// SPDX-License-Identifier: GPL-3.0-or-later
// Fixed-size, test-only shared memory. No pointers, file names or credentials.
// Driver writes the clock snapshot; the synthetic producer owns PCM/reset.
#pragma once
#include "../../apps/host/macos/audio-device/microphone-buffer.h"
typedef struct {
    uint64_t version;
    double ticksPerFrame;
    _Atomic uint64_t clockSequence, anchor, seed;
    _Atomic uint32_t running;
    _Atomic uint64_t producerSeed, deadline;
    _Atomic uint64_t readFrames, missingFrames, disabledFrames;
    _Atomic uint64_t readySeed, steadyMissing, steadyDisabled;
    PLANKMicBuffer buffer;
} PLANKMicProbeShared;
