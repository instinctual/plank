// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stdint.h>

enum {
    PLANKMacDefaultPingTimeoutMs = 10000,
    PLANKMacMinimumPingTimeoutMs = 200,
    PLANKMacMaximumPingTimeoutMs = 120000,
};

static inline bool plank_macos_valid_ping_timeout(uint32_t milliseconds) {
    return milliseconds >= PLANKMacMinimumPingTimeoutMs && milliseconds <= PLANKMacMaximumPingTimeoutMs;
}

// Preserve the existing one-second keepalive at the default timeout. Shorter
// administrator timeouts need an interval strictly below their idle deadline.
static inline uint32_t plank_macos_keep_alive_interval(uint32_t timeout_ms) {
    return timeout_ms < 2000 ? timeout_ms / 2 : 1000;
}
