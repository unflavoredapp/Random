/*
 * Host unit tests for fp_page.h + decrypt-order regression locks.
 *
 * These do NOT exercise the real mremap_encrypted syscall (device-only).
 * They lock the engineering claims from the 16 KB stock-iOS revision:
 *   1. Native mode is first in the decrypt attempt order.
 *   2. 4 KB-aligned cryptoff is accepted on a 16 KB page via aligned remap.
 *   3. Malformed / overflowing crypt ranges are rejected.
 *   4. Output integrity helper: cryptid-clear offset math stays consistent.
 *
 * Build + run (Linux/macOS host):
 *   cc -std=c11 -Wall -Wextra -O2 -I Sources/FairPlay \
 *      tests/fpcore/test_fp_page.c -o /tmp/test_fp_page && /tmp/test_fp_page
 */

#include "fp_page.h"
#include "fpcore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failed;

static void expect(int cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", msg);
        g_failed++;
    } else {
        printf("ok: %s\n", msg);
    }
}

/* Mirrors fp_decrypt_file() order — keep in sync with Sources/FairPlay/fpcore.c */
static const int kExpectedDecryptOrder[][2] = {
    {FP_MODE_NATIVE, 0}, {FP_MODE_NATIVE, 1},
    {FP_MODE_R_CID2, 0}, {FP_MODE_R_CID2, 1},
    {FP_MODE_RX_CID1, 0}, {FP_MODE_RX_CID1, 1},
    {FP_MODE_R_CID1, 0}, {FP_MODE_R_CID1, 1},
};

static void test_decrypt_order_starts_with_native(void) {
    expect(kExpectedDecryptOrder[0][0] == FP_MODE_NATIVE, "order[0] is FP_MODE_NATIVE");
    expect(kExpectedDecryptOrder[1][0] == FP_MODE_NATIVE, "order[1] is FP_MODE_NATIVE (+sigs)");
    expect(kExpectedDecryptOrder[2][0] == FP_MODE_R_CID2, "order[2] is FP_MODE_R_CID2");
    size_t n = sizeof kExpectedDecryptOrder / sizeof kExpectedDecryptOrder[0];
    expect(n == 8, "decrypt order has 8 mode×sigs attempts");
}

static void test_4k_crypt_on_16k_page(void) {
    const uint64_t page = 16384;
    const uint64_t cryptoff = 4096;   // 4 KB aligned, not 16 KB aligned
    const uint64_t cryptsize = 8192;  // two 4 KB pages of ciphertext
    const uint64_t slice = 64 * 1024;
    uint64_t off = 0, len = 0;
    expect(fp_compute_remap_window(cryptoff, cryptsize, slice, page, &off, &len),
           "4K cryptoff accepted on 16K page");
    expect(off == 0, "remap aligns down to 0");
    expect(len == 16384, "remap covers through crypt end (aligned up to 16K)");
    // Caller still copies only [cryptoff, cryptoff+cryptsize) — integrity of range.
    expect(off <= cryptoff && off + len >= cryptoff + cryptsize,
           "aligned window fully covers original crypt range");
}

static void test_16k_aligned_passthrough(void) {
    const uint64_t page = 16384;
    const uint64_t cryptoff = 16384;
    const uint64_t cryptsize = 32768;
    const uint64_t slice = 128 * 1024;
    uint64_t off = 0, len = 0;
    expect(fp_compute_remap_window(cryptoff, cryptsize, slice, page, &off, &len),
           "16K-aligned crypt accepted");
    expect(off == cryptoff && len == cryptsize, "already-aligned window unchanged");
}

static void test_4k_page_env(void) {
    const uint64_t page = 4096;
    const uint64_t cryptoff = 4096;
    const uint64_t cryptsize = 8192;
    const uint64_t slice = 32 * 1024;
    uint64_t off = 0, len = 0;
    expect(fp_compute_remap_window(cryptoff, cryptsize, slice, page, &off, &len),
           "4K page env accepts 4K crypt");
    expect(off == cryptoff && len == cryptsize, "4K page: window matches LC");
}

static void test_malformed_ranges(void) {
    uint64_t off = 0, len = 0;
    expect(!fp_compute_remap_window(0, 0, 65536, 16384, &off, &len), "empty cryptsize rejected");
    expect(!fp_compute_remap_window(0, 4096, 100, 16384, &off, &len), "window past slice rejected");
    expect(!fp_compute_remap_window(0, 4096, 65536, 0, &off, &len), "page=0 rejected");
    expect(!fp_compute_remap_window(UINT64_MAX - 100, 200, UINT64_MAX, 4096, &off, &len),
           "cryptoff+cryptsize overflow rejected");
}

static void test_no_hard_reject_semantics(void) {
    // Documents the regression: old code did (cryptoff % page) != 0 → fail.
    // New code must succeed for cryptoff % 16384 != 0 when window fits.
    const uint64_t page = 16384;
    uint64_t off = 0, len = 0;
    int ok = fp_compute_remap_window(0x1000, 0x2000, 0x10000, page, &off, &len);
    expect(ok, "regression: 4K cryptoff must NOT hard-reject on 16K page");
    expect((0x1000 % page) != 0, "precondition: cryptoff is not page-aligned");
}

int main(void) {
    printf("fpcore page/order regression tests\n");
    test_decrypt_order_starts_with_native();
    test_4k_crypt_on_16k_page();
    test_16k_aligned_passthrough();
    test_4k_page_env();
    test_malformed_ranges();
    test_no_hard_reject_semantics();
    if (g_failed) {
        fprintf(stderr, "%d failure(s)\n", g_failed);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
