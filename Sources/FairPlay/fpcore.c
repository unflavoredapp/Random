// FairPlayed — FairPlay decryption research tool.
// Brand: Tetherless · https://tetherless.dev
// Revised mremap_encrypted: page-aligned remap window, native cryptid mode,
// libsystem_kernel dlsym fallback, guarded page-in retries.
//
// GitHub configuration parity (install-path decrypt):
// - foulplay (meme/apple-tools foulplay/main.c): pass LC cryptid to mremap_encrypted
//   → FP_MODE_NATIVE is first in fp_decrypt_file()'s attempt order.
// - FairPlayed (morzelowski/FairPlayed fpcore.c + exportInstalledApp): map from
//   slice_off, vm_read_overwrite page-in, then R/cid2 + RX/cid1 fallbacks; caller
//   must pass the live install binary as in_path (SC_Info beside it) and a writable
//   Payload path as out_path.
//
// Regression (stock iOS / 16 KB pages):
// - cryptoff that is only 4 KB-aligned is NOT rejected; fp_compute_remap_window()
//   aligns the mremap args, then we copy the original crypt range only.
//
// Hardening:
// - Map only [remap_off, +remap_len) (no leading unencrypted bytes before remmap).
// - Lean buffers (no second full-cryptsize orig); per-page cipher verify.
// - Streamed page capture: one-page WILLNEED → vm_read → DONTNEED (never fault full crypt).
// - Sample entropy/RET on first/mid/last pages only — no full-crypt RSS walks.
// - iPhone always uses file-backed lean (even ~20 MB mains Jetsam on classic 3×).
// - Remmap-ok-but-unchanged classified as license/keys (FP_FAIL_PERM).
#include "fpcore.h"
#include "fp_page.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <malloc/malloc.h>
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
#include <mach/machine.h>
#if __has_include(<TargetConditionals.h>)
#include <TargetConditionals.h>
#endif
#if __has_include(<os/proc.h>)
#include <os/proc.h>
#endif
#ifndef CPU_TYPE_ARM64
#define CPU_TYPE_ARM64 ((cpu_type_t)(CPU_TYPE_ARM | CPU_ARCH_ABI64))
#endif
// iPhone / iPad: always prefer file-backed lean + streamed page capture.
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST
#define FP_FORCE_LEAN 1
#else
#define FP_FORCE_LEAN 0
#endif

#pragma mark - Failure class (for Swift UX)

static int g_fp_last_fail = FP_FAIL_NONE;

int fp_last_fail_kind(void) { return g_fp_last_fail; }

const char *fp_fail_kind_name(int kind) {
    switch (kind) {
        case FP_FAIL_NONE: return "none";
        case FP_FAIL_NOMEM: return "out-of-memory";
        case FP_FAIL_PERM: return "license-or-keys";
        case FP_FAIL_STILL_ENC: return "still-encrypted";
        case FP_FAIL_IO: return "io";
        default: return "other";
    }
}

static void fp_set_fail(int kind) { g_fp_last_fail = kind; }

static void fp_note_errno(int err) {
    if (err == ENOMEM) fp_set_fail(FP_FAIL_NOMEM);
    else if (err == EPERM || err == EACCES) fp_set_fail(FP_FAIL_PERM);
    else if (err == EIO || err == ENOENT || err == EBADF) fp_set_fail(FP_FAIL_IO);
    else if (err != 0) fp_set_fail(FP_FAIL_OTHER);
}

uint64_t fp_available_memory(void) {
#if defined(__APPLE__) && __has_include(<os/proc.h>)
    if (&os_proc_available_memory != NULL) {
        size_t avail = os_proc_available_memory();
        if (avail > 0) return (uint64_t)avail;
    }
#endif
    return 0;
}

int fp_memory_tight_for(uint64_t cryptsize) {
    // Lean path needs ≈1× cryptsize + remap window; classic path needs ≈3×.
    // Treat as tight when available RAM can't cover classic 3× with headroom,
    // or when the crypt range itself is large enough to jetsam mid-mremap.
    uint64_t classic_need = cryptsize * 3;
    uint64_t lean_need = cryptsize + (16ull << 20);
    if (cryptsize > (48ull << 20)) classic_need += cryptsize; // large padded remap
    uint64_t avail = fp_available_memory();
    if (avail > 0) {
        if (avail < classic_need + (64ull << 20)) return 1;
        if (avail < lean_need + (32ull << 20)) return 1;
    }
    (void)classic_need; (void)lean_need;
    // Prefer lean once crypt ≥ 32 MB — phones often jetsam the 3× path here.
    if (cryptsize >= (32ull << 20)) return 1;
    return 0;
}

int fp_memory_can_decrypt(uint64_t cryptsize) {
    // File-backed lean keeps the crypt buffer on disk; Jetsam cost is mostly the
    // remapped crypt window residency + ~48 MB process headroom.
    uint64_t lean_need = cryptsize + (48ull << 20);
    uint64_t avail = fp_available_memory();
    if (avail == 0) {
        // Unknown budget — allow attempt; crypt ≥ 180 MB is near-hopeless on 3–4 GB phones.
        return cryptsize < (180ull << 20) ? 1 : 0;
    }
    return avail >= lean_need ? 1 : 0;
}

int64_t fp_largest_cryptsize(const char *path) {
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) return -1;
    int64_t best = 0;
    for (int i = 0; i < n; i++) {
        if (!sl[i].has_enc || sl[i].cryptid == 0) continue;
        if ((int64_t)sl[i].cryptsize > best) best = (int64_t)sl[i].cryptsize;
    }
    return best;
}

#ifndef MAP_NOCACHE
#define MAP_NOCACHE 0
#endif

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

/// Stream heuristic: first / middle / last page only — never walk the full crypt RSS.
static void sample_code_entropy(
    const uint8_t *buf,
    uint64_t cryptsize,
    uint64_t pg,
    uint32_t *ret_out,
    double *ent_out
) {
    if (!buf || !cryptsize || !pg || !ret_out || !ent_out) {
        if (ret_out) *ret_out = 0;
        if (ent_out) *ent_out = 0;
        return;
    }
    uint64_t sample = cryptsize < pg ? cryptsize : pg;
    uint64_t page_total = (cryptsize + pg - 1) / pg;
    uint64_t mid = (page_total / 2) * pg;
    if (mid + sample > cryptsize) mid = cryptsize > sample ? cryptsize - sample : 0;
    uint64_t last = cryptsize > sample ? cryptsize - sample : 0;
    uint64_t offs[3] = { 0, mid, last };
    uint32_t ret_sum = 0;
    double ent_sum = 0;
    int n = 0;
    for (int i = 0; i < 3; i++) {
        ret_sum += code_words(buf + offs[i], (size_t)sample);
        ent_sum += entropy(buf + offs[i], (size_t)sample);
        n++;
    }
    *ret_out = n ? ret_sum / (uint32_t)n : 0;
    *ent_out = n ? ent_sum / (double)n : 0;
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
    // Bound every read to this fat slice (or the whole thin file). 32-bit Mach-O is
    // intentionally unsupported — modern App Store IPAs ship MH_MAGIC_64 only.
    if (size < sizeof(struct mach_header_64)) {
        snprintf(err, errlen, "slice too small for mach_header_64");
        return -1;
    }
    struct mach_header_64 mh;
    if (!pread_full(fd, &mh, sizeof mh, off)) { snprintf(err, errlen, "short read (header)"); return -1; }
    if (mh.magic != MH_MAGIC_64) { snprintf(err, errlen, "unsupported magic 0x%x (64-bit only)", mh.magic); return -1; }
    memset(s, 0, sizeof *s);
    s->slice_off = off; s->slice_size = size;
    s->cputype = mh.cputype; s->cpusubtype = mh.cpusubtype; s->filetype = mh.filetype;
    if (mh.sizeofcmds > 16 * 1024 * 1024) { snprintf(err, errlen, "sizeofcmds too large"); return -1; }
    // Header + load-command blob must fit inside this slice — never read past arch bounds.
    if ((uint64_t)sizeof mh + (uint64_t)mh.sizeofcmds > size) {
        snprintf(err, errlen, "sizeofcmds overflows slice (%u + %u > %llu)",
                 (unsigned)sizeof mh, mh.sizeofcmds, (unsigned long long)size);
        return -1;
    }
    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (!cmds || !pread_full(fd, cmds, mh.sizeofcmds, off + sizeof mh)) { free(cmds); snprintf(err, errlen, "short read (cmds)"); return -1; }
    uint32_t pos = 0;
    for (uint32_t i = 0; i < mh.ncmds && pos + 8 <= mh.sizeofcmds; i++) {
        struct load_command *lc = (struct load_command *)(cmds + pos);
        if (lc->cmdsize < 8 || pos + lc->cmdsize > mh.sizeofcmds) {
            free(cmds);
            snprintf(err, errlen, "load command %u overflows sizeofcmds", i);
            return -1;
        }
        if (lc->cmd == LC_ENCRYPTION_INFO_64 || lc->cmd == LC_ENCRYPTION_INFO) {
            const uint32_t need = (lc->cmd == LC_ENCRYPTION_INFO_64)
                ? (uint32_t)sizeof(struct encryption_info_command_64)
                : (uint32_t)sizeof(struct encryption_info_command);
            if (lc->cmdsize < need) {
                free(cmds);
                snprintf(err, errlen, "encryption LC too small (%u < %u)", lc->cmdsize, need);
                return -1;
            }
            struct encryption_info_command *e = (void *)lc;
            // crypt range is relative to the thin slice start.
            if ((uint64_t)e->cryptoff > size ||
                (uint64_t)e->cryptsize > size - (uint64_t)e->cryptoff) {
                free(cmds);
                snprintf(err, errlen, "encryption range overflows slice (off=0x%x size=0x%x slice=%llu)",
                         e->cryptoff, e->cryptsize, (unsigned long long)size);
                return -1;
            }
            s->has_enc = true;
            s->enc_lc_off = off + sizeof mh + pos;
            s->cryptoff = e->cryptoff; s->cryptsize = e->cryptsize; s->cryptid = e->cryptid;
        } else if (lc->cmd == LC_CODE_SIGNATURE) {
            if (lc->cmdsize < sizeof(struct linkedit_data_command)) {
                free(cmds);
                snprintf(err, errlen, "code signature LC too small");
                return -1;
            }
            struct linkedit_data_command *l = (void *)lc;
            if ((uint64_t)l->dataoff > size ||
                (uint64_t)l->datasize > size - (uint64_t)l->dataoff) {
                free(cmds);
                snprintf(err, errlen, "code signature range overflows slice");
                return -1;
            }
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
            // Device decrypt only needs arm64 / arm64e — skip x86_64 fat siblings
            // so we never pay a second cryptsize Jetsam tax for simulator slices.
            if (!(ct & CPU_ARCH_ABI64)) continue;
            char e2[128];
            if (parse_thin(fd, o, sz, &slices[*count], e2, sizeof e2) == 0) {
                slices[*count].cputype = ct; // fat cputype for ARM64 filter below
                (*count)++;
            }
        }
        // Prefer ARM64-only when at least one ARM64 slice parsed.
        {
            bool have_arm64 = false;
            for (int i = 0; i < *count; i++) {
                if (slices[i].cputype == CPU_TYPE_ARM64) { have_arm64 = true; break; }
            }
            if (have_arm64) {
                int w = 0;
                for (int i = 0; i < *count; i++) {
                    if (slices[i].cputype == CPU_TYPE_ARM64) slices[w++] = slices[i];
                }
                *count = w;
            }
        }
        if (*count == 0) {
            snprintf(err, errlen, "fat Mach-O has no decryptable arm64 slices");
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

/// Read one decrypted crypt page after mremap. Retries vm_read_overwrite with a short
/// yield — fairplayd often needs a second page-in pulse on large / busy binaries.
static bool fp_read_crypt_page(
    uint8_t *base,
    uint64_t read_bias,
    uint64_t page_index,
    uint64_t page,
    uint64_t cryptsize,
    uint8_t *dec,
    int *first_kr,
    uint64_t *first_off,
    uint32_t cryptoff
) {
    uint64_t off = page_index * page;
    uint64_t n = (off + page <= cryptsize) ? page : (cryptsize - off);
    for (int try = 0; try < 3; try++) {
        if (try) usleep((useconds_t)(1500 * try));
        vm_size_t got = 0;
        kern_return_t kr = vm_read_overwrite(
            mach_task_self(),
            (vm_address_t)(base + read_bias + off),
            (vm_size_t)n,
            (vm_address_t)(dec + off),
            &got
        );
        if (kr == KERN_SUCCESS && got == n) return true;
        if (first_kr && !*first_kr) {
            *first_kr = kr ? (int)kr : -1;
            if (first_off) *first_off = (uint64_t)cryptoff + off;
        }
    }
    return false;
}

int fp_attempt(const char *path, const fp_slice_t *s, int mode, bool addsigs, uint8_t *out, fp_attempt_t *res) {
    memset(res, 0, sizeof *res);
    res->mode = mode; res->addsigs = addsigs; res->mremap_ret = -1;
    double t0 = now_ms();
    const uint64_t pg = fp_page_size();
    if (!s->has_enc || s->cryptsize == 0) return -1;
    // Slice must start on a page so mmap(offset=slice_off) is valid.
    if (s->slice_off % pg) { res->mmap_errno = EINVAL; return -1; }

    // Map only the aligned remap window (unified exact + padded). On 16 KB devices,
    // LC cryptoff may be 4 KB-aligned — fp_map_window_for_crypt aligns without
    // hard-rejecting, and never maps leading unencrypted bytes before remap_off.
    uint64_t remap_off = 0, remap_len = 0, map_file_off = 0, map_len = 0, read_bias = 0;
    if (!fp_map_window_for_crypt(s->slice_off, s->cryptoff, s->cryptsize, s->slice_size, pg,
                                 &map_file_off, &map_len, &read_bias, &remap_off, &remap_len)) {
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

    uint8_t *base = mmap(NULL, (size_t)map_len, prot, MAP_PRIVATE | MAP_NOCACHE, fd, (off_t)map_file_off);
    if (base == MAP_FAILED) {
        res->mmap_errno = errno;
        fp_note_errno(errno);
        close(fd);
        res->ms = now_ms() - t0;
        return -1;
    }

    // Caller usually passes a lean/file-backed `out`. When absent, allocate once —
    // never a second full cipher buffer here.
    uint8_t *dec = out ? out : malloc(s->cryptsize);
    uint8_t *page_cipher = malloc((size_t)pg);
    if (!dec || !page_cipher) {
        if (!out) free(dec); free(page_cipher);
        munmap(base, (size_t)map_len); close(fd);
        res->mmap_errno = ENOMEM; fp_set_fail(FP_FAIL_NOMEM); res->ms = now_ms() - t0; return -1;
    }

    uint64_t total = (s->cryptsize + pg - 1) / pg;
    if (total == 0) total = 1;
    res->pages_total = total;

    uint8_t *okmask = calloc((size_t)total, 1);
    if (!okmask) {
        if (!out) free(dec); free(page_cipher);
        munmap(base, (size_t)map_len); close(fd);
        res->mmap_errno = ENOMEM; fp_set_fail(FP_FAIL_NOMEM); res->ms = now_ms() - t0; return -1;
    }

    // Stream seed: only first/mid/last pages for heuristics — do NOT fault the
    // entire crypt into RSS before mremap (that alone Jetsams ~20 MB mains).
    const bool stream_capture = FP_FORCE_LEAN || fp_memory_tight_for(s->cryptsize);
    {
        uint64_t sample = s->cryptsize < pg ? s->cryptsize : pg;
        uint64_t mid = (total / 2) * pg;
        if (mid + sample > s->cryptsize) mid = s->cryptsize > sample ? s->cryptsize - sample : 0;
        uint64_t last = s->cryptsize > sample ? s->cryptsize - sample : 0;
        uint64_t offs[3] = { 0, mid, last };
        for (int si = 0; si < 3; si++) {
            if (!pread_full(fd, dec + offs[si], (size_t)sample,
                            (off_t)(s->slice_off + s->cryptoff + offs[si]))) {
                free(okmask); if (!out) free(dec); free(page_cipher);
                munmap(base, (size_t)map_len); close(fd);
                res->mmap_errno = EIO; fp_set_fail(FP_FAIL_IO); res->ms = now_ms() - t0; return -1;
            }
        }
        // Remaining pages stay uninitialized until streamed page capture fills them
        // (failed pages are re-seeded from disk one page at a time below).
        if (!stream_capture) {
            // Classic path (Mac / roomy): seed the rest so merge compares are cheap.
            for (uint64_t p = 0; p < total; p++) {
                uint64_t off = p * pg;
                if (off == 0 || off == mid || off == last) continue;
                uint64_t nbytes = (off + pg <= s->cryptsize) ? pg : (s->cryptsize - off);
                if (!pread_full(fd, dec + off, (size_t)nbytes,
                                (off_t)(s->slice_off + s->cryptoff + off))) {
                    free(okmask); if (!out) free(dec); free(page_cipher);
                    munmap(base, (size_t)map_len); close(fd);
                    res->mmap_errno = EIO; fp_set_fail(FP_FAIL_IO); res->ms = now_ms() - t0; return -1;
                }
            }
        }
    }
    sample_code_entropy(dec, s->cryptsize, pg, &res->ret_before, &res->ent_before);

    // Guarded remapping retry: when fairplayd flakes mid page-in, unmap + mremap again
    // and re-read only failed pages. Extra rounds when we are making progress.
    uint64_t prev_ok = 0;
    const int max_rounds = 5;
    for (int round = 0; round < max_rounds; round++) {
        if (round > 0) {
            if (base != MAP_FAILED) munmap(base, (size_t)map_len);
            usleep((useconds_t)(40 * 1000 * round));
            base = mmap(NULL, (size_t)map_len, prot, MAP_PRIVATE | MAP_NOCACHE, fd, (off_t)map_file_off);
            if (base == MAP_FAILED) { res->mmap_errno = errno; fp_note_errno(errno); break; }
        }
        errno = 0;
        int mr = do_mremap_encrypted(base, (size_t)map_len, cid, s->cputype, s->cpusubtype);
        res->mremap_ret = mr;
        res->mremap_errno = mr == 0 ? 0 : errno;
        if (mr != 0) {
            fp_note_errno(errno);
            if (errno == ENOMEM || errno == EPERM || errno == EACCES) break;
            continue;
        }

        // Stream page capture: touch + read + DONTNEED one page at a time.
        // Never MADV_WILLNEED multi-MB runs on device — that re-Jetsams the window.
        uint64_t pages_ok = 0;
        int first_kr = 0;
        uint64_t first_off = 0;
        for (uint64_t i = 0; i < total; i++) {
            if (okmask[i]) { pages_ok++; continue; }
            uint64_t off = i * pg;
            uint64_t n = (off + pg <= s->cryptsize) ? pg : (s->cryptsize - off);
            // Seed this page with ciphertext so a failed read leaves merge-friendly bytes.
            if (stream_capture) {
                if (!pread_full(fd, dec + off, (size_t)n,
                                (off_t)(s->slice_off + s->cryptoff + off))) {
                    continue;
                }
            }
#ifdef MADV_WILLNEED
            (void)madvise(base + read_bias + off, (size_t)pg, MADV_WILLNEED);
#else
            {
                volatile uint8_t touch = base[read_bias + off];
                (void)touch;
            }
#endif
            if (fp_read_crypt_page(base, read_bias, i, pg, s->cryptsize, dec,
                                   &first_kr, &first_off, s->cryptoff)) {
                // Confirm the page actually transformed vs on-disk ciphertext.
                if (!pread_full(fd, page_cipher, (size_t)n,
                               (off_t)(s->slice_off + s->cryptoff + off))) {
                    okmask[i] = 1;
                    pages_ok++;
                } else if (memcmp(dec + off, page_cipher, (size_t)n) != 0) {
                    okmask[i] = 1;
                    pages_ok++;
                } else {
                    // Remap "succeeded" but page still ciphertext — not ok so later
                    // modes / rounds can recover (missing keys often look like this).
                    if (!first_kr) { first_kr = -2; first_off = s->cryptoff + off; }
                }
            }
#ifdef MADV_DONTNEED
            // Drop the remapped page from RSS once plaintext is in `dec` (or failed).
            (void)madvise(base + read_bias + off, (size_t)pg, MADV_DONTNEED);
#endif
        }
        res->pages_ok = pages_ok;
        if (first_kr && !res->first_fail_kr) {
            res->first_fail_kr = first_kr;
            res->first_fail_off = first_off;
        }
        if (pages_ok == total) break;
        // Stop early if a remount round made no progress.
        if (round > 0 && pages_ok <= prev_ok) break;
        prev_ok = pages_ok;
    }

    free(okmask);
    if (res->mremap_ret == 0 && res->pages_ok > 0) {
        res->changed = true; // ok pages already differ from ciphertext
        // Only sample after a full capture — mid/last may be unseeded mid-stream.
        if (res->pages_ok == total) {
            sample_code_entropy(dec, s->cryptsize, pg, &res->ret_after, &res->ent_after);
        }
    } else if (res->mremap_ret == 0 && res->pages_ok == 0) {
        // fairplayd accepted remmap but every page stayed ciphertext → keys/license.
        res->changed = false;
        fp_set_fail(FP_FAIL_PERM);
    }
    free(page_cipher);

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
    // Never treat partial page-in as fully decrypted — merge across modes instead.
    if (!(a->mremap_ret == 0 && a->pages_ok == a->pages_total && a->changed)) return false;
    bool entropy_ok = (a->ent_before > 7.85 && a->ent_after < 7.55) ||
                      (a->ent_before - a->ent_after) > 0.35 ||
                      (a->ent_before > 7.7 && a->ent_after < 7.4);
    bool code_ok = a->ret_after > a->ret_before;
    // Full transform with moderate entropy drop is enough — some frameworks are small
    // and already low-entropy in ciphertext after packing.
    bool full_transform = a->changed && a->pages_ok == a->pages_total &&
                          (a->ent_before - a->ent_after) > 0.15;
    // Sample-only lean path: ret/entropy may be from first/mid/last page probes —
    // still require full page-in + changed before clearing cryptid.
    bool sample_ok = a->pages_ok == a->pages_total && a->changed &&
                     (a->ret_after > 0 || a->ent_after < 7.8);
    return entropy_ok || code_ok || full_transform || sample_ok;
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
    g_fp_last_fail = FP_FAIL_NONE;
    fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256] = {0};
    if (fp_parse(in_path, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0) {
        logf_(log, ctx, "  parse failed: %s", err);
        fp_set_fail(FP_FAIL_IO);
        return -1;
    }
    bool any = false;
    for (int i = 0; i < n; i++) if (sl[i].has_enc && sl[i].cryptid) any = true;
    if (strcmp(in_path, out_path) != 0 && copy_file(in_path, out_path) != 0) {
        logf_(log, ctx, "  copy failed: %s", strerror(errno));
        fp_note_errno(errno);
        return -1;
    }
    if (!any) return 1;

    int out = open(out_path, O_RDWR);
    if (out < 0) {
        logf_(log, ctx, "  open out: %s", strerror(errno));
        fp_note_errno(errno);
        return -1;
    }

    // Resolve mremap backend once so logs show dlsym vs svc (not silent).
    {
        int backend = 0;
        const char *rerr = NULL;
        (void)resolve_mremap_encrypted(&backend, &rerr);
        if (rerr) logf_(log, ctx, "  mremap backend=%s (%s)", mremap_backend_name(backend), rerr);
        else logf_(log, ctx, "  mremap backend=%s", mremap_backend_name(backend));
    }

    // Default order: native LC cryptid first, then R/cryptid=2 (no PROT_EXEC), then dyld RX/cid1.
    // Exact-geometry slices prefer R/cid2 first (buddy3 [M] exact dispatch).
    // Each mode is tried with and without F_ADDFILESIGS_RETURN.
    // Kept in sync with tests/fpcore/test_fp_page.c (kExpectedDecryptOrder).
    const int order_default[][2] = {
        {FP_MODE_NATIVE, 0}, {FP_MODE_NATIVE, 1},
        {FP_MODE_R_CID2, 0}, {FP_MODE_R_CID2, 1},
        {FP_MODE_RX_CID1, 0}, {FP_MODE_RX_CID1, 1},
        {FP_MODE_R_CID1, 0}, {FP_MODE_R_CID1, 1}
    };
    const int order_exact[][2] = {
        {FP_MODE_R_CID2, 0}, {FP_MODE_R_CID2, 1},
        {FP_MODE_NATIVE, 0}, {FP_MODE_NATIVE, 1},
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
        const bool exact = fp_crypt_range_is_exact(s->cryptoff, s->cryptsize, s->slice_size, pg);
        if (exact) {
            logf_(log, ctx, "  slice[%d] exact native-page geometry [M] — mapping crypt range directly", i);
        } else if (s->cryptoff % pg) {
            logf_(log, ctx, "  slice[%d] cryptoff 0x%x not page-aligned (page=%llu) — aligning remap to 0x%llx+0x%llx",
                  i, s->cryptoff, (unsigned long long)pg,
                  (unsigned long long)remap_off, (unsigned long long)remap_len);
        }

        const int (*order)[2] = exact ? order_exact : order_default;
        const size_t order_n = exact
            ? (sizeof order_exact / sizeof order_exact[0])
            : (sizeof order_default / sizeof order_default[0]);

        const bool mem_tight = fp_memory_tight_for(s->cryptsize);
        uint64_t page_total = (s->cryptsize + pg - 1) / pg;
        if (page_total == 0) page_total = 1;

        // Classic: cipher + merged + dec (3×). Lean: file-backed mmap of the output
        // crypt range (MAP_SHARED) so the anonymous Jetsam footprint stays near 0×;
        // fall back to one malloc buffer + disk page compares when mmap fails.
        // iPhone always leans — even ~20 MB mains Jetsam on the 3× classic path.
        uint8_t *cipher = NULL;
        uint8_t *merged = NULL;
        uint8_t *dec = NULL;
        bool dec_mapped = false;
        uint8_t *merged_ok = calloc((size_t)page_total, 1);
        uint8_t *page_cipher = malloc((size_t)pg);
        int cin = open(in_path, O_RDONLY);
        bool lean = FP_FORCE_LEAN || mem_tight || s->cryptsize >= (8ull << 20);
        if (!lean) {
            cipher = malloc(s->cryptsize);
            merged = malloc(s->cryptsize);
            if (!cipher || !merged) {
                free(cipher); free(merged);
                cipher = merged = NULL;
                lean = true;
            }
        }
        if (lean) {
            void *map = mmap(NULL, (size_t)s->cryptsize, PROT_READ | PROT_WRITE, MAP_SHARED,
                             out, (off_t)(s->slice_off + s->cryptoff));
            if (map != MAP_FAILED) {
                dec = (uint8_t *)map;
                dec_mapped = true;
            } else {
                dec = malloc(s->cryptsize);
            }
        } else {
            dec = malloc(s->cryptsize);
        }
        bool cipher_ok = false;
        if (!lean && cin >= 0 && cipher) {
            cipher_ok = pread_full(cin, cipher, s->cryptsize,
                                   (off_t)(s->slice_off + s->cryptoff));
        }
        if (!dec || !merged_ok || !page_cipher || cin < 0 || (!lean && !cipher_ok)) {
            logf_(log, ctx, "  slice[%d] buffer alloc/read failed (ENOMEM?)", i);
            if (dec_mapped) munmap(dec, (size_t)s->cryptsize); else free(dec);
            free(cipher); free(merged); free(merged_ok); free(page_cipher);
            if (cin >= 0) close(cin);
            fp_set_fail(FP_FAIL_NOMEM);
            rc = -1; break;
        }
        if (lean) {
            logf_(log, ctx,
                  "  slice[%d] streamed lean for %.1f MB crypt — %s + per-page capture",
                  i, (double)s->cryptsize / (1024.0 * 1024.0),
                  dec_mapped ? "file-backed mmap dec" : "1× buffer");
        }
        if (!lean) memcpy(merged, cipher, s->cryptsize);
        logf_(log, ctx, "  slice[%d] map window pages≈%llu chunk_hint=%llu%s",
              i, (unsigned long long)page_total,
              (unsigned long long)fp_suggested_chunk_pages(s->cryptsize, pg),
              lean ? " (lean)" : "");

        bool done = false;
        fp_attempt_t best; memset(&best, 0, sizeof best); best.mremap_ret = -1;
        uint64_t merged_pages = 0;
        // Lean: one retry per mode is enough — fp_attempt already remounts internally.
        // Burning 3×8 full-window remmaps after ENOMEM is what Jetsams ~20 MB mains.
        const int tries_per_mode = lean ? 2 : 2;
        bool enomem_bail = false;

        for (size_t k = 0; k < order_n && !done && !enomem_bail; k++) {
            fp_attempt_t a; char d[512];
            for (int attempt = 0; attempt < tries_per_mode && !done && !enomem_bail; attempt++) {
                if (attempt) {
                    // Longer backoff under lean / ENOMEM so Jetsam can reclaim.
                    unsigned usec = lean ? (180 * 1000 * (attempt + 1)) : (40 * 1000 * attempt);
                    usleep((useconds_t)usec);
                    // Drop dirty lean pages before the next remmap so peak isn't
                    // file-backed crypt RSS + MAP_PRIVATE remap window.
                    if (lean && dec_mapped) {
                        (void)msync(dec, (size_t)s->cryptsize, MS_SYNC);
#ifdef MADV_DONTNEED
                        (void)madvise(dec, (size_t)s->cryptsize, MADV_DONTNEED);
#endif
                    }
                    malloc_zone_pressure_relief(NULL, 0);
                }
                // Seed attempt buffer: classic copies full cipher. Lean must NOT
                // pread the whole crypt into `dec` before mremap — that alone
                // Jetsams Host-class ~20 MB mains. fp_attempt samples + per-page
                // seeds during capture.
                if (!lean) {
                    memcpy(dec, cipher, s->cryptsize);
                }
                fp_attempt(in_path, s, order[k][0], order[k][1], dec, &a);
                if (a.pages_ok > best.pages_ok || (a.pages_ok == best.pages_ok && a.changed && !best.changed))
                    best = a;
                // First ENOMEM: one purge+retry on this mode, then stop the storm.
                if (a.mremap_errno == ENOMEM || a.mmap_errno == ENOMEM) {
                    fp_set_fail(FP_FAIL_NOMEM);
                    if (attempt + 1 < tries_per_mode) {
                        logf_(log, ctx,
                              "  slice[%d] mremap ENOMEM — reclaiming once then retry…", i);
                        continue;
                    }
                    logf_(log, ctx,
                          "  slice[%d] mremap ENOMEM — stopping mode storm (Jetsam)", i);
                    enomem_bail = true;
                    break;
                }
                // Merge pages that transformed vs ciphertext.
                if (a.mremap_ret == 0 && a.pages_ok > 0) {
                    for (uint64_t p = 0; p < page_total; p++) {
                        if (merged_ok[p]) continue;
                        uint64_t off = p * pg;
                        uint64_t nbytes = (off + pg <= s->cryptsize) ? pg : (s->cryptsize - off);
                        bool transformed = false;
                        if (!lean) {
                            transformed = memcmp(dec + off, cipher + off, (size_t)nbytes) != 0;
                            if (transformed) memcpy(merged + off, dec + off, (size_t)nbytes);
                        } else {
                            if (!pread_full(cin, page_cipher, (size_t)nbytes,
                                            (off_t)(s->slice_off + s->cryptoff + off))) {
                                continue;
                            }
                            transformed = memcmp(dec + off, page_cipher, (size_t)nbytes) != 0;
                            // Persist good pages immediately so we don't need a merged buffer.
                            if (transformed) {
                                if (!pwrite_full(out, dec + off, (size_t)nbytes,
                                                 (off_t)(s->slice_off + s->cryptoff + off))) {
                                    fp_set_fail(FP_FAIL_IO);
                                }
                            }
                        }
                        if (transformed) merged_ok[p] = 1;
                    }
                    merged_pages = 0;
                    for (uint64_t p = 0; p < page_total; p++) if (merged_ok[p]) merged_pages++;
                }
                fp_attempt_describe(&a, d, sizeof d);
                done = attempt_looks_decrypted(&a);
                if (!done && merged_pages == page_total) {
                    // All pages already persisted — do NOT pread the full crypt into RSS.
                    a.pages_ok = page_total;
                    a.pages_total = page_total;
                    a.changed = 1;
                    if (!lean) {
                        memcpy(dec, merged, s->cryptsize);
                        a.ret_after = code_words(dec, s->cryptsize);
                        a.ent_after = entropy(dec, s->cryptsize);
                        a.ret_before = code_words(cipher, s->cryptsize);
                        a.ent_before = entropy(cipher, s->cryptsize);
                    } else {
                        // Stream heuristic: sample first / middle / last page only.
                        uint64_t sample = s->cryptsize < pg ? s->cryptsize : pg;
                        uint64_t mid = (page_total / 2) * pg;
                        if (mid + sample > s->cryptsize) mid = s->cryptsize > sample ? s->cryptsize - sample : 0;
                        uint64_t last = s->cryptsize > sample ? s->cryptsize - sample : 0;
                        uint32_t ret_b = 0, ret_a = 0;
                        double ent_b = 0, ent_a = 0;
                        int samples = 0;
                        uint64_t offs[3] = { 0, mid, last };
                        for (int si = 0; si < 3; si++) {
                            if (!pread_full(cin, page_cipher, (size_t)sample,
                                            (off_t)(s->slice_off + s->cryptoff + offs[si]))) {
                                continue;
                            }
                            ret_b += code_words(page_cipher, sample);
                            ent_b += entropy(page_cipher, sample);
                            // Plaintext lives in out (and MAP_SHARED dec when mapped).
                            uint8_t page_plain[16384];
                            size_t take = sample > sizeof(page_plain) ? sizeof(page_plain) : (size_t)sample;
                            if (!pread_full(out, page_plain, take,
                                            (off_t)(s->slice_off + s->cryptoff + offs[si]))) {
                                continue;
                            }
                            ret_a += code_words(page_plain, take);
                            ent_a += entropy(page_plain, take);
                            samples++;
                        }
                        if (samples > 0) {
                            a.ret_before = ret_b / (uint32_t)samples;
                            a.ret_after = ret_a / (uint32_t)samples;
                            a.ent_before = ent_b / (double)samples;
                            a.ent_after = ent_a / (double)samples;
                        }
                    }
                    done = attempt_looks_decrypted(&a);
                    if (done) best = a;
                }
                logf_(log, ctx, "  slice[%d] try%zu.%d %s %s (merged %llu/%llu%s%s)",
                      i, k, attempt, done ? "[DECRYPTED]" : "[--]", d,
                      (unsigned long long)merged_pages, (unsigned long long)page_total,
                      exact ? ", exact" : "", lean ? ", lean" : "");
            }
        }
        if (!done && merged_pages == page_total) {
            // Pages already on disk via lean pwrite / classic merged — no full reload.
            if (!lean) memcpy(dec, merged, s->cryptsize);
            done = true;
            logf_(log, ctx, "  slice[%d] recovered via merged pages across modes%s",
                  i, lean ? " (lean/out-file)" : "");
        }
        if (!done) {
            char d[512];
            fp_attempt_describe(&best, d, sizeof d);
            logf_(log, ctx, "  slice[%d] FAILED after all modes; best: %s (merged %llu/%llu)",
                  i, d, (unsigned long long)merged_pages, (unsigned long long)page_total);
            if (enomem_bail || best.mremap_errno == ENOMEM || best.mmap_errno == ENOMEM)
                fp_set_fail(FP_FAIL_NOMEM);
            else if (best.mremap_errno == EPERM || best.mremap_errno == EACCES) fp_set_fail(FP_FAIL_PERM);
            else if (best.mremap_ret == 0 && !best.changed) fp_set_fail(FP_FAIL_PERM);
            else if (g_fp_last_fail == FP_FAIL_NONE) fp_set_fail(FP_FAIL_STILL_ENC);
            rc = -1;
            if (dec_mapped) munmap(dec, (size_t)s->cryptsize); else free(dec);
            free(cipher); free(merged); free(merged_ok); free(page_cipher);
            close(cin);
            break;
        }
        if (!lean && merged_pages == page_total) memcpy(dec, merged, s->cryptsize);
        uint32_t zero = 0;
        // File-backed lean already holds plaintext in the MAP_SHARED region; still
        // rewrite cryptid. Non-mapped lean / classic rewrite the full crypt range.
        if (!dec_mapped) {
            if (!pwrite_full(out, dec, s->cryptsize, (off_t)(s->slice_off + s->cryptoff))) {
                logf_(log, ctx, "  write failed: %s", strerror(errno)); rc = -1;
            }
        } else {
            // Ensure dirty mmap pages hit disk before we clear cryptid.
            (void)msync(dec, (size_t)s->cryptsize, MS_SYNC);
        }
        if (rc == 0 && !pwrite_full(out, &zero, 4,
                (off_t)(s->enc_lc_off + offsetof(struct encryption_info_command, cryptid)))) {
            logf_(log, ctx, "  write failed: %s", strerror(errno)); rc = -1;
        }
        if (dec_mapped) munmap(dec, (size_t)s->cryptsize); else free(dec);
        free(cipher); free(merged); free(merged_ok); free(page_cipher);
        close(cin);
    }
    if (rc == 0) {
        fsync(out);
    }
    close(out);
    if (rc == 0) {
        // Fail closed: refuse to return success if any slice still reports cryptid ≠ 0.
        int still = fp_has_encrypted_slice(out_path);
        if (still != 0) {
            logf_(log, ctx, "  verify failed: output still encrypted (status=%d)", still);
            fp_set_fail(FP_FAIL_STILL_ENC);
            rc = -1;
        } else {
            logf_(log, ctx, "  verify ok: cryptid=0 on all slices");
            g_fp_last_fail = FP_FAIL_NONE;
        }
    }
    return rc;
}
