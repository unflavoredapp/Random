// Pure page-window helpers for mremap_encrypted (host-testable, no Darwin deps).
// Brand: Tetherless · https://tetherless.dev
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

/// True when the crypt range is already a whole-number of native pages (buddy3 [M] exact path).
static inline bool fp_crypt_range_is_exact(
    uint64_t cryptoff,
    uint64_t cryptsize,
    uint64_t slice_size,
    uint64_t page
) {
    if (!page || !cryptsize) return false;
    if (cryptoff % page) return false;
    if (cryptsize % page) return false;
    if (cryptoff > UINT64_MAX - cryptsize) return false;
    return cryptoff + cryptsize <= slice_size;
}

/// Suggested page-in / merge window size in pages (~4 MiB), capped to the crypt range.
/// Used for streaming ciphertext compares and progressive remount reads — not for
/// splitting mremap_encrypted itself (fairplayd wants the full LC window).
static inline uint64_t fp_suggested_chunk_pages(uint64_t cryptsize, uint64_t page) {
    if (!page || !cryptsize) return 0;
    uint64_t target_bytes = 4ull << 20; // 4 MiB
    uint64_t target = target_bytes / page;
    if (target < 16) target = 16;
    uint64_t total = (cryptsize + page - 1) / page;
    return total < target ? total : target;
}

/// File offset + length to mmap for an aligned remap window covering the crypt range.
/// Always maps only [remap_off, remap_off+remap_len) under the slice — never the
/// leading unencrypted bytes before remap_off (saves RSS on large binaries).
static inline bool fp_map_window_for_crypt(
    uint64_t slice_off,
    uint64_t cryptoff,
    uint64_t cryptsize,
    uint64_t slice_size,
    uint64_t page,
    uint64_t *map_file_off,
    uint64_t *map_len,
    uint64_t *read_bias,
    uint64_t *remap_off,
    uint64_t *remap_len
) {
    if (!map_file_off || !map_len || !read_bias || !remap_off || !remap_len) return false;
    if (!fp_compute_remap_window(cryptoff, cryptsize, slice_size, page, remap_off, remap_len)) {
        return false;
    }
    if (cryptoff < *remap_off) return false;
    *map_file_off = slice_off + *remap_off;
    *map_len = *remap_len;
    *read_bias = cryptoff - *remap_off;
    return *map_len > 0;
}
