// SPDX-License-Identifier: GPL-3.0-or-later
#include "reverse-media-clock.h"
#include "microphone-queue.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    const uint64_t second = 1000000000;
    PLANKReverseMediaClock clock = {0};
    assert(!PLANKReverseMediaClockMap(&clock, second, second));
    // Independent source/Host clock origins and +/-1000 ppm rates. Camera
    // captures occur between audio anchors and arrive with varying jitter;
    // arrival time must not become their presentation timestamp.
    for (int ppm = -1000; ppm <= 1000; ppm += 1000) {
        PLANKReverseMediaClockClear(&clock);
        for (unsigned block = 0; block < 6000; block++) {
            uint64_t host = 1000 * second + block * UINT64_C(10000000);
            uint64_t source = 100 * second + (uint64_t)((double)block * 10000000 * (1 + ppm / 1000000.0));
            assert(PLANKReverseMediaClockObserve(&clock, source, host + 30000000, host));
            uint64_t video = source - 5000000; // same scene, 5 ms earlier
            uint64_t presentation = PLANKReverseMediaClockMap(&clock, video, host + (block % 5) * 1000000);
            uint64_t expected = host + 30000000 - (uint64_t)(5000000 / (1 + ppm / 1000000.0));
            assert(presentation && llabs((long long)presentation - (long long)expected) < 10000);
        }
    }
    uint64_t now = clock.observed;
    assert(!PLANKReverseMediaClockMap(&clock, clock.source, now - 1));
    assert(!PLANKReverseMediaClockMap(&clock, clock.source, now + 100000000));
    assert(!PLANKReverseMediaClockMap(&clock, clock.source + second, now));
    assert(!PLANKReverseMediaClockObserve(&clock, 0, second, second));
    assert(!PLANKReverseMediaClockObserve(&clock, UINT64_MAX, second, second));
    assert(!PLANKReverseMediaClockObserve(&clock, second, UINT64_MAX, second));
    assert(PLANKReverseMediaClockObserve(&clock, second, 2 * second, 2 * second));
    assert(!PLANKReverseMediaClockObserve(&clock, second - 1, 2 * second + 1, 2 * second + 1));
    assert(!PLANKReverseMediaClockActive(&clock, 2 * second + 1));

    PLANKMicQueue queue = {0};
    float samples[960], output[960];
    for (unsigned i = 0; i < 480; i++) { samples[i*2] = .25f; samples[i*2+1] = -.5f; }
    for (unsigned block = 0; block < 6; block++)
        assert(PLANKMicQueueSubmitTimed(&queue, samples, 480, block * 480,
            second + block * 10000000, 2 * second));
    uint64_t capture = 0;
    assert(PLANKMicQueueRenderTimed(&queue, 2 * second, output, &capture));
    assert(capture == second && queue.count == 2880 - 481);
    assert(output[0] == .25f && output[1] == -.5f);
    assert(PLANKMicQueueRenderTimed(&queue, 2 * second, output, &capture));
    assert(capture == second + 10000000 + second / 48000); // prior render consumed 481
    PLANKMicQueueClear(&queue);
    assert(!PLANKMicQueueRenderTimed(&queue, 2 * second, output, &capture) && !capture);
    for (unsigned block = 0; block < 3; block++)
        assert(PLANKMicQueueSubmitTimed(&queue, samples, 480, block * 480,
            second + block * 10000000, 2 * second));
    assert(!PLANKMicQueueRenderTimed(&queue, 2 * second + 100000000, output, &capture) && !capture);
    assert(!PLANKMicQueueSubmitTimed(&queue, samples, 480, 1440, UINT64_MAX, 3 * second));
    puts("reverse media clock: source/Host origins, drift, jitter, expiry, reset and rendered stereo sample timing passed");
}
