// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <limits.h>

// One authenticated desktop session, serialized on its media queue. Anchor to
// the source sample actually consumed by the microphone renderer, after queue
// drift correction. Re-anchor every rendered block instead of assuming that
// the Client and Host oscillators have the same rate over a long session.
typedef struct {
    uint64_t source, host, observed;
} PLANKReverseMediaClock;
static inline void PLANKReverseMediaClockClear(PLANKReverseMediaClock *clock) {
    *clock = (PLANKReverseMediaClock){0};
}
static inline bool PLANKReverseMediaClockActive(const PLANKReverseMediaClock *clock, uint64_t now) {
    return clock->source && now >= clock->observed && now - clock->observed < UINT64_C(100000000);
}
static inline bool PLANKReverseMediaClockObserve(PLANKReverseMediaClock *clock,
        uint64_t source, uint64_t host, uint64_t now) {
    if (!source || source > INT64_MAX || !host || host > INT64_MAX || !now ||
        (host >= now ? host - now : now - host) > UINT64_C(100000000)) {
        PLANKReverseMediaClockClear(clock); return false;
    }
    if (PLANKReverseMediaClockActive(clock, now) && (source <= clock->source || host <= clock->host)) {
        PLANKReverseMediaClockClear(clock); return false;
    }
    *clock = (PLANKReverseMediaClock){source, host, now}; return true;
}
static inline uint64_t PLANKReverseMediaClockMap(const PLANKReverseMediaClock *clock,
        uint64_t source, uint64_t now) {
    if (!PLANKReverseMediaClockActive(clock, now) || !source || source > INT64_MAX) return 0;
    int64_t delta = (int64_t)source - (int64_t)clock->source;
    // Bounded extrapolation: with 1000 ppm oscillator error, 150 ms corresponds
    // to at most 0.15 ms of clock-rate error between fresh audio anchors.
    if (delta < -150000000 || delta > 150000000 ||
        (delta > 0 && clock->host > (uint64_t)(INT64_MAX - delta)) ||
        (delta < 0 && clock->host <= (uint64_t)-delta)) return 0;
    uint64_t mapped = (uint64_t)((int64_t)clock->host + delta);
    if ((mapped > now && mapped - now > UINT64_C(100000000)) ||
        (mapped <= now && now - mapped > UINT64_C(150000000))) return 0;
    return mapped;
}

#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Strong references in both producers retain the session clock across queued
// cleanup. Only the supplied serial session queue may access this storage.
@interface PLANKMacReverseMediaClock : NSObject {
@public
    PLANKReverseMediaClock value;
}
@end
#endif
