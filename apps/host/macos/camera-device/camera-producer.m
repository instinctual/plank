// SPDX-License-Identifier: GPL-3.0-or-later
#import "camera-producer.h"
#include "camera-link.h"
#include "camera-clock.h"
#include <xpc/xpc.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <unistd.h>

@implementation PLANKMacCameraProducer {
    dispatch_queue_t _queue;
    xpc_connection_t _peer;
    dispatch_source_t _timer;
    PLANKCameraLink *_link;
    size_t _bytes;
    uint64_t _generation, _activation, _lease, _serial, _keyRequest;
    uint64_t _requestedAt, _acknowledgedAt;
    BOOL _started, _stopped, _pending;
    BOOL (^_valid)(void);
    void (^_ready)(BOOL);
}
static uint64_t producerNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
- (instancetype)init { return nil; }
- (instancetype)initWithQueue:(dispatch_queue_t)queue generation:(uint64_t)generation
                  activation:(uint64_t)activation requirement:(NSString *)requirement
                        valid:(BOOL (^)(void))valid {
    if (!queue || !generation || !activation || !requirement.length || !valid) return nil;
    long page = sysconf(_SC_PAGESIZE); if (page <= 0) return nil;
    self = [super init]; if (!self) return nil;
    _queue = queue; _generation = generation; _valid = [valid copy];
    _activation = activation;
    _bytes = PLANKCameraLinkBytes((size_t)page);
    _peer = xpc_connection_create_mach_service(PLANK_CAMERA_PRODUCER_SERVICE, queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!_peer) return nil;
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(_peer, ^(xpc_object_t message) { (void)message; [weakSelf stop]; });
    if (xpc_connection_set_peer_code_signing_requirement(_peer, requirement.UTF8String)) {
        xpc_connection_cancel(_peer); xpc_connection_activate(_peer); _peer = nil; return nil;
    }
    xpc_connection_activate(_peer); return self;
}
- (BOOL)available { dispatch_assert_queue(_queue); return _link && !_stopped; }
- (void)start:(void (^)(BOOL))ready {
    dispatch_assert_queue(_queue);
    if (_started || _stopped || !ready) { if (ready) ready(NO); return; }
    _started = YES; _ready = [ready copy];
    if (!_valid()) { [self stop]; return; }
    __weak typeof(self) weakSelf = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 5*NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer); [self request];
}
- (void)request {
    if (_pending || _stopped) return;
    if (!_valid()) { [self stop]; return; }
    _pending = YES; _requestedAt = producerNow();
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(message, "version", PLANKCameraLinkVersion);
    xpc_dictionary_set_uint64(message, "generation", _generation);
    xpc_dictionary_set_uint64(message, "activation", _activation);
    __weak typeof(self) weakSelf = self;
    xpc_connection_send_message_with_reply(_peer, message, _queue, ^(xpc_object_t reply) {
        typeof(self) owner = weakSelf; if (!owner || owner->_stopped) return;
        xpc_object_t leaseValue = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(reply, "lease") : NULL;
        if (xpc_connection_get_euid(owner->_peer) != 0 || !leaseValue || xpc_get_type(leaseValue) != XPC_TYPE_UINT64 ||
            !owner->_valid() || producerNow() - owner->_requestedAt >= NSEC_PER_SEC ||
            xpc_dictionary_get_count(reply) != (owner->_link ? 1u : 2u)) { [owner stop]; return; }
        uint64_t lease = xpc_uint64_get_value(leaseValue);
        if (!lease || (owner->_lease && owner->_lease != lease)) { [owner stop]; return; }
        if (!owner->_link) {
            xpc_object_t memory = xpc_dictionary_get_value(reply, "memory");
            if (!memory || xpc_get_type(memory) != XPC_TYPE_SHMEM) { [owner stop]; return; }
            void *mapping = NULL; size_t size = xpc_shmem_map(memory, &mapping);
            PLANKCameraLink *link = mapping;
            if (!mapping || size != owner->_bytes || atomic_load(&link->version) != PLANKCameraLinkVersion) {
                if (mapping) munmap(mapping, size);
                [owner stop]; return;
            }
            owner->_link = link; owner->_lease = lease;
        }
        owner->_pending = NO; owner->_acknowledgedAt = producerNow();
        void (^ready)(BOOL) = owner->_ready; owner->_ready = nil;
        if (ready) ready(YES);
    });
}
- (BOOL)submit:(const uint8_t *)record size:(size_t)size hostTimeNanos:(uint64_t)hostTime {
    dispatch_assert_queue(_queue);
    uint64_t now = PLANKCameraHostTimeNanos(); PlankCameraHeader header;
    if (!_link || _stopped || !_valid() || !hostTime || hostTime > now ||
        now - hostTime > PLANK_CAMERA_MAX_AGE_NS ||
        plank_camera_header_decode(record, size, &header) || header.generation != _activation) return NO;
    return PLANKCameraLinkWrite(_link, &_serial, record, size, hostTime);
}
- (BOOL)takeKeyframeRequest {
    dispatch_assert_queue(_queue);
    if (!_link || _stopped) return NO;
    uint64_t request = atomic_load(&_link->keyRequest);
    if (request == _keyRequest) return NO;
    _keyRequest = request; return YES;
}
- (void)tick {
    if (_stopped) return;
    uint64_t ns = producerNow();
    if (!_valid() || (_pending && ns - _requestedAt >= NSEC_PER_SEC)) { [self stop]; return; }
    if (!_pending && ns - _acknowledgedAt >= 500*NSEC_PER_MSEC) [self request];
}
- (void)stop {
    dispatch_assert_queue(_queue);
    if (_stopped) return;
    _stopped = YES;
    if (_link) { munmap(_link, _bytes); _link = NULL; }
    if (_timer) dispatch_source_cancel(_timer);
    if (_peer) xpc_connection_cancel(_peer);
    void (^ready)(BOOL) = _ready; _ready = nil;
    if (ready) ready(NO);
}
- (void)dealloc {
    if (_link) { munmap(_link, _bytes); }
    if (_timer) dispatch_source_cancel(_timer);
    if (_peer) xpc_connection_cancel(_peer);
}
@end
