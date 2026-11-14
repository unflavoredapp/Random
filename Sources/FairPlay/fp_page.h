// Pure page-window helpers for mremap_encrypted (host-testable, no Darwin deps).
#pragma once
#include <stdint.h>
#include <stdbool.h>

static inline uint64_t fp_align_down(uint64_t v, uint64_t pg) {
    return pg ? (v & ~(pg - 1)) : v;
}

static inline uint64_t fp_align_up(uint64_t v, uint64_t pg) {
    return pg ? ((v + pg - 1) & ~(pg - 1)) : v;
}

/// Compute the page-aligned remap window that covers [cryptoff, cryptoff+cryptsize).
/// Returns false when the window is empty or would extend past slice_size.
/// On success, *remap_off / *remap_len are suitable mremap_encrypted arguments;
/// the caller still copies only the original cryptsize bytes starting at cryptoff.
static inline bool fp_compute_remap_window(
    uint64_t cryptoff,
    uint64_t cryptsize,
    uint64_t slice_size,
    uint64_t page,
    uint64_t *remap_off,
    uint64_t *remap_len
) {
    if (!page || !cryptsize || !remap_off || !remap_len) return false;
    if (cryptoff > UINT64_MAX - cryptsize) return false;
    uint64_t crypt_end = cryptoff + cryptsize;
    uint64_t off = fp_align_down(cryptoff, page);
    uint64_t end = fp_align_up(crypt_end, page);
    if (end <= off || end > slice_size) return false;
    *remap_off = off;
    *remap_len = end - off;
    return true;
}
