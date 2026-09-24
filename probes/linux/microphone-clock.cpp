// SPDX-License-Identifier: GPL-3.0-or-later
// Explicit live-source probe: opens the default input for three seconds.
// Emits timing counters only; never saves or prints microphone samples.
#include "linuxmicrophone.h"
#include <chrono>
#include <cstdio>
#include <thread>
#include <algorithm>
int main() {
    using Clock = std::chrono::steady_clock;
    PlankLinuxMicrophone capture;
    const auto end = Clock::now() + std::chrono::seconds(3);
    std::uint64_t packets = 0, first = 0, last = 0, minAge = UINT64_MAX, maxAge = 0;
    PlankLinuxMicrophone::Packet packet;
    while (Clock::now() < end) {
        if (!capture.valid()) { std::puts("microphone_capture_valid=0"); return 1; }
        while (capture.take(packet)) {
            const std::uint64_t now = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count();
            if (!packet.captureTimeNs || packet.captureTimeNs <= last || packet.captureTimeNs > now) return 2;
            if (!packets) first = packet.captureTimeNs;
            last = packet.captureTimeNs; packets++;
            minAge = std::min(minAge, now - last); maxAge = std::max(maxAge, now - last);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::printf("packets=%llu capture_span_ns=%llu min_age_ns=%llu max_age_ns=%llu\n",
        (unsigned long long)packets, (unsigned long long)(last - first),
        (unsigned long long)minAge, (unsigned long long)maxAge);
    return packets >= 100 ? 0 : 3;
}
