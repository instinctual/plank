// SPDX-License-Identifier: GPL-3.0-or-later
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "host-network-policy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const uint32_t invalid[] = {0, 1, 100, 199, 120001, UINT32_MAX};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i)
        assert(!plank_macos_valid_ping_timeout(invalid[i]));
    for (uint32_t timeout = 200; timeout <= 120000; ++timeout) {
        assert(plank_macos_valid_ping_timeout(timeout));
        uint32_t keepalive = plank_macos_keep_alive_interval(timeout);
        assert(keepalive >= 100 && keepalive <= 1000 && keepalive < timeout);
    }
    assert(PLANKMacDefaultPingTimeoutMs == 10000);
    assert(plank_macos_keep_alive_interval(PLANKMacDefaultPingTimeoutMs) == 1000);
    puts("macos_host_timeout=pass bounds=1 keepalive_before_deadline=1 default_unchanged=1");
}
