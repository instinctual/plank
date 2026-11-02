// CPU-only comparison. No capture, NVENC or end-to-end performance claims.
#include "src/platform/linux/x11_rgb10.h"
#include <algorithm>
#include <barrier>
#include <chrono>
#include <iostream>
#include <thread>
#include <vector>

// Original row loop, built with the same optimizer and architecture flags.
__attribute__((noinline)) void baseline(const uint32_t* source, uint16_t* green,
    uint16_t* blue, uint16_t* red, std::size_t count) {
    for (std::size_t x = 0; x < count; ++x) {
        const uint32_t pixel = source[x];
        red[x] = uint16_t(pixel & 0x3ffU);
        green[x] = uint16_t((pixel >> 10U) & 0x3ffU);
        blue[x] = uint16_t((pixel >> 20U) & 0x3ffU);
    }
}
__attribute__((noinline)) void optimized(const uint32_t* source, uint16_t* green,
    uint16_t* blue, uint16_t* red, std::size_t count) {
    platf::x11::unpack_xrgb10_to_gbr10_row(source, green, blue, red, count);
}
int main() {
    for (const unsigned width : {3840, 5120}) {
        constexpr unsigned height = 2160, workers = 8;
        std::vector<uint32_t> source(width * height);
        std::vector<uint16_t> green(source.size()), blue(source.size()), red(source.size());
        for (std::size_t i = 0; i < source.size(); ++i) source[i] = uint32_t(i * 2654435761U);
        std::barrier ready(workers + 1), complete(workers + 1);
        bool stop = false;
        int mode = 0;
        std::vector<std::thread> threads;
        for (unsigned i = 0; i < workers; ++i) threads.emplace_back([&, i] {
            while (true) {
                ready.arrive_and_wait(); if (stop) break;
                const auto convert = mode == 2 ? optimized : baseline;
                auto [first, last] = platf::x11::row_range(height, i, workers);
                const unsigned step = mode == 0 ? workers : 1;
                if (mode == 0) { first = i; last = height; }
                for (auto y = first; y < last; y += step) {
                    const auto offset = y * width;
                    convert(source.data() + offset, green.data() + offset,
                        blue.data() + offset, red.data() + offset, width);
                }
                complete.arrive_and_wait();
            }
        });
        // Alternate implementations to reduce frequency/thermal ordering bias.
        std::vector<double> timings[3];
        for (unsigned round = 0; round < 180; ++round) for (int k = 0; k < 3; ++k) {
            mode = (k + round) % 3;
            const auto start = std::chrono::steady_clock::now();
            ready.arrive_and_wait(); complete.arrive_and_wait();
            if (round >= 20) timings[mode].push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
        }
        stop = true; ready.arrive_and_wait(); for (auto& thread : threads) thread.join();
        for (std::size_t i = 0; i < source.size(); ++i) {
            if (red[i] != (source[i] & 1023) || green[i] != ((source[i] >> 10) & 1023) || blue[i] != ((source[i] >> 20) & 1023)) return 1;
        }
        const char* names[] = {"original/interleaved", "original/contiguous", "SIMD/contiguous"};
        for (unsigned i = 0; i < 3; ++i) {
            auto& t = timings[i]; std::sort(t.begin(), t.end());
            std::cout << width << "x" << height << " " << names[i] << " frames=" << t.size()
                      << " median_ms=" << t[t.size()/2] << " p95_ms=" << t[t.size()*95/100] << '\n';
        }
    }
}
