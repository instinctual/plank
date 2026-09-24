// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the real broker over anonymous local XPC, with only root/signature
// admission and HAL routing replaced. No named service, root work or audio IO.
#import <Foundation/Foundation.h>
#include <xpc/xpc.h>
#include <unistd.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
static uid_t fixtureRoot(void) { return 0; }
static int fixtureRequirement(xpc_connection_t connection, const char *requirement) {
    assert(connection && !strcmp(requirement, "fixture-signed-host")); return 0;
}
#define geteuid fixtureRoot
#define xpc_connection_set_peer_code_signing_requirement fixtureRequirement
#import "../../apps/host/macos/audio-device/output-broker.m"
#undef geteuid
#undef xpc_connection_set_peer_code_signing_requirement

static atomic_uint selections, restorations;
@interface FixtureSelection : PLANKMacOutputSelection
@end
@implementation FixtureSelection
- (BOOL)select { atomic_fetch_add(&selections, 1); return YES; }
- (BOOL)restore { atomic_fetch_add(&restorations, 1); return YES; }
- (BOOL)recover { return YES; }
@end
static void waitFor(dispatch_semaphore_t signal) {
    assert(!dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)));
}
static xpc_connection_t connectPeer(xpc_endpoint_t endpoint, dispatch_queue_t queue) {
    xpc_connection_t peer = xpc_connection_create_from_endpoint(endpoint);
    xpc_connection_set_target_queue(peer, queue);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) { (void)event; });
    xpc_connection_activate(peer); return peer;
}
static xpc_object_t message(uint64_t generation, bool active) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(message, "version", PLANKOutputRoutingVersion);
    xpc_dictionary_set_uint64(message, "generation", generation);
    xpc_dictionary_set_bool(message, "active", active); return message;
}
static BOOL request(xpc_connection_t peer, xpc_object_t message, dispatch_queue_t queue) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block BOOL accepted = NO;
    xpc_connection_send_message_with_reply(peer, message, queue, ^(xpc_object_t reply) {
        accepted = xpc_get_type(reply) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(reply, "accepted");
        dispatch_semaphore_signal(done);
    });
    waitFor(done); return accepted;
}
int main(void) { @autoreleasepool {
    dispatch_queue_t queue = dispatch_queue_create("plank.test.output-broker", DISPATCH_QUEUE_SERIAL);
    PLANKMacOutputBroker *broker = [[PLANKMacOutputBroker alloc] initWithQueue:queue requirement:@"fixture-signed-host"
        authorize:^BOOL(PLANKMacAgentPeer peer, uint64_t generation) {
            return peer.uid == getuid() && peer.pid == getpid() && generation == 7;
        }];
    assert(broker);
    [broker setValue:[[FixtureSelection alloc] initWithDirectory:@"/unused"] forKey:@"selection"];
    xpc_connection_t listener = xpc_connection_create(NULL, queue);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) [broker accept:peer];
    });
    xpc_connection_activate(listener);
    xpc_endpoint_t endpoint = xpc_endpoint_create(listener);
    assert(endpoint);
    for (unsigned i = 0; i < 6; ++i) {
        xpc_connection_t peer = connectPeer(endpoint, queue);
        xpc_object_t invalid = message(i == 0 ? 8 : 7, true);
        if (i == 1) xpc_dictionary_set_uint64(invalid, "version", 2);
        if (i == 2) xpc_dictionary_set_string(invalid, "generation", "7");
        if (i == 3) xpc_dictionary_set_uint64(invalid, "active", 1);
        if (i == 4) xpc_dictionary_set_uint64(invalid, "generation", 0);
        if (i == 5) xpc_dictionary_set_bool(invalid, "unexpected", true);
        assert(!request(peer, invalid, queue)); xpc_connection_cancel(peer);
        assert(!atomic_load(&selections) && !atomic_load(&restorations));
    }
    xpc_connection_t owner = connectPeer(endpoint, queue);
    assert(request(owner, message(7, true), queue) && atomic_load(&selections) == 1);
    assert(request(owner, message(7, true), queue) && atomic_load(&selections) == 1);
    xpc_connection_t contender = connectPeer(endpoint, queue);
    assert(!request(contender, message(7, true), queue));
    assert(!atomic_load(&restorations));
    assert(request(owner, message(7, false), queue));
    assert(atomic_load(&restorations) == 1);
    xpc_connection_t replacement = connectPeer(endpoint, queue);
    assert(request(replacement, message(7, true), queue));
    // Old-generation renewal revokes this owner's route, not a replacement's.
    assert(!request(replacement, message(8, true), queue));
    assert(atomic_load(&restorations) == 2);
    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    dispatch_async(queue, ^{ [broker stopWithCompletion:^{ dispatch_semaphore_signal(stopped); }]; });
    waitFor(stopped); xpc_connection_cancel(listener);
    puts("output_broker_real_xpc_types_authority_single_owner_renew_revoke=pass signature_gate=fixture");
} }
