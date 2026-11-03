#include "plankreconnectpolicy.h"
#include "sessionlifecycle.h"
#include <cassert>
#include <initializer_list>

int main()
{
    PlankReconnectPolicy policy;
    assert(!policy.allowsRequest(0));
    policy.allowUntil(30000);
    for (uint64_t now = 1; now < 30000; ++now) assert(policy.allowsRequest(now));
    for (uint64_t now = 30000; now < 90000; ++now) assert(!policy.allowsRequest(now));
    policy.allowUntil(120000); // A new bounded recovery interval.
    assert(policy.allowsRequest(90000));
    assert(!policy.allowsRequest(120000));
    policy.allowContinuously();
    for (uint64_t now : {0ULL, 14999ULL, 15000ULL, 30000ULL, 60000ULL, 86400000ULL})
        assert(policy.allowsRequest(now));
    policy.allowUntil(0); // Explicit disconnect, even during automatic recovery.
    assert(!policy.allowsRequest(86400000));
    policy.allowUntil(90015000); // Next session may opt into auto-disconnect.
    assert(policy.allowsRequest(90014999));
    assert(!policy.allowsRequest(90015000));
    for (int status : {400, 403, 404, 423}) {
        assert(PlankReconnectPolicy::terminalStatus(status, true));
        assert(PlankReconnectPolicy::terminalStatus(status, false));
    }
    assert(PlankReconnectPolicy::terminalStatus(401, true));
    assert(!PlankReconnectPolicy::terminalStatus(401, false));
    for (int status : {409, 425, 429, 500, 502, 503, 504}) {
        assert(!PlankReconnectPolicy::terminalStatus(status, true));
        assert(!PlankReconnectPolicy::terminalStatus(status, false));
    }

    // A replacement request may beat retirement of the old Host connection.
    // Busy responses preserve automatic recovery and do not authorize takeover.
    PlankSessionLifecycle lifecycle;
    policy.allowContinuously();
    assert(lifecycle.started() && lifecycle.requestRecovery() && lifecycle.beginRecovery());
    for (uint64_t now : {500ULL, 1500ULL, 2500ULL}) {
        assert(policy.allowsRequest(now));
        assert(!PlankReconnectPolicy::terminalStatus(409, false));
        assert(lifecycle.recovering());
    }
    assert(lifecycle.recovered() && lifecycle.streaming());
    // An explicit Host termination or user Disconnect remains final.
    lifecycle.stop();
    assert(!lifecycle.requestRecovery() && !lifecycle.recovered());
}
