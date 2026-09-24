// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <string.h>
#include "microphone-format.h"

// Serialized producer-side PCM, separate from the lock-free HAL history.
// Capacity alone cannot bound age when rendering stalls or a partial packet
// remains below the priming threshold. Use local monotonic receipt times;
// these are not capture timestamps and do not establish A/V clock alignment.
enum { PLANKMicQueueFrames = 2880, PLANKMicTargetFrames = 960 };
#define PLANK_MIC_PCM_MAX_AGE_NS UINT64_C(100000000)
typedef struct {
    float samples[PLANKMicQueueFrames * PLANKMicChannels];
    uint64_t arrived[PLANKMicQueueFrames];
    uint64_t nextSample, expiredFrames, discardedFrames;
    unsigned head, count;
    int averageFrames256;
    bool hasSample, primed;
} PLANKMicQueue;

static inline void PLANKMicQueueDiscard(PLANKMicQueue *queue, unsigned count) {
    // Clear discarded PCM as well as its bookkeeping; mute and expiry must
    // not leave old speech waiting for a later priming or clock reset.
    for (unsigned i = 0; i < count; i++) {
        unsigned frame = (queue->head + i) % PLANKMicQueueFrames;
        memset(&queue->samples[frame * PLANKMicChannels], 0, PLANKMicChannels * sizeof(float));
        queue->arrived[frame] = 0;
    }
    queue->head = (queue->head + count) % PLANKMicQueueFrames;
    queue->count -= count;
}

static inline void PLANKMicQueueFlush(PLANKMicQueue *queue) {
    PLANKMicQueueDiscard(queue, queue->count);
    queue->head = 0; queue->primed = false; queue->averageFrames256 = 0;
}

static inline void PLANKMicQueueClear(PLANKMicQueue *queue) {
    PLANKMicQueueFlush(queue);
    queue->hasSample = false; queue->nextSample = 0;
    // Lifetime counters survive mute/reopen.
}

static inline void PLANKMicQueueExpire(PLANKMicQueue *queue, uint64_t now) {
    if (queue->count && now < queue->arrived[(queue->head + queue->count - 1) % PLANKMicQueueFrames]) {
        queue->expiredFrames += queue->count;
        PLANKMicQueueFlush(queue);
        return;
    }
    unsigned expired = 0;
    while (expired < queue->count) {
        uint64_t arrived = queue->arrived[(queue->head + expired) % PLANKMicQueueFrames];
        if (now >= arrived && now - arrived < PLANK_MIC_PCM_MAX_AGE_NS) break;
        expired++;
    }
    if (expired) {
        PLANKMicQueueDiscard(queue, expired);
        queue->expiredFrames += expired;
        queue->primed = false;
    }
}

static inline bool PLANKMicQueueSubmit(PLANKMicQueue *queue, const float *samples,
                                     uint32_t count, uint64_t sampleTime, uint64_t now) {
    if (!samples || count != PLANKMicPacketFrames || sampleTime % PLANKMicPacketFrames ||
        sampleTime > UINT64_MAX - count || (queue->hasSample && sampleTime < queue->nextSample)) return false;
    for (unsigned i = 0; i < count * PLANKMicChannels; i++) if (!isfinite(samples[i])) return false;
    // Expire before appending: fresh arrivals must not refresh old PCM's age.
    PLANKMicQueueExpire(queue, now);
    if (queue->hasSample && sampleTime != queue->nextSample) {
        uint64_t missing = sampleTime - queue->nextSample;
        if (missing <= 2 * PLANKMicPacketFrames && queue->count + missing + count <= PLANKMicQueueFrames) {
            for (unsigned i = 0; i < missing; i++) {
                unsigned frame = (queue->head + queue->count++) % PLANKMicQueueFrames;
                memset(&queue->samples[frame * PLANKMicChannels], 0, PLANKMicChannels * sizeof(float));
                queue->arrived[frame] = now;
            }
        } else PLANKMicQueueFlush(queue);
    }
    queue->hasSample = true; queue->nextSample = sampleTime + count;
    if (queue->count + count > PLANKMicQueueFrames) {
        unsigned discard = queue->count + count - PLANKMicQueueFrames;
        PLANKMicQueueDiscard(queue, discard);
        queue->discardedFrames += discard;
    }
    for (unsigned i = 0; i < count; i++) {
        unsigned frame = (queue->head + queue->count++) % PLANKMicQueueFrames;
        for (unsigned channel = 0; channel < PLANKMicChannels; channel++)
            queue->samples[frame * PLANKMicChannels + channel] = fminf(1, fmaxf(-1, samples[i * PLANKMicChannels + channel]));
        queue->arrived[frame] = now;
    }
    return true;
}

// Exactly one 10 ms stereo block. Return false for silence/starvation. Adjust
// both channels together by one frame around the existing 20 ms queue target.
static inline bool PLANKMicQueueRender(PLANKMicQueue *queue, uint64_t now,
                                     float output[PLANKMicPacketFrames * PLANKMicChannels]) {
    memset(output, 0, PLANKMicPacketFrames * PLANKMicChannels * sizeof(float));
    PLANKMicQueueExpire(queue, now);
    if (!queue->primed && queue->count >= PLANKMicTargetFrames) {
        queue->primed = true;
        queue->averageFrames256 = (int)queue->count * 256;
    }
    if (!queue->primed || queue->count < 479) { queue->primed = false; return false; }
    // Audio servers deliver batches. Using instantaneous occupancy can speed
    // up at each batch peak and slow down at its trough, cancelling the clock
    // correction even as a slower source repeatedly starves. Smooth 32 blocks
    // and retain the 20 ms target AFTER consuming this 10 ms output block.
    // That reserve also absorbs a batch with one fewer source packet while
    // the slow correction catches up; capacity remains 60 ms.
    queue->averageFrames256 += ((int)queue->count * 256 - queue->averageFrames256) / 32;
    const int low = (PLANKMicTargetFrames + PLANKMicPacketFrames) * 256;
    const int high = (PLANKMicTargetFrames + 3 * PLANKMicPacketFrames / 2) * 256;
    unsigned consume = queue->averageFrames256 > high ? 481 : queue->averageFrames256 < low ? 479 : 480;
    if (consume > queue->count) consume = queue->count;
    for (unsigned i = 0; i < PLANKMicPacketFrames; i++) {
        double offset = (double)i * consume / PLANKMicPacketFrames;
        unsigned a = (unsigned)offset, b = a + 1 < consume ? a + 1 : consume - 1;
        for (unsigned channel = 0; channel < PLANKMicChannels; channel++)
            output[i * PLANKMicChannels + channel] =
                queue->samples[((queue->head + a) % PLANKMicQueueFrames) * PLANKMicChannels + channel] * (1 - (offset - a)) +
                queue->samples[((queue->head + b) % PLANKMicQueueFrames) * PLANKMicChannels + channel] * (offset - a);
    }
    PLANKMicQueueDiscard(queue, consume);
    return true;
}
