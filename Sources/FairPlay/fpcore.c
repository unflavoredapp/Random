// FairPlayed — FairPlay decryption research tool.
// Revised mremap_encrypted: page-aligned remap window, native cryptid mode,
// libsystem_kernel dlsym fallback, guarded page-in retries.
//
// Regression (stock iOS / 16 KB pages):
// - FP_MODE_NATIVE is first in fp_decrypt_file()'s attempt order.
// - cryptoff that is only 4 KB-aligned is NOT rejected; fp_compute_remap_window()
//   aligns the mremap args, then we copy the original crypt range only.
#include "fpcore.h"
#include "fp_page.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <libkern/OSByteOrder.h>
#include <mach/mach.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>

#pragma mark - mremap_encrypted

typedef int (*mremap_encrypted_fn)(void *, size_t, uint32_t, uint32_t, uint32_t);

// Darwin arm64: SYS_mremap_encrypted == 489 (stable across iOS 16–27 stock kernels).
#ifndef SYS_mremap_encrypted_arm64
#define SYS_mremap_encrypted_arm64 489
#endif

static int raw_mremap_encrypted(void *addr, size_t len, uint32_t cryptid, uint32_t cputype, uint32_t cpusubtype) {
#if defined(__arm64__)
    // Kernel requires page-aligned addr + len; callers must round first.
    register uint64_t x0 __asm__("x0") = (uint64_t)addr;
    register uint64_t x1 __asm__("x1") = (uint64_t)len;
    register uint64_t x2 __asm__("x2") = cryptid;
    register uint64_t x3 __asm__("x3") = cputype;
    register uint64_t x4 __asm__("x4") = cpusubtype;
    register uint64_t x16 __asm__("x16") = SYS_mremap_encrypted_arm64;
    uint64_t failed;
    __asm__ volatile("svc #0x80\n\tcset %[f], cs\n"
                     : "+r"(x0), "+r"(x1), [f] "=r"(failed)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x16)
                     : "memory", "cc");
    if (failed) { errno = (int)x0; return -1; }
    return (int)x0;
#else
    (void)addr; (void)len; (void)cryptid; (void)cputype; (void)cpusubtype;
    errno = ENOTSUP;
    return -1;
#endif
}

enum { FP_MREMAP_BACKEND_NONE = 0, FP_MREMAP_BACKEND_DLSYM = 1, FP_MREMAP_BACKEND_KERNEL = 2, FP_MREMAP_BACKEND_SVC = 3 };

static mremap_encrypted_fn resolve_mremap_encrypted(int *backend_out, const char **err_out) {
    static mremap_encrypted_fn fn;
    static int resolved;
    static int backend;
    static char errbuf[128];
    if (resolved) {
        if (backend_out) *backend_out = backend;
        if (err_out) *err_out = backend ? NULL : errbuf;
        return fn;
    }
    errbuf[0] = 0;
    // Prefer the exported libsystem symbol (works when the stub is present).
    fn = (mremap_encrypted_fn)dlsym(RTLD_DEFAULT, "mremap_encrypted");
    if (fn) {
        backend = FP_MREMAP_BACKEND_DLSYM;
    } else {
        const char *dl1 = dlerror();
        void *h = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_LAZY | RTLD_NOLOAD);
        if (!h) h = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_LAZY);
        if (h) {
            fn = (mremap_encrypted_fn)dlsym(h, "mremap_encrypted");
            if (fn) backend = FP_MREMAP_BACKEND_KERNEL;
        }
        if (!fn) {
            const char *dl2 = dlerror();
            snprintf(errbuf, sizeof errbuf, "dlsym=%s; kernel=%s; falling back to svc",
                     dl1 && *dl1 ? dl1 : "nil",
                     dl2 && *dl2 ? dl2 : (h ? "nil" : "dlopen-failed"));
            backend = FP_MREMAP_BACKEND_SVC; // raw svc path used by do_mremap_encrypted
        }
    }
    resolved = 1;
    if (backend_out) *backend_out = backend;
    if (err_out) *err_out = backend == FP_MREMAP_BACKEND_SVC ? errbuf : NULL;
    return fn;
}

static const char *mremap_backend_name(int backend) {
    switch (backend) {
        case FP_MREMAP_BACKEND_DLSYM: return "dlsym";
        case FP_MREMAP_BACKEND_KERNEL: return "libsystem_kernel";
        case FP_MREMAP_BACKEND_SVC: return "svc";
        default: return "none";
    }
}

static int do_mremap_encrypted(void *addr, size_t len, uint32_t cryptid, uint32_t cputype, uint32_t cpusubtype) {
    int backend = 0;
    const char *err = NULL;
    mremap_encrypted_fn fn = resolve_mremap_encrypted(&backend, &err);
    (void)err;
    if (fn) return fn(addr, len, cryptid, cputype, cpusubtype);
    return raw_mremap_encrypted(addr, len, cryptid, cputype, cpusubtype);
}

static uint64_t fp_page_size(void) {
    static uint64_t pg;
    if (!pg) {
        long p = sysconf(_SC_PAGESIZE);
        if (p <= 0) p = getpagesize();
        pg = (uint64_t)(p > 0 ? p : 16384);
    }
    return pg;
}

/// Pick cryptid + PROT flags for a mode. cryptid arg selects the VM path
/// (2 = CRYPTID_MODEL_ENCRYPTION skips PROT_EXEC); it is not the FairPlay key id.
static void mode_params(int mode, const fp_slice_t *s, uint32_t *cid_out, int *prot_out) {
    switch (mode) {
        case FP_MODE_R_CID2:
            *cid_out = 2;
            *prot_out = PROT_READ;
            break;
        case FP_MODE_RX_CID1:
            *cid_out = 1;
            *prot_out = PROT_READ | PROT_EXEC;
            break;
        case FP_MODE_R_CID1:
            *cid_out = 1;
            *prot_out = PROT_READ;
            break;
        case FP_MODE_NATIVE:
        default: {
            uint32_t native = s->cryptid ? s->cryptid : 1;
            *cid_out = native;
            // cryptid 1 historically expects an executable mapping (dyld path);
            // cryptid 2+ can use plain PROT_READ.
            *prot_out = (native == 1) ? (PROT_READ | PROT_EXEC) : PROT_READ;
            break;
        }
    }
}

#pragma mark - helpers

static void logf_(fp_log_t log, void *ctx, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void logf_(fp_log_t log, void *ctx, const char *fmt, ...) {
    char buf[2048];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    if (log) log(ctx, buf); else fprintf(stderr, "%s\n", buf);
}

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static double entropy(const uint8_t *p, size_t n) {
    if (!n) return 0;
    uint64_t h[256] = {0};
    for (size_t i = 0; i < n; i++) h[p[i]]++;
    double e = 0;
    for (int i = 0; i < 256; i++) if (h[i]) { double q = (double)h[i] / n; e -= q * log2(q); }
    return e;
}

static uint32_t code_words(const uint8_t *p, size_t n) {
    uint32_t c = 0;
    for (size_t i = 0; i + 4 <= n; i += 4) {
        uint32_t w; memcpy(&w, p + i, 4);
        if (w == 0xd65f03c0 /* ret */ || w == 0xd503237f /* pacibsp */ || w == 0xd65f0fff /* retab */) c++;
    }
    return c;
}

static bool pread_full(int fd, void *buf, size_t n, off_t off) {
    uint8_t *p = buf;
    while (n) {
        ssize_t r = pread(fd, p, n, off);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return false; }
        p += r; n -= r; off += r;
    }
    return true;
}

static bool pwrite_full(int fd, const void *buf, size_t n, off_t off) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t r = pwrite(fd, p, n, off);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return false; }
        p += r; n -= r; off += r;
    }
    return true;
}

const char *fp_mode_name(int mode) {
    switch (mode) {
        case FP_MODE_R_CID2:  return "R/cryptid2";
        case FP_MODE_RX_CID1: return "RX/cryptid1";
        case FP_MODE_R_CID1:  return "R/cryptid1";
        case FP_MODE_NATIVE:  return "native/cryptid";
    }
    return "?";
}

bool fp_is_macho(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    uint32_t m = 0;
    bool ok = pread(fd, &m, 4, 0) == 4;
    close(fd);
    if (!ok) return false;
    return m == MH_MAGIC_64 || m == MH_MAGIC || m == MH_CIGAM_64 || m == MH_CIGAM
        || m == FAT_MAGIC || m == FAT_MAGIC_64 || m == FAT_CIGAM || m == FAT_CIGAM_64;
}

#pragma mark - parsing

static int parse_thin(int fd, uint64_t off, uint64_t size, fp_slice_t *s, char *err, size_t errlen) {
    struct mach_header_64 mh;
    if (!pread_full(fd, &mh, sizeof mh, off)) { snprintf(err, errlen, "short read (header)"); return -1; }
    if (mh.magic != MH_MAGIC_64) { snprintf(err, errlen, "unsupported magic 0x%x", mh.magic); return -1; }
    memset(s, 0, sizeof *s);
    s->slice_off = off; s->slice_size = size;
    s->cputype = mh.cputype; s->cpusubtype = mh.cpusubtype; s->filetype = mh.filetype;
    if (mh.sizeofcmds > 16 * 1024 * 1024) { snprintf(err, errlen, "sizeofcmds too large"); return -1; }
    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (!cmds || !pread_full(fd, cmds, mh.sizeofcmds, off + sizeof mh)) { free(cmds); snprintf(err, errlen, "short read (cmds)"); return -1; }
    uint32_t pos = 0;
    for (uint32_t i = 0; i < mh.ncmds && pos + 8 <= mh.sizeofcmds; i++) {
        struct load_command *lc = (struct load_command *)(cmds + pos);
        if (lc->cmdsize < 8 || pos + lc->cmdsize > mh.sizeofcmds) break;
        if (lc->cmd == LC_ENCRYPTION_INFO_64 || lc->cmd == LC_ENCRYPTION_INFO) {
            struct encryption_info_command *e = (void *)lc;
            s->has_enc = true;
            s->enc_lc_off = off + sizeof mh + pos;
            s->cryptoff = e->cryptoff; s->cryptsize = e->cryptsize; s->cryptid = e->cryptid;
        } else if (lc->cmd == LC_CODE_SIGNATURE) {
            struct linkedit_data_command *l = (void *)lc;
            s->cs_off = l->dataoff; s->cs_size = l->datasize;
        }
        pos += lc->cmdsize;
    }
    free(cmds);
    return 0;
}

int fp_parse(const char *path, fp_slice_t *slices, int max, int *count, char *err, size_t errlen) {
    *count = 0;
    if (!slices || max <= 0 || !count) {
        if (err && errlen) snprintf(err, errlen, "bad args");
        return -1;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) { snprintf(err, errlen, "open: %s", strerror(errno)); return -1; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 4) {
        close(fd);
        snprintf(err, errlen, "stat/size: %s", st.st_size < 4 ? "too small" : strerror(errno));
        return -1;
    }
    const uint64_t file_size = (uint64_t)st.st_size;
    uint32_t magic = 0;
    if (!pread_full(fd, &magic, 4, 0)) { close(fd); snprintf(err, errlen, "short read"); return -1; }
    int rc = 0;
    if (magic == FAT_MAGIC || magic == FAT_MAGIC_64 || magic == FAT_CIGAM || magic == FAT_CIGAM_64) {
        bool is64 = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64);
        // Fat headers are always big-endian on disk.
        struct fat_header fh;
        if (!pread_full(fd, &fh, sizeof fh, 0)) {
            close(fd); snprintf(err, errlen, "short fat header"); return -1;
        }
        uint32_t n = OSSwapBigToHostInt32(fh.nfat_arch);
        // Cap absurd tables; real universals are tiny (≤ ~10 arches).
        if (n == 0 || n > 64) {
            close(fd); snprintf(err, errlen, "fat nfat_arch=%u invalid", n); return -1;
        }
        uint64_t arch_sz = is64 ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
        if (arch_sz > UINT64_MAX / n || sizeof fh + n * arch_sz > file_size) {
            close(fd); snprintf(err, errlen, "fat arch table overflows file"); return -1;
        }
        uint64_t p = sizeof fh;
        for (uint32_t i = 0; i < n && *count < max; i++) {
            uint64_t o, sz; uint32_t ct;
            if (is64) {
                struct fat_arch_64 fa;
                if (!pread_full(fd, &fa, sizeof fa, p)) break;
                p += sizeof fa;
                o = OSSwapBigToHostInt64(fa.offset);
                sz = OSSwapBigToHostInt64(fa.size);
                ct = OSSwapBigToHostInt32(fa.cputype);
            } else {
                struct fat_arch fa;
                if (!pread_full(fd, &fa, sizeof fa, p)) break;
                p += sizeof fa;
                o = OSSwapBigToHostInt32(fa.offset);
                sz = OSSwapBigToHostInt32(fa.size);
                ct = OSSwapBigToHostInt32(fa.cputype);
            }
            // Slice must lie entirely inside the file.
            if (sz == 0 || o > file_size || sz > file_size - o) continue;
            // Prefer arm64 / arm64e; still accept any 64-bit slice (simulators, etc.).
            if (!(ct & CPU_ARCH_ABI64)) continue;
            char e2[128];
            if (parse_thin(fd, o, sz, &slices[*count], e2, sizeof e2) == 0) (*count)++;
        }
        if (*count == 0) {
            snprintf(err, errlen, "fat Mach-O has no decryptable 64-bit slices");
            rc = -1;
        }
    } else if (magic == MH_MAGIC_64) {
        rc = parse_thin(fd, 0, file_size, &slices[0], err, errlen);
        if (rc == 0) *count = 1;
    } else {
        snprintf(err, errlen, "not a 64-bit Mach-O (magic 0x%08x)", magic);
        rc = -1;
    }
    close(fd);
    return rc;
}

#pragma mark - attempt

int fp_attempt(const char *path, const fp_slice_t *s, int mode, bool addsigs, uint8_t *out, fp_attempt_t *res) {
    memset(res, 0, sizeof *res);
    res->mode = mode; res->addsigs = addsigs; res->mremap_ret = -1;
    double t0 = now_ms();
    const uint64_t pg = fp_page_size();
    if (!s->has_enc || s->cryptsize == 0) return -1;
    // Slice must start on a page so mmap(offset=slice_off) is valid.
    if (s->slice_off % pg) { res->mmap_errno = EINVAL; return -1; }

    // Page-align the remap window. On 16 KB devices, LC cryptoff/cryptsize may still
    // be 4 KB multiples; the kernel rejects non-page-aligned mremap_encrypted args.
    // Do NOT hard-reject 4 KB-aligned cryptoff — compute an aligned window instead.
    uint64_t remap_off = 0, remap_len = 0;
    if (!fp_compute_remap_window(s->cryptoff, s->cryptsize, s->slice_size, pg, &remap_off, &remap_len)) {
        res->mremap_errno = EINVAL;
        res->ms = now_ms() - t0;
        return -1;
    }
    res->remap_off = remap_off;
    res->remap_len = remap_len;

    uint32_t cid = 0;
    int prot = PROT_READ;
    mode_params(mode, s, &cid, &prot);
    res->used_cryptid = cid;

    int fd = open(path, O_RDONLY);
    if (fd < 0) { res->mmap_errno = errno; return -1; }

    if (addsigs && s->cs_size) {
        fsignatures_t fs = { .fs_file_start = (off_t)s->slice_off, .fs_blob_start = (void *)(uintptr_t)s->cs_off, .fs_blob_size = s->cs_size };
        if (fcntl(fd, F_ADDFILESIGS_RETURN, &fs) == -1) res->sig_errno = errno;
    }

    // Map enough of the slice to cover the aligned remap window.
    uint64_t map_len = fp_align_up(remap_off + remap_len, pg);
    if (map_len == 0) map_len = pg;
    uint8_t *base = mmap(NULL, (size_t)map_len, prot, MAP_PRIVATE, fd, (off_t)s->slice_off);
    if (base == MAP_FAILED) { res->mmap_errno = errno; close(fd); res->ms = now_ms() - t0; return -1; }

    uint8_t *orig = malloc(s->cryptsize);
    uint8_t *dec = out ? out : malloc(s->cryptsize);
    if (!orig || !dec || !pread_full(fd, orig, s->cryptsize, (off_t)(s->slice_off + s->cryptoff))) {
        free(orig); if (!out) free(dec); munmap(base, (size_t)map_len); close(fd); res->mmap_errno = EIO; return -1;
    }

    // Page accounting covers the logical crypt range (not the padded remap).
    uint64_t total = (s->cryptsize + pg - 1) / pg;
    if (total == 0) total = 1;
    res->pages_total = total;

    // Guarded remapping retry: when fairplayd flakes mid page-in, unmap + mremap again
    // and re-read failed pages (userspace pager retry — no kwrite).
    uint8_t *okmask = calloc((size_t)total, 1);
    if (!okmask) {
        free(orig); if (!out) free(dec); munmap(base, (size_t)map_len); close(fd);
        res->mmap_errno = ENOMEM; res->ms = now_ms() - t0; return -1;
    }

    for (int round = 0; round < 5; round++) {
        if (round > 0) {
            if (base != MAP_FAILED) munmap(base, (size_t)map_len);
            usleep((useconds_t)(50 * 1000 * round));
            base = mmap(NULL, (size_t)map_len, prot, MAP_PRIVATE, fd, (off_t)s->slice_off);
            if (base == MAP_FAILED) { res->mmap_errno = errno; break; }
        }
        errno = 0;
        int mr = do_mremap_encrypted(base + remap_off, (size_t)remap_len, cid, s->cputype, s->cpusubtype);
        res->mremap_ret = mr;
        res->mremap_errno = mr == 0 ? 0 : errno;
        if (mr != 0) continue;

        uint64_t pages_ok = 0;
        int first_kr = 0;
        uint64_t first_off = 0;
        for (uint64_t i = 0; i < total; i++) {
            if (okmask[i]) { pages_ok++; continue; }
            uint64_t off = i * pg;
            uint64_t n = (off + pg <= s->cryptsize) ? pg : (s->cryptsize - off);
            vm_size_t got = 0;
            // vm_read_overwrite reports decrypt page-in failures as kern_return_t (no SIGBUS).
            kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                                 (vm_address_t)(base + s->cryptoff + off),
                                                 (vm_size_t)n,
                                                 (vm_address_t)(dec + off), &got);
            if (kr == KERN_SUCCESS && got == n) {
                okmask[i] = 1;
                pages_ok++;
            } else {
                if (!first_kr) { first_kr = kr ? (int)kr : -1; first_off = s->cryptoff + off; }
                memset(dec + off, 0, (size_t)n);
            }
        }
        res->pages_ok = pages_ok;
        if (first_kr && !res->first_fail_kr) {
            res->first_fail_kr = first_kr;
            res->first_fail_off = first_off;
        }
        if (pages_ok == total) break;
    }

    free(okmask);
    if (res->mremap_ret == 0 && res->pages_ok == res->pages_total) {
        res->changed = memcmp(orig, dec, s->cryptsize) != 0;
        res->ret_after = code_words(dec, s->cryptsize);
        res->ent_after = entropy(dec, s->cryptsize);
    }
    res->ret_before = code_words(orig, s->cryptsize);
    res->ent_before = entropy(orig, s->cryptsize);

    free(orig);
    if (!out) free(dec);
    if (base != MAP_FAILED) munmap(base, (size_t)map_len);
    close(fd);
    res->ms = now_ms() - t0;
    return (res->mremap_ret == 0 && res->pages_ok == res->pages_total && res->changed) ? 0 : -1;
}

void fp_attempt_describe(const fp_attempt_t *a, char *buf, size_t len) {
    snprintf(buf, len,
             "%s%s cid=%u remap=0x%llx+0x%llx: sig=%s mmap=%s mremap=%d(errno %d %s) pages=%llu/%llu "
             "firstfail=kr%d@0x%llx changed=%d code-words %u->%u entropy %.3f->%.3f (%.0f ms)",
             fp_mode_name(a->mode), a->addsigs ? "+sigs" : "",
             a->used_cryptid,
             (unsigned long long)a->remap_off, (unsigned long long)a->remap_len,
             a->addsigs ? (a->sig_errno ? strerror(a->sig_errno) : "ok") : "-",
             a->mmap_errno ? strerror(a->mmap_errno) : "ok",
             a->mremap_ret, a->mremap_errno, a->mremap_errno ? strerror(a->mremap_errno) : "ok",
             (unsigned long long)a->pages_ok, (unsigned long long)a->pages_total,
             a->first_fail_kr, (unsigned long long)a->first_fail_off, a->changed,
             a->ret_before, a->ret_after, a->ent_before, a->ent_after, a->ms);
}

static bool attempt_looks_decrypted(const fp_attempt_t *a) {
    // Primary: full page-in + bytes changed + entropy drop typical of FairPlay ciphertext → code.
    // Encrypted text sits near 8.0 bits/byte; arm64 text usually drops below ~7.5.
    if (!(a->mremap_ret == 0 && a->pages_ok == a->pages_total && a->changed)) return false;
    bool entropy_ok = (a->ent_before > 7.85 && a->ent_after < 7.55) ||
                      (a->ent_before - a->ent_after) > 0.35;
    bool code_ok = a->ret_after > a->ret_before;
    // Accept either strong entropy drop or new RET/PACIBSP words (tiny binaries).
    return entropy_ok || code_ok;
}

int fp_probe_file(const char *path, const int *modes, int nmodes, fp_log_t log, void *ctx) {
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) { logf_(log, ctx, "  parse failed: %s", err); return -1; }
    int successes = 0;
    for (int i = 0; i < n; i++) {
        const fp_slice_t *s = &sl[i];
        logf_(log, ctx, "  slice[%d] cpu=0x%x/0x%x type=%u off=0x%llx enc=%d cryptoff=0x%x cryptsize=0x%x cryptid=%u cs=0x%x+0x%x",
              i, s->cputype, s->cpusubtype, s->filetype, (unsigned long long)s->slice_off, s->has_enc,
              s->cryptoff, s->cryptsize, s->cryptid, s->cs_off, s->cs_size);
        if (!s->has_enc || s->cryptid == 0) continue;
        for (int m = 0; m < nmodes; m++) {
            for (int sig = 0; sig < 2; sig++) {
                fp_attempt_t a; char d[512];
                fp_attempt(path, s, modes[m], sig, NULL, &a);
                fp_attempt_describe(&a, d, sizeof d);
                bool ok = attempt_looks_decrypted(&a);
                if (ok) successes++;
                logf_(log, ctx, "    %s %s", ok ? "[DECRYPTED]" : "[--]", d);
            }
        }
    }
    return successes;
}

#pragma mark - decrypt to file

static int copy_file(const char *src, const char *dst) {
    int in = open(src, O_RDONLY);
    if (in < 0) return -1;
    struct stat st; fstat(in, &st);
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, (st.st_mode & 0777) | 0600);
    if (out < 0) { close(in); return -1; }
    uint8_t *buf = malloc(1 << 20);
    ssize_t r; int rc = 0;
    while ((r = read(in, buf, 1 << 20)) > 0) if (write(out, buf, (size_t)r) != r) { rc = -1; break; }
    if (r < 0) rc = -1;
    free(buf); close(in); close(out);
    return rc;
}

int fp_has_encrypted_slice(const char *path) {
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) return -1;
    for (int i = 0; i < n; i++) if (sl[i].has_enc && sl[i].cryptid) return 1;
    return 0;
}

int fp_max_cryptid(const char *path) {
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) return -1;
    int max = 0;
    for (int i = 0; i < n; i++) {
        if (sl[i].has_enc && (int)sl[i].cryptid > max) max = (int)sl[i].cryptid;
    }
    return max;
}

int fp_count_encrypted_slices(const char *path) {
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) return -1;
    int c = 0;
    for (int i = 0; i < n; i++) if (sl[i].has_enc && sl[i].cryptid) c++;
    return c;
}

int fp_describe_cryptids(const char *path, char *buf, size_t buflen) {
    if (!buf || !buflen) return -1;
    buf[0] = 0;
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) {
        snprintf(buf, buflen, "parse-error");
        return -1;
    }
    size_t used = 0;
    for (int i = 0; i < n; i++) {
        char piece[64];
        if (sl[i].has_enc) {
            snprintf(piece, sizeof piece, "%ss%u:cryptid=%u", i ? " " : "", (unsigned)i, sl[i].cryptid);
        } else {
            snprintf(piece, sizeof piece, "%ss%u:plain", i ? " " : "", (unsigned)i);
        }
        size_t len = strlen(piece);
        if (used + len + 1 >= buflen) break;
        memcpy(buf + used, piece, len + 1);
        used += len;
    }
    if (!n) snprintf(buf, buflen, "no-slices");
    return n;
}

int fp_decrypt_file(const char *in_path, const char *out_path, fp_log_t log, void *ctx) {
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(in_path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) { logf_(log, ctx, "  parse failed: %s", err); return -1; }
    bool any = false;
    for (int i = 0; i < n; i++) if (sl[i].has_enc && sl[i].cryptid) any = true;
    if (strcmp(in_path, out_path) != 0 && copy_file(in_path, out_path) != 0) { logf_(log, ctx, "  copy failed: %s", strerror(errno)); return -1; }
    if (!any) return 1;

    int out = open(out_path, O_RDWR);
    if (out < 0) { logf_(log, ctx, "  open out: %s", strerror(errno)); return -1; }

    // Resolve mremap backend once so logs show dlsym vs svc (not silent).
    {
        int backend = 0;
        const char *rerr = NULL;
        (void)resolve_mremap_encrypted(&backend, &rerr);
        if (rerr) logf_(log, ctx, "  mremap backend=%s (%s)", mremap_backend_name(backend), rerr);
        else logf_(log, ctx, "  mremap backend=%s", mremap_backend_name(backend));
    }

    // Order: native LC cryptid first, then R/cryptid=2 (no PROT_EXEC), then dyld RX/cid1.
    // Each mode is tried with and without F_ADDFILESIGS_RETURN.
    // Kept in sync with tests/fpcore/test_fp_page.c (kExpectedDecryptOrder).
    const int order[][2] = {
        {FP_MODE_NATIVE, 0}, {FP_MODE_NATIVE, 1},
        {FP_MODE_R_CID2, 0}, {FP_MODE_R_CID2, 1},
        {FP_MODE_RX_CID1, 0}, {FP_MODE_RX_CID1, 1},
        {FP_MODE_R_CID1, 0}, {FP_MODE_R_CID1, 1}
    };
    const uint64_t pg = fp_page_size();
    int rc = 0;
    for (int i = 0; i < n && rc == 0; i++) {
        const fp_slice_t *s = &sl[i];
        if (!s->has_enc || s->cryptid == 0) continue;
        if (s->cryptsize == 0) {
            logf_(log, ctx, "  slice[%d] empty crypt range", i);
            rc = -1; break;
        }
        // Remap window must fit in the slice after page alignment.
        // Intentionally NOT: (cryptoff % page) != 0 → fail. That rejected valid
        // 4 KB LC ranges on 16 KB devices before alignment could run.
        uint64_t remap_off = 0, remap_len = 0;
        if (!fp_compute_remap_window(s->cryptoff, s->cryptsize, s->slice_size, pg, &remap_off, &remap_len)) {
            logf_(log, ctx, "  slice[%d] crypt range not remappable (off=0x%x size=0x%x page=%llu slice=%llu)",
                  i, s->cryptoff, s->cryptsize, (unsigned long long)pg, (unsigned long long)s->slice_size);
            rc = -1; break;
        }
        if (s->cryptoff % pg) {
            logf_(log, ctx, "  slice[%d] cryptoff 0x%x not page-aligned (page=%llu) — aligning remap to 0x%llx+0x%llx",
                  i, s->cryptoff, (unsigned long long)pg,
                  (unsigned long long)remap_off, (unsigned long long)remap_len);
        }
        uint8_t *dec = malloc(s->cryptsize);
        if (!dec) { rc = -1; break; }
        bool done = false;
        fp_attempt_t best; memset(&best, 0, sizeof best); best.mremap_ret = -1;
        for (size_t k = 0; k < sizeof order / sizeof order[0] && !done; k++) {
            fp_attempt_t a; char d[512];
            // Extra tries per mode — guarded remapping inside fp_attempt plus outer backoff.
            for (int attempt = 0; attempt < 4 && !done; attempt++) {
                if (attempt) usleep((useconds_t)(60 * 1000 * attempt));
                fp_attempt(in_path, s, order[k][0], order[k][1], dec, &a);
                if (a.pages_ok > best.pages_ok || (a.pages_ok == best.pages_ok && a.changed && !best.changed))
                    best = a;
                fp_attempt_describe(&a, d, sizeof d);
                done = attempt_looks_decrypted(&a);
                logf_(log, ctx, "  slice[%d] try%zu.%d %s %s", i, k, attempt, done ? "[DECRYPTED]" : "[--]", d);
            }
        }
        if (!done) {
            char d[512];
            fp_attempt_describe(&best, d, sizeof d);
            logf_(log, ctx, "  slice[%d] FAILED after all modes; best: %s", i, d);
            rc = -1; free(dec); break;
        }
        uint32_t zero = 0;
        if (!pwrite_full(out, dec, s->cryptsize, (off_t)(s->slice_off + s->cryptoff)) ||
            !pwrite_full(out, &zero, 4, (off_t)(s->enc_lc_off + offsetof(struct encryption_info_command, cryptid)))) {
            logf_(log, ctx, "  write failed: %s", strerror(errno)); rc = -1;
        }
        free(dec);
    }
    close(out);
    if (rc == 0) {
        // Fail closed: refuse to return success if any slice still reports cryptid ≠ 0.
        int still = fp_has_encrypted_slice(out_path);
        if (still != 0) {
            logf_(log, ctx, "  verify failed: output still encrypted (status=%d)", still);
            rc = -1;
        } else {
            logf_(log, ctx, "  verify ok: cryptid=0 on all slices");
        }
    }
    return rc;
}
