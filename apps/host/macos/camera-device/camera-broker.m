// SPDX-License-Identifier: GPL-3.0-or-later
#import "camera-broker.h"
#include "camera-link.h"
#include <sys/mman.h>
#include <unistd.h>
#include <time.h>

@interface PLANKCameraPeer : NSObject
@property xpc_connection_t connection;
@property xpc_object_t memory;
@property uint64_t created, generation, lease, lastRenew;
@property PLANKMacAgentPeer identity;
@property BOOL extension, registered, ready, closed, pending;
@property uint64_t activation;
@end
@implementation PLANKCameraPeer
@end

static uint64_t cameraNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
static BOOL cameraNumber(xpc_object_t message, const char *name, uint64_t *value) {
    xpc_object_t item = xpc_dictionary_get_value(message, name);
    if (!item || xpc_get_type(item) != XPC_TYPE_UINT64) return NO;
    *value = xpc_uint64_get_value(item); return YES;
}

@implementation PLANKMacCameraBroker {
    dispatch_queue_t _queue;
    NSString *_requirement, *_extensionRequirement;
    BOOL (^_authorize)(PLANKMacAgentPeer, uint64_t);
    size_t _bytes;
    xpc_connection_t _extensionListener, _producerListener;
    PLANKCameraPeer *_extension, *_producer;
    NSMutableArray<PLANKCameraPeer *> *_peers;
    dispatch_source_t _watch;
    BOOL _stopped;
}
- (instancetype)init { return nil; }
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
         extensionRequirement:(NSString *)extensionRequirement authorize:(BOOL (^)(PLANKMacAgentPeer, uint64_t))authorize {
    if (geteuid() || !queue || !requirement.length || !extensionRequirement.length || !authorize) return nil;
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0) return nil;
    self = [super init];
    if (self) {
        _queue = queue; _requirement = [requirement copy]; _authorize = [authorize copy];
        _extensionRequirement = [extensionRequirement copy];
        _bytes = PLANKCameraLinkBytes((size_t)page);
        _peers = [NSMutableArray array];
    }
    return self;
}
- (void)close:(PLANKCameraPeer *)peer {
    if (!peer || peer.closed) return;
    peer.closed = YES;
    xpc_connection_cancel(peer.connection); [_peers removeObject:peer];
    if (peer == _producer) {
        _producer = nil;
        if (_extension) [self extensionOperation:3 lease:peer.lease activation:peer.activation memory:NULL completion:^(BOOL accepted) { (void)accepted; }];
    }
    if (peer == _extension) { _extension = nil; [self close:_producer]; }
    peer.memory = nil;
}
- (void)extensionOperation:(uint64_t)operation lease:(uint64_t)lease activation:(uint64_t)activation memory:(xpc_object_t)memory
             completion:(void (^)(BOOL))completion {
    if (!_extension || !lease) { completion(NO); return; }
    PLANKCameraPeer *extension = _extension;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(request, "version", PLANKCameraLinkVersion);
    xpc_dictionary_set_uint64(request, "operation", operation);
    xpc_dictionary_set_uint64(request, "lease", lease);
    if (memory) {
        xpc_dictionary_set_uint64(request, "activation", activation);
        xpc_dictionary_set_value(request, "memory", memory);
    }
    __weak typeof(self) weakSelf = self;
    __block BOOL finished = NO;
    void (^finish)(BOOL) = ^(BOOL ok) {
        if (finished) return;
        finished = YES; completion(ok);
    };
    xpc_connection_send_message_with_reply(extension.connection, request, _queue, ^(xpc_object_t reply) {
        typeof(self) owner = weakSelf;
        xpc_object_t accepted = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ?
            xpc_dictionary_get_value(reply, "accepted") : NULL;
        BOOL ok = owner && !owner->_stopped && owner->_extension == extension && !extension.closed &&
            xpc_get_type(reply) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_count(reply) == 1 &&
            accepted && xpc_get_type(accepted) == XPC_TYPE_BOOL &&
            xpc_dictionary_get_bool(reply, "accepted");
        finish(ok);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _queue, ^{ finish(NO); });
}
- (void)receive:(xpc_object_t)message peer:(PLANKCameraPeer *)peer {
    if (peer.closed || _stopped) return;
    uint64_t version = 0;
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY ||
        !cameraNumber(message, "version", &version) || version != PLANKCameraLinkVersion) { [self close:peer]; return; }
    if (peer.extension) {
        if (_extension || peer.registered || xpc_dictionary_get_count(message) != 1) { [self close:peer]; return; }
        peer.registered = YES; _extension = peer; return;
    }
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply) { [self close:peer]; return; }
    uint64_t generation = 0, activation = 0;
    if (xpc_dictionary_get_count(message) != 3 || !cameraNumber(message, "activation", &activation) || !activation ||
        !cameraNumber(message, "generation", &generation) ||
        !generation || !_authorize(peer.identity, generation) || !_extension) { [self close:peer]; return; }
    if (peer.registered) {
        if (peer != _producer || generation != peer.generation || !peer.ready ||
            peer.activation != activation) { [self close:peer]; return; }
        peer.lastRenew = cameraNow();
        xpc_dictionary_set_uint64(reply, "lease", peer.lease);
        xpc_connection_send_message(peer.connection, reply); return;
    }
    if (_producer) { [self close:peer]; return; }
    void *mapping = mmap(NULL, _bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0);
    if (mapping == MAP_FAILED) { [self close:peer]; return; }
    PLANKCameraLinkInit(mapping);
    peer.memory = xpc_shmem_create(mapping, _bytes);
    munmap(mapping, _bytes);
    if (!peer.memory) { [self close:peer]; return; }
    uint64_t lease = 0;
    arc4random_buf(&lease, sizeof(lease));
    if (!lease) lease = 1;
    peer.registered = YES; peer.generation = generation; peer.lease = lease;
    peer.activation = activation;
    peer.lastRenew = cameraNow(); _producer = peer;
    __weak typeof(self) weakSelf = self;
    [self extensionOperation:1 lease:lease activation:peer.activation memory:peer.memory completion:^(BOOL ok) {
        typeof(self) owner = weakSelf;
        if (!owner || peer.closed) return;
        if (!ok || owner->_producer != peer || !owner->_authorize(peer.identity, generation)) {
            [owner close:peer]; return;
        }
        peer.ready = YES;
        xpc_dictionary_set_uint64(reply, "lease", lease);
        xpc_dictionary_set_value(reply, "memory", peer.memory);
        xpc_connection_send_message(peer.connection, reply);
    }];
}
- (void)accept:(xpc_connection_t)connection extension:(BOOL)extension {
    const char *requirement = extension ? _extensionRequirement.UTF8String : _requirement.UTF8String;
    if (_stopped || _peers.count >= 8 || xpc_connection_set_peer_code_signing_requirement(connection, requirement)) {
        xpc_connection_set_event_handler(connection, ^(xpc_object_t message) { (void)message; });
        xpc_connection_cancel(connection); xpc_connection_activate(connection); return;
    }
    PLANKCameraPeer *peer = [PLANKCameraPeer new]; peer.connection = connection;
    peer.extension = extension; peer.created = cameraNow();
    // Kernel identity is read after the first delivered message, when XPC has
    // established credentials; no caller-supplied PID/UID is accepted.
    [_peers addObject:peer];
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_target_queue(connection, _queue);
    __weak PLANKCameraPeer *weakPeer = peer;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t message) {
        PLANKCameraPeer *current = weakPeer;
        if (!current) return;
        current.identity = (PLANKMacAgentPeer){xpc_connection_get_euid(current.connection),
            xpc_connection_get_pid(current.connection), (uint32_t)xpc_connection_get_asid(current.connection)};
        [weakSelf receive:message peer:current];
    });
    xpc_connection_activate(connection);
}
- (BOOL)start {
    dispatch_assert_queue(_queue);
    if (_watch || _stopped) return NO;
    _extensionListener = xpc_connection_create_mach_service(PLANK_CAMERA_EXTENSION_SERVICE, _queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    _producerListener = xpc_connection_create_mach_service(PLANK_CAMERA_PRODUCER_SERVICE, _queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!_extensionListener || !_producerListener) {
        // Locally created XPC connections must leave their inactive state before
        // their final release, including partial listener construction failure.
        for (xpc_connection_t listener in @[_extensionListener ?: (id)NSNull.null,
                                           _producerListener ?: (id)NSNull.null]) {
            if ((id)listener == NSNull.null) continue;
            xpc_connection_set_event_handler(listener, ^(xpc_object_t event) { (void)event; });
            xpc_connection_activate(listener);
        }
        [self stop]; return NO;
    }
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(_extensionListener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) [weakSelf accept:peer extension:YES];
    });
    xpc_connection_set_event_handler(_producerListener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) [weakSelf accept:peer extension:NO];
    });
    xpc_connection_activate(_extensionListener); xpc_connection_activate(_producerListener);
    _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_watch, DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC, 25*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_watch, ^{
        typeof(self) owner = weakSelf; if (!owner) return;
        uint64_t now = cameraNow();
        for (PLANKCameraPeer *peer in owner->_peers.copy)
            if (!peer.registered && now - peer.created >= 2*NSEC_PER_SEC) [owner close:peer];
        PLANKCameraPeer *producer = owner->_producer;
        if (!producer) return;
        if (now - producer.lastRenew >= 2*NSEC_PER_SEC || !owner->_authorize(producer.identity, producer.generation)) {
            [owner close:producer]; return;
        }
        if (!producer.ready || producer.pending) return;
        producer.pending = YES;
        [owner extensionOperation:2 lease:producer.lease activation:producer.activation memory:NULL completion:^(BOOL ok) {
            producer.pending = NO;
            if (!ok) [weakSelf close:producer];
        }];
    });
    dispatch_resume(_watch); return YES;
}
- (void)stop {
    dispatch_assert_queue(_queue);
    if (_stopped) return;
    _stopped = YES;
    if (_watch) dispatch_source_cancel(_watch);
    for (PLANKCameraPeer *peer in _peers.copy) [self close:peer];
    if (_extensionListener) xpc_connection_cancel(_extensionListener);
    if (_producerListener) xpc_connection_cancel(_producerListener);
}
@end
