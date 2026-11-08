#include "src/capture_image_pool.h"
#include <cassert>
#include <iostream>
#include <limits>
#include <set>
#include <vector>

namespace {
struct Clock {
    using time_point = std::chrono::steady_clock::time_point;
    static inline time_point time {};
    static time_point now() { return time; }
    static void advance() { time += std::chrono::seconds(4); }
};
struct Image {
    int id;
    bool capture_pool_preferred;
    std::set<int>& alive;
    Image(int id, bool preferred, std::set<int>& alive): id(id), capture_pool_preferred(preferred), alive(alive) {
        assert(alive.insert(id).second);
    }
    ~Image() { assert(alive.erase(id) == 1); }
};
using Pool = video::capture_image_pool_t<Image, Clock>;
struct Factory {
    std::set<int> alive;
    int next = 0;
    unsigned preferred_limit = 6;
    bool fail = false;
    std::shared_ptr<Image> operator()() {
        if (fail) return {};
        return std::make_shared<Image>(++next, alive.size() < preferred_limit, alive);
    }
};

void retain_across_bursts() {
    for (std::size_t retain : {0U, 6U}) {
        Factory allocate;
        {
            Pool pool(retain);
            for (unsigned cycle = 0; cycle < 20; ++cycle) {
                std::vector<std::shared_ptr<Image>> consumers;
                for (unsigned i = 0; i < 6; ++i) {
                    auto frame = pool.acquire(allocate);
                    assert(frame);
                    consumers.push_back(frame);
                }
                std::set<int> unique;
                for (const auto& frame : consumers) assert(unique.insert(frame->id).second);
                consumers.clear();
                Clock::advance();
                auto frame = pool.acquire(allocate);
                assert(frame);
                assert(allocate.alive.size() == (retain ? 6 : 1));
            }
            assert(pool.allocation_count == (retain ? 6 : 101));
            assert(pool.retired_count == (retain ? 0 : 100));
            assert(pool.peak_allocated == 6 && pool.unavailable_count == 0);
        }
        assert(allocate.alive.empty());
    }
}

void ownership_and_capacity() {
    Factory allocate;
    Pool pool(6);
    std::vector<std::shared_ptr<Image>> consumers;
    for (unsigned i = 0; i < Pool::capacity; ++i) {
        consumers.push_back(pool.acquire(allocate));
        assert(consumers.back());
        Clock::advance();
    }
    assert(pool.peak_allocated == Pool::capacity);
    assert(!pool.acquire(allocate) && allocate.next == 12 && pool.unavailable_count == 1);
    const auto released = consumers.front()->id;
    consumers.front().reset();
    auto reused = pool.acquire(allocate);
    assert(reused && reused->id == released && allocate.next == 12);
    assert(allocate.alive.size() == 12); // Owned buffers were never retired.
    pool.clear();
    assert(allocate.alive.size() == 12); // Consumers remain valid through reinitialization.
    assert(!pool.allocation_count && !pool.retired_count && !pool.unavailable_count && !pool.peak_allocated);
    reused.reset();
    consumers.clear();
    assert(allocate.alive.empty());

    pool.set_retention(2);
    auto next = pool.acquire(allocate);
    assert(next && next->id == 13 && pool.allocation_count == 1 && pool.peak_allocated == 1);
}

void prefer_registered_memory() {
    Factory allocate;
    Pool pool(6);
    std::vector<std::shared_ptr<Image>> consumers;
    for (unsigned i = 0; i < Pool::capacity; ++i) consumers.push_back(pool.acquire(allocate));
    auto busy_overflow = consumers.back();
    assert(!busy_overflow->capture_pool_preferred);
    consumers.clear();
    Clock::advance();
    auto frame = pool.acquire(allocate);
    assert(frame && frame->capture_pool_preferred);
    assert((allocate.alive == std::set<int>{1, 2, 3, 4, 5, 6, 12}));
    // A consumer holding pageable overflow must not evict one of the six pins.
    busy_overflow.reset();
    frame.reset();
    frame = pool.acquire(allocate);
    assert((allocate.alive == std::set<int>{1, 2, 3, 4, 5, 6}));
    assert(pool.retired_count == 6); // Newer pageable burst buffers were retired first.
    frame.reset();
    for (unsigned cycle = 0; cycle < 10; ++cycle) {
        for (unsigned i = 0; i < 6; ++i) {
            consumers.push_back(pool.acquire(allocate));
            assert(consumers.back()->capture_pool_preferred);
        }
        consumers.clear();
        Clock::advance();
    }
    assert(allocate.next == 12); // No re-registration after the initial burst.
}

void limits_failures_and_pageable_fallback() {
    constexpr std::size_t budget = 256U * 1024U * 1024U;
    assert(Pool::retention_for_bytes(3840U * 2160U * 4U, budget) == 8);
    assert(Pool::retention_for_bytes(5120U * 2160U * 4U, budget) == 6);
    assert(Pool::retention_for_bytes(7680U * 4320U * 4U, budget) == 2);
    assert(Pool::retention_for_bytes(0, budget) == 0);
    assert(Pool::retention_for_bytes(1, budget) == Pool::capacity);
    assert(Pool::retention_for_bytes(budget + 1, budget) == 0);
    assert(Pool::retention_for_bytes(std::numeric_limits<std::size_t>::max(), budget) == 0);
    Factory allocate;
    allocate.preferred_limit = 0; // CPU x264 images or CUDA registration unavailable.
    Pool pool(9999);
    assert(pool.retention() == Pool::capacity);
    allocate.fail = true;
    assert(!pool.acquire(allocate));
    assert(pool.allocation_failures == 1 && pool.allocation_count == 0);
    allocate.fail = false;
    auto frame = pool.acquire(allocate);
    assert(frame && !frame->capture_pool_preferred);
    const auto id = frame->id;
    frame.reset();
    Clock::advance();
    assert(pool.acquire(allocate)->id == id && pool.allocation_count == 1);
    pool.clear();
    assert(allocate.alive.empty());
}
}

int main() {
    retain_across_bursts();
    ownership_and_capacity();
    prefer_registered_memory();
    limits_failures_and_pageable_fallback();
    std::cout << "Capture pool reuse, bounded retention, pin preference, ownership and reinitialization passed\n";
}
