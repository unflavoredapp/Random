#pragma once
#include <stddef.h>
#include <thread>
#include <vector>
#include <atomic>
#define DISPATCH_APPLY_AUTO 0
// Real concurrency so the parallel paths are exercised like on iOS.
static inline void dispatch_apply(size_t n, int, void (^block)(size_t))
{
    std::atomic<size_t> next(0);
    unsigned w = std::thread::hardware_concurrency(); if (w < 2) w = 2; if (w > 8) w = 8;
    std::vector<std::thread> ts;
    for (unsigned t = 0; t < w; t++) ts.emplace_back([&]{ for (size_t i; (i = next.fetch_add(1)) < n; ) block(i); });
    for (auto &t : ts) t.join();
}
