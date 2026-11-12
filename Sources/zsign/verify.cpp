#include "verify.h"
#include <openssl/sha.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <vector>

using std::string;
using std::vector;

namespace {

const uint32_t kFatMagic = 0xcafebabe;      // big-endian on disk
const uint32_t kMH = 0xfeedface, kMH64 = 0xfeedfacf;
const uint32_t kLCCodeSignature = 0x1d;
const uint32_t kSuperBlob = 0xfade0cc0, kCodeDirectory = 0xfade0c02, kBlobWrapper = 0xfade0b01;
const uint32_t kSlotCD = 0, kSlotAltCD = 0x1000, kSlotAltCDEnd = 0x1005, kSlotCMS = 0x10000;

uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
uint32_t le32(const uint8_t *p) { return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0]; }

bool preadAll(int fd, uint8_t *buf, size_t len, uint64_t off)
{
    size_t done = 0;
    while (done < len)
    {
        ssize_t n = pread(fd, buf + done, len - done, (off_t)(off + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        done += (size_t)n;
    }
    return true;
}

bool hashFile(const string &path, uint8_t sha1[20], uint8_t sha256[32])
{
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    SHA_CTX c1; SHA256_CTX c2;
    SHA1_Init(&c1); SHA256_Init(&c2);
    vector<uint8_t> buf(1 << 20);
    bool ok = true;
    for (;;)
    {
        ssize_t n = read(fd, buf.data(), buf.size());
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = false; break; }
        if (n == 0) break;
        SHA1_Update(&c1, buf.data(), (size_t)n);
        SHA256_Update(&c2, buf.data(), (size_t)n);
    }
    close(fd);
    if (!ok) return false;
    SHA1_Final(sha1, &c1);
    SHA256_Final(sha256, &c2);
    return true;
}

struct CD
{
    uint8_t hashType = 0, hashSize = 0, pageShift = 0;
    uint32_t nSpecial = 0, nCode = 0, codeLimit = 0;
    const uint8_t *specialEnd = nullptr;   // == start of code slots; special slot k is at specialEnd - k*hashSize
    const uint8_t *codeSlots = nullptr;
};

string fmt(const char *f, ...)
{
    char b[512];
    va_list a; va_start(a, f); vsnprintf(b, sizeof(b), f, a); va_end(a);
    return b;
}

bool verifySlice(int fd, uint64_t sliceOff, uint64_t sliceSize,
                 const uint8_t *infoSHA1, const uint8_t *infoSHA256,
                 const uint8_t *resSHA1, const uint8_t *resSHA256,
                 string &err)
{
    uint8_t hdr[32];
    if (sliceSize < 32 || !preadAll(fd, hdr, 32, sliceOff)) { err = "slice header unreadable"; return false; }
    uint32_t magic = le32(hdr);
    if (magic != kMH && magic != kMH64) { err = fmt("unsupported Mach-O magic 0x%08x", magic); return false; }
    uint32_t hdrSize = (magic == kMH64) ? 32 : 28;
    uint32_t ncmds = le32(hdr + 16), sizeofcmds = le32(hdr + 20);
    if ((uint64_t)hdrSize + sizeofcmds > sliceSize || sizeofcmds > (64u << 20)) { err = "load commands out of bounds"; return false; }

    vector<uint8_t> cmds(sizeofcmds);
    if (sizeofcmds && !preadAll(fd, cmds.data(), sizeofcmds, sliceOff + hdrSize)) { err = "load commands unreadable"; return false; }

    uint32_t dataoff = 0, datasize = 0; bool found = false;
    uint32_t pos = 0;
    for (uint32_t i = 0; i < ncmds; i++)
    {
        if (pos + 8 > sizeofcmds) { err = "load command table truncated"; return false; }
        uint32_t cmd = le32(&cmds[pos]), cmdsize = le32(&cmds[pos + 4]);
        if (cmdsize < 8 || pos + cmdsize > sizeofcmds) { err = "bad load command size"; return false; }
        if (cmd == kLCCodeSignature && cmdsize >= 16)
        {
            dataoff = le32(&cmds[pos + 8]); datasize = le32(&cmds[pos + 12]); found = true;
        }
        pos += cmdsize;
    }
    if (!found) { err = "no LC_CODE_SIGNATURE (binary is unsigned)"; return false; }
    if (dataoff == 0 || datasize < 12 || (uint64_t)dataoff + datasize > sliceSize || datasize > (256u << 20))
    { err = fmt("signature region out of bounds (off %u size %u slice %llu)", dataoff, datasize, (unsigned long long)sliceSize); return false; }

    vector<uint8_t> sig(datasize);
    if (!preadAll(fd, sig.data(), datasize, sliceOff + dataoff)) { err = "signature unreadable"; return false; }
    if (be32(&sig[0]) != kSuperBlob) { err = "signature is not an embedded SuperBlob"; return false; }
    uint32_t sbLen = be32(&sig[4]), count = be32(&sig[8]);
    if (sbLen > datasize || sbLen < 12 || 12ull + (uint64_t)count * 8 > sbLen) { err = "SuperBlob header corrupt"; return false; }

    vector<CD> cds; bool haveCMS = false;
    for (uint32_t i = 0; i < count; i++)
    {
        uint32_t type = be32(&sig[12 + i * 8]), off = be32(&sig[16 + i * 8]);
        if ((uint64_t)off + 8 > sbLen) { err = "blob index out of bounds"; return false; }
        const uint8_t *b = &sig[off];
        uint32_t bmagic = be32(b), blen = be32(b + 4);
        if (blen < 8 || (uint64_t)off + blen > sbLen) { err = "blob length out of bounds"; return false; }
        if (type == kSlotCMS) { haveCMS = (bmagic == kBlobWrapper && blen > 8); continue; }
        if (type != kSlotCD && !(type >= kSlotAltCD && type < kSlotAltCDEnd)) continue;
        if (bmagic != kCodeDirectory || blen < 44) { err = "CodeDirectory blob corrupt"; return false; }
        CD cd;
        uint32_t hashOffset = be32(b + 16);
        cd.nSpecial = be32(b + 24); cd.nCode = be32(b + 28); cd.codeLimit = be32(b + 32);
        cd.hashSize = b[36]; cd.hashType = b[37]; cd.pageShift = b[39];
        if (!((cd.hashType == 1 && cd.hashSize == 20) || (cd.hashType == 2 && cd.hashSize == 32)))
        { err = fmt("unsupported CodeDirectory hash (type %u size %u)", cd.hashType, cd.hashSize); return false; }
        if (cd.pageShift < 12 || cd.pageShift > 16) { err = fmt("unexpected page size 2^%u", cd.pageShift); return false; }
        if ((uint64_t)hashOffset + (uint64_t)cd.nCode * cd.hashSize > blen || (uint64_t)cd.nSpecial * cd.hashSize > hashOffset)
        { err = "CodeDirectory hash table out of bounds"; return false; }
        if (cd.codeLimit != dataoff)
        { err = fmt("CodeDirectory covers %u bytes but the signature starts at %u", cd.codeLimit, dataoff); return false; }
        uint64_t page = 1ull << cd.pageShift;
        uint64_t want = ((uint64_t)cd.codeLimit + page - 1) / page;
        if (cd.nCode != want) { err = fmt("CodeDirectory has %u page hashes, expected %llu", cd.nCode, (unsigned long long)want); return false; }
        cd.codeSlots = b + hashOffset;
        cd.specialEnd = cd.codeSlots;
        cds.push_back(cd);
    }
    if (cds.empty()) { err = "no CodeDirectory in signature"; return false; }
    if (!haveCMS) { err = "CMS signature blob missing"; return false; }

    // Special slots (1 = Info.plist, 3 = CodeResources). A zero slot means "not bound", which is
    // only acceptable when the caller didn't ask us to check that slot.
    for (const CD &cd : cds)
    {
        const uint8_t *exp1 = (cd.hashType == 1) ? infoSHA1 : infoSHA256;
        const uint8_t *exp3 = (cd.hashType == 1) ? resSHA1 : resSHA256;
        if (exp1)
        {
            if (cd.nSpecial < 1 || memcmp(cd.specialEnd - 1 * cd.hashSize, exp1, cd.hashSize) != 0)
            { err = "Info.plist hash in the signature does not match Info.plist on disk"; return false; }
        }
        if (exp3)
        {
            if (cd.nSpecial < 3 || memcmp(cd.specialEnd - 3 * cd.hashSize, exp3, cd.hashSize) != 0)
            { err = "CodeResources hash in the signature does not match _CodeSignature/CodeResources on disk"; return false; }
        }
    }

    // Page hashes: one streaming pass, every CD checked against the same bytes.
    uint32_t shift = cds[0].pageShift;
    for (const CD &cd : cds) if (cd.pageShift != shift) { err = "CodeDirectories disagree on page size"; return false; }
    const uint64_t page = 1ull << shift, limit = dataoff;
    const uint64_t chunkPages = (1u << 20) / page ? (1u << 20) / page : 1;
    vector<uint8_t> buf((size_t)(chunkPages * page));
    uint64_t pageIndex = 0;
    for (uint64_t off = 0; off < limit; )
    {
        uint64_t len = limit - off; if (len > buf.size()) len = buf.size();
        if (!preadAll(fd, buf.data(), (size_t)len, sliceOff + off)) { err = "code pages unreadable"; return false; }
        for (uint64_t p = 0; p < len; p += page, pageIndex++)
        {
            size_t n = (size_t)((len - p < page) ? (len - p) : page);
            uint8_t h1[20], h2[32]; bool did1 = false, did2 = false;
            for (const CD &cd : cds)
            {
                const uint8_t *slot = cd.codeSlots + pageIndex * cd.hashSize;
                if (cd.hashType == 1) { if (!did1) { SHA1(buf.data() + p, n, h1); did1 = true; } if (memcmp(slot, h1, 20)) { err = fmt("page %llu hash mismatch (SHA-1)", (unsigned long long)pageIndex); return false; } }
                else                  { if (!did2) { SHA256(buf.data() + p, n, h2); did2 = true; } if (memcmp(slot, h2, 32)) { err = fmt("page %llu hash mismatch (SHA-256)", (unsigned long long)pageIndex); return false; } }
            }
        }
        off += len;
    }
    return true;
}

} // namespace

bool TCVerifyMachOFile(const string &strPath, const string &strInfoPlistPath, const string &strCodeResPath, string &strError)
{
    uint8_t i1[20], i2[32], r1[20], r2[32];
    bool haveInfo = false, haveRes = false;
    if (!strInfoPlistPath.empty())
    {
        if (!hashFile(strInfoPlistPath, i1, i2)) { strError = "can't read Info.plist for verification"; return false; }
        haveInfo = true;
    }
    if (!strCodeResPath.empty())
    {
        if (!hashFile(strCodeResPath, r1, r2)) { strError = "can't read CodeResources for verification"; return false; }
        haveRes = true;
    }

    int fd = open(strPath.c_str(), O_RDONLY);
    if (fd < 0) { strError = string("can't open: ") + strerror(errno); return false; }
#ifdef F_NOCACHE
    fcntl(fd, F_NOCACHE, 1);
#endif
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 32) { close(fd); strError = "file too small"; return false; }
    uint64_t fileSize = (uint64_t)st.st_size;

    uint8_t head[8];
    if (!preadAll(fd, head, 8, 0)) { close(fd); strError = "header unreadable"; return false; }

    bool ok = true;
    string err;
    if (be32(head) == kFatMagic)
    {
        uint32_t n = be32(head + 4);
        if (n == 0 || n > 32) { close(fd); strError = "corrupt fat header"; return false; }
        vector<uint8_t> arches(n * 20);
        if (!preadAll(fd, arches.data(), arches.size(), 8)) { close(fd); strError = "fat header unreadable"; return false; }
        for (uint32_t i = 0; i < n && ok; i++)
        {
            uint64_t off = be32(&arches[i * 20 + 8]), size = be32(&arches[i * 20 + 12]);
            if (off + size > fileSize) { ok = false; err = fmt("fat slice %u out of bounds", i); break; }
            ok = verifySlice(fd, off, size, haveInfo ? i1 : nullptr, haveInfo ? i2 : nullptr, haveRes ? r1 : nullptr, haveRes ? r2 : nullptr, err);
            if (!ok) err = fmt("slice %u: ", i) + err;
        }
    }
    else
    {
        ok = verifySlice(fd, 0, fileSize, haveInfo ? i1 : nullptr, haveInfo ? i2 : nullptr, haveRes ? r1 : nullptr, haveRes ? r2 : nullptr, err);
    }
    close(fd);
    if (!ok) strError = err;
    return ok;
}
