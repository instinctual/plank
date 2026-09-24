// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>
#include "microphone-format.h"

// A sample-addressed history, not a FIFO: every Core Audio reader sees the
// same samples for the same device time. A stalled reader never holds up the
// producer or replays an old queue. One serialized writer; any number of readers.
// Real-time reads perform only bounded, lock-free loads and memory writes.
enum { PLANKMicFrames = 8192, PLANKMicMaxIO = 4096 };
typedef struct {
    _Atomic uint64_t frame;
    // One atomic payload keeps left and right from different writes from mixing.
    _Atomic uint64_t bits;
} PLANKMicSample;
typedef struct {
    _Atomic uint64_t generation;
    _Atomic uint64_t firstFrame;
    PLANKMicSample samples[PLANKMicFrames];
} PLANKMicBuffer;

static inline void PLANKMicBufferInit(PLANKMicBuffer *buffer) {
    atomic_init(&buffer->generation, 2);
    atomic_init(&buffer->firstFrame, 0);
    for (unsigned i = 0; i < PLANKMicFrames; i++) {
        atomic_init(&buffer->samples[i].frame, 0);
        atomic_init(&buffer->samples[i].bits, 0);
    }
}

// Only the writer calls Reset. Call before publishing a new session/mute
// generation. A read overlapping reset becomes silence. Absolute device time
// must continue increasing across session resets; the HAL clock only resets
// while IO is stopped, when the buffer is also reinitialized.
static inline void PLANKMicBufferReset(PLANKMicBuffer *buffer, uint64_t firstFrame) {
    atomic_fetch_add(&buffer->generation, 1);
    atomic_store(&buffer->firstFrame, firstFrame);
    for (unsigned i = 0; i < PLANKMicFrames; i++)
        atomic_store(&buffer->samples[i].frame, 0);
    atomic_fetch_add(&buffer->generation, 1);
}

static inline bool PLANKMicBufferWrite(PLANKMicBuffer *buffer, uint64_t frame,
                                     const float *samples, uint32_t count) {
    if (!samples || !count || count > PLANKMicMaxIO || frame > UINT64_MAX - count ||
        frame < atomic_load(&buffer->firstFrame)) return false;
    // Validate the entire block before making any samples visible.
    for (uint32_t i = 0; i < count * PLANKMicChannels; i++) if (!isfinite(samples[i])) return false;
    for (uint32_t i = 0; i < count; i++) {
        PLANKMicSample *slot = &buffer->samples[(frame + i) % PLANKMicFrames];
        float value[PLANKMicChannels];
        for (unsigned channel = 0; channel < PLANKMicChannels; channel++)
            value[channel] = fminf(1.0f, fmaxf(-1.0f, samples[i * PLANKMicChannels + channel]));
        uint64_t bits;
        memcpy(&bits, value, sizeof(bits));
        // Atomic payload as well as stamp avoids a C data race on overwrite.
        // Sequential consistency makes a reader's stamp/payload/stamp check
        // reject overwrite without a spin loop or real-time retry.
        atomic_store(&slot->frame, 0);
        atomic_store(&slot->bits, bits);
        atomic_store(&slot->frame, frame + i + 1);
    }
    return true;
}

static inline bool PLANKMicBufferRead(const PLANKMicBuffer *buffer, uint64_t frame,
                                    float *samples, uint32_t count) {
    if (!samples || count > PLANKMicMaxIO) return false;
    memset(samples, 0, count * PLANKMicChannels * sizeof(*samples));
    if (frame > UINT64_MAX - count) return false;
    uint64_t generation = atomic_load(&buffer->generation);
    if (generation & 1) return true;
    uint64_t first = atomic_load(&buffer->firstFrame);
    for (uint32_t i = 0; i < count; i++) {
        uint64_t position = frame + i;
        if (position < first) continue;
        const PLANKMicSample *slot = &buffer->samples[position % PLANKMicFrames];
        uint64_t before = atomic_load(&slot->frame);
        uint64_t bits = atomic_load(&slot->bits);
        uint64_t after = atomic_load(&slot->frame);
        if (before == position + 1 && after == before)
            memcpy(&samples[i * PLANKMicChannels], &bits, sizeof(bits));
    }
    if (generation != atomic_load(&buffer->generation))
        memset(samples, 0, count * PLANKMicChannels * sizeof(*samples));
    return true;
}
