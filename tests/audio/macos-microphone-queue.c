// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic production PCM queue tests; no audio device or recording.
#include "microphone-queue.h"
#include <assert.h>
#include <stdio.h>

#define MS UINT64_C(1000000)
static PLANKMicQueue queue;
static float input[PLANKMicPacketFrames * PLANKMicChannels];
static float output[PLANKMicPacketFrames * PLANKMicChannels];
static void reset(void) { memset(&queue, 0, sizeof(queue)); }
static void values(float left, float right) {
    for (unsigned i = 0; i < PLANKMicPacketFrames; i++) {
        input[2*i] = left; input[2*i+1] = right;
    }
}
static void push(uint64_t sample, uint64_t now, float value) {
    values(value, -value);
    assert(PLANKMicQueueSubmit(&queue, input, PLANKMicPacketFrames, sample, now));
    assert(queue.count <= PLANKMicQueueFrames);
}
static void constant(float left, float right) {
    for (unsigned i = 0; i < PLANKMicPacketFrames; i++) {
        assert(fabsf(output[2*i] - left) < 0.000001f);
        assert(fabsf(output[2*i+1] - right) < 0.000001f);
    }
}
static void freshness(void) {
    reset(); push(0, 0, .25f); push(480, 0, .25f);
    assert(PLANKMicQueueRender(&queue, PLANK_MIC_PCM_MAX_AGE_NS - 1, output));
    constant(.25f, -.25f);
    const unsigned remaining = queue.count;
    assert(!PLANKMicQueueRender(&queue, PLANK_MIC_PCM_MAX_AGE_NS, output));
    constant(0, 0); assert(queue.count == 0 && queue.expiredFrames == remaining);

    // A scheduler stall must not replay the queued speech after recovery.
    reset(); push(0, 0, .25f); push(480, 10*MS, .25f);
    assert(!PLANKMicQueueRender(&queue, 500*MS, output));
    constant(0, 0); assert(queue.expiredFrames == 960);
    // Expiry keeps the sample-order guard; only an explicit activation reset
    // permits sample zero again.
    assert(!PLANKMicQueueSubmit(&queue, input, 480, 0, 500*MS));

    // New traffic cannot refresh the age of the old queued samples.
    reset(); push(0, 0, .25f); push(480, 0, .25f);
    push(960, 101*MS, .75f);
    assert(queue.expiredFrames == 960 && queue.count == 480);
    assert(!PLANKMicQueueRender(&queue, 101*MS, output)); constant(0, 0);
    push(1440, 111*MS, .75f);
    assert(PLANKMicQueueRender(&queue, 111*MS, output)); constant(.75f, -.75f);

    // Keep the fresh tail but re-prime after dropping the expired prefix.
    reset(); push(0, 0, .25f); push(480, 90*MS, .75f);
    assert(!PLANKMicQueueRender(&queue, 100*MS, output)); constant(0, 0);
    assert(queue.expiredFrames == 480 && queue.count == 480);
    push(960, 100*MS, .75f);
    assert(PLANKMicQueueRender(&queue, 100*MS, output)); constant(.75f, -.75f);

    // A fractional drift remainder must not survive starvation indefinitely.
    reset(); push(0, 0, .25f); push(480, 10*MS, .25f);
    assert(PLANKMicQueueRender(&queue, 10*MS, output));
    assert(PLANKMicQueueRender(&queue, 20*MS, output));
    const unsigned remainder = queue.count;
    assert(remainder > 0 && remainder < 479);
    assert(!PLANKMicQueueRender(&queue, 30*MS, output));
    push(960, 120*MS, .75f); push(1440, 130*MS, .75f);
    assert(queue.expiredFrames == remainder);
    assert(PLANKMicQueueRender(&queue, 130*MS, output)); constant(.75f, -.75f);

    reset(); push(0, 100*MS, .25f); push(480, 110*MS, .25f);
    assert(!PLANKMicQueueRender(&queue, 105*MS, output));
    constant(0, 0); assert(queue.expiredFrames == 960); // clock reversal fails silent
}
static void recovery(void) {
    reset(); push(0, 0, .25f); push(960, 20*MS, .75f);
    assert(PLANKMicQueueRender(&queue, 20*MS, output)); constant(.25f, -.25f);
    assert(PLANKMicQueueRender(&queue, 30*MS, output)); constant(0, 0); // missing packet
    assert(PLANKMicQueueRender(&queue, 40*MS, output));
    // Clock adaptation may stretch the silence boundary by a sample; the
    // body of the next block must contain fresh stereo audio, never the old tone.
    for (unsigned i = 4; i < PLANKMicPacketFrames; i++) {
        assert(output[2*i] == .75f && output[2*i+1] == -.75f);
    }
    push(4800, 50*MS, .5f); // large gap flushes the residual, no replay
    assert(queue.count == 480 && !queue.primed);
    assert(!PLANKMicQueueRender(&queue, 50*MS, output)); constant(0, 0);

    PLANKMicQueueClear(&queue); // mute/new activation
    for (unsigned i = 0; i < PLANKMicQueueFrames * PLANKMicChannels; i++) assert(queue.samples[i] == 0);
    push(0, 60*MS, .5f); push(480, 70*MS, .5f);
    assert(PLANKMicQueueRender(&queue, 70*MS, output)); constant(.5f, -.5f);

    reset();
    for (unsigned packet = 0; packet < 7; packet++) push(packet*480, 0, (packet + 1)*.1f);
    assert(queue.count == PLANKMicQueueFrames && queue.discardedFrames == 480);
    assert(PLANKMicQueueRender(&queue, 0, output));
    assert(fabsf(output[0] - .2f) < .000001f); // oldest packet evicted
    assert(queue.count == PLANKMicQueueFrames - 481); // high-water drift correction

    reset(); values(2, -.25f);
    assert(PLANKMicQueueSubmit(&queue, input, 480, 0, 0));
    assert(PLANKMicQueueSubmit(&queue, input, 480, 480, 0));
    assert(PLANKMicQueueRender(&queue, 0, output)); constant(1, -.25f);
    PLANKMicQueue saved = queue;
    assert(!PLANKMicQueueSubmit(&queue, input, 479, 960, 0));
    assert(!PLANKMicQueueSubmit(&queue, input, 480, 961, 0));
    assert(!PLANKMicQueueSubmit(&queue, NULL, 480, 960, 0));
    assert(!PLANKMicQueueSubmit(&queue, input, 480, UINT64_MAX - UINT64_MAX % 480, 0));
    input[959] = NAN;
    assert(!PLANKMicQueueSubmit(&queue, input, 480, 960, 0));
    assert(!memcmp(&saved, &queue, sizeof(queue))); // no partial acceptance
}
static void drift(int ppm, unsigned batchMs, unsigned phaseMs) {
    reset();
    uint64_t capture = phaseMs * MS, sample = 0;
    uint64_t interval = (uint64_t)(10000000 + 10 * ppm);
    unsigned starved = 0, rendered = 0, steadyStarved = 0;
    // Two simulated minutes per case, with audio-server batches and clocks that
    // differ by +/-1000 ppm. Each stereo channel shares the same correction.
    for (uint64_t now = 0; now < 120000*MS; now += 10*MS) {
        if (now % (batchMs*MS) == 0) {
            while (capture <= now) {
                push(sample, now, .375f); sample += 480; capture += interval;
            }
        }
        if (PLANKMicQueueRender(&queue, now, output)) { constant(.375f, -.375f); rendered++; }
        else { constant(0, 0); starved++; if (now >= 100*MS) steadyStarved++; }
        assert(queue.count <= PLANKMicQueueFrames);
    }
    assert(starved <= 4 && rendered >= 11996 && steadyStarved == 0);
    assert(queue.expiredFrames == 0 && queue.discardedFrames == 0);
}
int main(void) {
    freshness(); recovery();
    for (int ppm = -1000; ppm <= 1000; ppm += 1000)
        for (unsigned batchMs = 10; batchMs <= 30; batchMs += 10)
            for (unsigned phaseMs = 0; phaseMs <= 5; phaseMs += 5) drift(ppm, batchMs, phaseMs);
    puts("microphone_queue=pass age_bound=100ms gaps=1 mute=1 stereo=1 burst=10/20/30ms drift=+-1000ppm simulated_minutes=36");
}
