// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <CoreMedia/CoreMedia.h>

// CMIO HostTime timestamps belong to the Core Media host clock. Keep these
// distinct from CLOCK_MONOTONIC, used only for local IPC lease deadlines.
static inline uint64_t PLANKCameraHostTimeNanos(void) {
    CMTime time = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()),
        1000000000, kCMTimeRoundingMethod_Default);
    return CMTIME_IS_NUMERIC(time) && time.value > 0 ? (uint64_t)time.value : 0;
}
