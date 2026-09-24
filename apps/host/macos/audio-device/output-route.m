// SPDX-License-Identifier: GPL-3.0-or-later
#import "output-route.h"
#import "output-broker.h"
#include <time.h>
#include <unistd.h>

@implementation PLANKMacOutputRoute {
    dispatch_queue_t _queue;
    xpc_connection_t _peer;
    dispatch_source_t _timer;
    uint64_t _generation, _requestedAt, _acknowledgedAt;
    BOOL _started, _stopped, _pending, _ready;
    BOOL (^_valid)(void);
    void (^_completion)(void);
}
- (instancetype)initWithQueue:(dispatch_queue_t)queue generation:(uint64_t)generation
                  requirement:(NSString *)requirement valid:(BOOL (^)(void))valid {
    if (!queue || !generation || !requirement.length || !valid || !getuid()) return nil;
    self = [super init]; if (!self) return nil;
    _queue = queue; _generation = generation; _valid = [valid copy];
    _peer = xpc_connection_create_mach_service(PLANK_OUTPUT_SERVICE, queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!_peer) return nil;
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(_peer, ^(xpc_object_t event) { (void)event; [weakSelf finish]; });
    if (xpc_connection_set_peer_code_signing_requirement(_peer, requirement.UTF8String)) {
        xpc_connection_cancel(_peer); xpc_connection_activate(_peer); return nil;
    }
    xpc_connection_activate(_peer); return self;
}
- (void)finish {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    if (_peer) { xpc_connection_cancel(_peer); _peer = nil; }
    if (!_stopped) NSLog(@"PLANK Output automatic selection unavailable; select PLANK Output in Sound settings for remote audio");
    _stopped = YES;
    void (^completion)(void) = _completion; _completion = nil;
    if (completion) completion();
}
- (void)request:(BOOL)active {
    if (!_peer) { [self finish]; return; }
    _pending = YES; _requestedAt = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(message, "version", PLANKOutputRoutingVersion);
    xpc_dictionary_set_uint64(message, "generation", _generation);
    xpc_dictionary_set_bool(message, "active", active);
    __weak typeof(self) weakSelf = self;
    xpc_connection_send_message_with_reply(_peer, message, _queue, ^(xpc_object_t reply) {
        typeof(self) owner = weakSelf;
        if (!owner || !owner->_peer) return;
        if (!active) { [owner finish]; return; }
        if (owner->_stopped) return;
        xpc_object_t accepted = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(reply, "accepted") : NULL;
        if (xpc_connection_get_euid(owner->_peer) != 0 || !accepted || xpc_get_type(accepted) != XPC_TYPE_BOOL ||
            !xpc_bool_get_value(accepted) || xpc_dictionary_get_count(reply) != 1 || !owner->_valid()) {
            [owner finish]; return;
        }
        owner->_pending = NO; owner->_acknowledgedAt = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        if (!owner->_ready) NSLog(@"PLANK Output selected for remote playback");
        owner->_ready = YES;
    });
}
- (void)start {
    dispatch_assert_queue(_queue);
    if (_started || _stopped) return;
    _started = YES;
    if (!_valid()) { [self finish]; return; }
    __weak typeof(self) weakSelf = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC, 25*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{
        typeof(self) owner = weakSelf;
        if (!owner || owner->_stopped) return;
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        if (!owner->_valid() || (owner->_pending && now - owner->_requestedAt >= 2*NSEC_PER_SEC)) {
            [owner finish]; return;
        }
        if (!owner->_pending && now - owner->_acknowledgedAt >= 500*NSEC_PER_MSEC) [owner request:YES];
    });
    dispatch_resume(_timer); [self request:YES];
}
- (void)stopWithCompletion:(void (^)(void))completion {
    dispatch_assert_queue(_queue);
    if (_stopped) { if (completion) completion(); return; }
    _stopped = YES; _completion = [completion copy];
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    [self request:NO];
    // Teardown stays bounded even if HAL restoration is temporarily blocked.
    // Root retains the recovery journal and retries independently.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), _queue, ^{ [self finish]; });
}
@end
