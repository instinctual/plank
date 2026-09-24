// SPDX-License-Identifier: GPL-3.0-or-later
#import "output-broker.h"
#import "output-selection.h"
#include <unistd.h>
#include <time.h>

@interface PLANKOutputPeer : NSObject
@property xpc_connection_t connection;
@property PLANKMacAgentPeer identity;
@property uint64_t generation, lastRenew;
@property BOOL closed, ready;
@end
@implementation PLANKOutputPeer
@end

static uint64_t outputNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }

@implementation PLANKMacOutputBroker {
    dispatch_queue_t _queue, _hal;
    NSString *_requirement;
    BOOL (^_authorize)(PLANKMacAgentPeer, uint64_t);
    xpc_connection_t _listener;
    dispatch_source_t _watch;
    NSMutableArray<PLANKOutputPeer *> *_peers;
    PLANKOutputPeer *_owner;
    PLANKMacOutputSelection *_selection;
    BOOL _stopped, _maintenance;
}
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
                    authorize:(BOOL (^)(PLANKMacAgentPeer, uint64_t))authorize {
    if (geteuid() || !queue || !requirement.length || !authorize) return nil;
    self = [super init];
    if (self) {
        _queue = queue; _requirement = [requirement copy]; _authorize = [authorize copy];
        _hal = dispatch_queue_create("la.instinctual.PLANK.Output.selection", DISPATCH_QUEUE_SERIAL);
        _selection = [[PLANKMacOutputSelection alloc] initWithDirectory:@PLANK_OUTPUT_ROUTING_DIRECTORY];
        _peers = [NSMutableArray array];
    }
    return self;
}
- (void)close:(PLANKOutputPeer *)peer reply:(xpc_object_t)reply {
    if (!peer || peer.closed) return;
    peer.closed = YES; [_peers removeObject:peer];
    BOOL owned = _owner == peer;
    if (owned) _owner = nil;
    dispatch_async(_hal, ^{
        BOOL restored = !owned || [self->_selection restore];
        dispatch_async(self->_queue, ^{
            if (reply) {
                xpc_dictionary_set_bool(reply, "accepted", restored);
                xpc_connection_send_message(peer.connection, reply);
                xpc_connection_send_barrier(peer.connection, ^{ xpc_connection_cancel(peer.connection); });
            } else xpc_connection_cancel(peer.connection);
        });
    });
}
- (void)receive:(xpc_object_t)message peer:(PLANKOutputPeer *)peer {
    if (peer.closed || _stopped) return;
    xpc_object_t version = xpc_get_type(message) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(message, "version") : NULL;
    xpc_object_t generation = version ? xpc_dictionary_get_value(message, "generation") : NULL;
    xpc_object_t active = version ? xpc_dictionary_get_value(message, "active") : NULL;
    if (!version || xpc_get_type(version) != XPC_TYPE_UINT64 || xpc_uint64_get_value(version) != PLANKOutputRoutingVersion ||
        !generation || xpc_get_type(generation) != XPC_TYPE_UINT64 || !xpc_uint64_get_value(generation) ||
        !active || xpc_get_type(active) != XPC_TYPE_BOOL || xpc_dictionary_get_count(message) != 3) {
        [self close:peer reply:NULL]; return;
    }
    uint64_t value = xpc_uint64_get_value(generation);
    if (!_authorize(peer.identity, value) || (peer.generation && peer.generation != value)) {
        [self close:peer reply:NULL]; return;
    }
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply) { [self close:peer reply:NULL]; return; }
    if (!xpc_bool_get_value(active)) { [self close:peer reply:reply]; return; }
    if (peer.generation) {
        if (_owner != peer || !peer.ready) { [self close:peer reply:NULL]; return; }
        peer.lastRenew = outputNow();
        xpc_dictionary_set_bool(reply, "accepted", true);
        xpc_connection_send_message(peer.connection, reply); return;
    }
    if (_owner) { [self close:peer reply:NULL]; return; }
    peer.generation = value; peer.lastRenew = outputNow(); _owner = peer;
    dispatch_async(_hal, ^{
        BOOL selected = [self->_selection select];
        dispatch_async(self->_queue, ^{
            if (peer.closed) return; // close queued restoration after selection.
            if (!selected || self->_stopped || self->_owner != peer || !self->_authorize(peer.identity, value)) {
                [self close:peer reply:NULL]; return;
            }
            peer.ready = YES; peer.lastRenew = outputNow();
            xpc_dictionary_set_bool(reply, "accepted", true);
            xpc_connection_send_message(peer.connection, reply);
        });
    });
}
- (void)accept:(xpc_connection_t)connection {
    if (_stopped || _peers.count >= 8 ||
        xpc_connection_set_peer_code_signing_requirement(connection, _requirement.UTF8String)) {
        xpc_connection_set_event_handler(connection, ^(xpc_object_t message) { (void)message; });
        xpc_connection_cancel(connection); xpc_connection_activate(connection); return;
    }
    PLANKOutputPeer *peer = [PLANKOutputPeer new];
    peer.connection = connection; peer.lastRenew = outputNow(); [_peers addObject:peer];
    xpc_connection_set_target_queue(connection, _queue);
    __weak typeof(self) weakSelf = self;
    __weak PLANKOutputPeer *weakPeer = peer;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t message) {
        PLANKOutputPeer *current = weakPeer;
        if (!current) return;
        current.identity = (PLANKMacAgentPeer){xpc_connection_get_euid(connection),
            xpc_connection_get_pid(connection), (uint32_t)xpc_connection_get_asid(connection)};
        [weakSelf receive:message peer:current];
    });
    xpc_connection_activate(connection);
}
- (BOOL)start {
    dispatch_assert_queue(_queue);
    if (_watch || _stopped) return NO;
    _listener = xpc_connection_create_mach_service(PLANK_OUTPUT_SERVICE, _queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!_listener) return NO;
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(_listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_CONNECTION) [weakSelf accept:event];
    });
    xpc_connection_activate(_listener);
    _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_watch, DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC, 50*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_watch, ^{ [weakSelf tick]; });
    dispatch_resume(_watch); return YES;
}
- (void)tick {
    typeof(self) owner = self;
    if (!owner || owner->_stopped) return;
    uint64_t now = outputNow();
    for (PLANKOutputPeer *peer in owner->_peers.copy)
        if (now - peer.lastRenew >= 3*NSEC_PER_SEC ||
            (peer.generation && !owner->_authorize(peer.identity, peer.generation))) [owner close:peer reply:NULL];
    if (!owner->_owner && !owner->_maintenance) {
        owner->_maintenance = YES;
        dispatch_async(owner->_hal, ^{
            // Retry restoration after temporary HAL failure; never override
            // a manual selection or select an unrecorded external device.
            [owner->_selection recover];
            dispatch_async(owner->_queue, ^{ owner->_maintenance = NO; });
        });
    }
}
- (void)stopWithCompletion:(void (^)(void))completion {
    dispatch_assert_queue(_queue);
    _stopped = YES;
    if (_watch) dispatch_source_cancel(_watch);
    if (_listener) xpc_connection_cancel(_listener);
    for (PLANKOutputPeer *peer in _peers.copy) [self close:peer reply:NULL];
    dispatch_async(_hal, ^{
        [self->_selection recover];
        if (completion) dispatch_async(self->_queue, completion);
    });
}
@end
