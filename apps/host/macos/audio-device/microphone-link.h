// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "microphone-buffer.h"
#include <stddef.h>

// One fresh region per producer lease. Never reuse a retired writer's mapping.
// No pointers or lengths provided by a remote peer. Only control-queue code
// accesses shared memory; the realtime reader uses the driver's private copy.
#ifndef PLANK_MIC_DRIVER_SERVICE
#define PLANK_MIC_DRIVER_SERVICE "la.instinctual.PLANK.Host.microphone-driver"
#define PLANK_MIC_PRODUCER_SERVICE "la.instinctual.PLANK.Host.microphone-producer"
#endif
enum { PLANKMicLinkVersion = 1, PLANKMicPacketFrames = 480 };
typedef struct {
    uint64_t version;
    // HAL publishes its clock; producer reads a coherent snapshot. These are
    // advisory to the producer, never trusted by the driver after publication.
    _Atomic uint64_t clockSequence, anchor, seed;
    _Atomic uint32_t running;
    _Atomic uint64_t producerSeed, deadline;
    double ticksPerFrame;
    // Producer writes timestamp-addressed samples. Driver bounds every read,
    // sanitizes every float and supplies silence on missing/expired samples.
    PLANKMicBuffer samples;
} PLANKMicLink;

static inline size_t PLANKMicLinkBytes(size_t page) {
    return page ? (sizeof(PLANKMicLink) + page - 1) / page * page : 0;
}
static inline void PLANKMicLinkInit(PLANKMicLink *link) {
    memset(link, 0, sizeof(*link));
    link->version = PLANKMicLinkVersion;
    PLANKMicBufferInit(&link->samples);
}
