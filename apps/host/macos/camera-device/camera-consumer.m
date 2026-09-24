// SPDX-License-Identifier: GPL-3.0-or-later
#import "camera-consumer.h"
#include "camera-link.h"
#include "camera-clock.h"
#include <xpc/xpc.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static uint64_t cameraNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
static BOOL cameraWord(xpc_object_t object, const char *name, uint64_t *value) {
    xpc_object_t item = xpc_dictionary_get_value(object, name);
    if (!item || xpc_get_type(item) != XPC_TYPE_UINT64) return NO;
    *value = xpc_uint64_get_value(item); return YES;
}
@implementation PLANKMacCameraConsumer {
    dispatch_queue_t _queue;
    NSString *_requirement;
    xpc_connection_t _peer;
    dispatch_source_t _timer;
    PLANKCameraLink *_link;
    uint8_t *_record;
    size_t _bytes;
    uint64_t _lease, _deadline, _connectAt, _cursor, _keyAt;
    BOOL _started, _stopped;
    void (^_admission)(uint64_t);
    void (^_frame)(const uint8_t *, size_t, uint64_t, uint64_t);
    void (^_gap)(void);
}
- (instancetype)init { return nil; }
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
                        lease:(void (^)(uint64_t))lease
                        frame:(void (^)(const uint8_t *, size_t, uint64_t, uint64_t))frame
                          gap:(void (^)(void))gap {
    long page = sysconf(_SC_PAGESIZE);
    if (!queue || !requirement.length || !lease || !frame || !gap || page <= 0) return nil;
    if (!(self = [super init])) return nil;
    _queue = queue; _requirement = [requirement copy]; _bytes = PLANKCameraLinkBytes((size_t)page);
    _admission = [lease copy]; _frame = [frame copy]; _gap = [gap copy];
    _record = malloc(PLANKCameraRecordBytes); if (!_record) return nil;
    return self;
}
- (BOOL)available { dispatch_assert_queue(_queue); return _lease && !_stopped && cameraNow() < _deadline; }
- (void)drop {
    if (_lease) _admission(0);
    if (_link) munmap(_link, _bytes);
    _link = NULL; _lease = _deadline = _cursor = _keyAt = 0;
}
- (void)disconnect {
    [self drop];
    if (_peer) xpc_connection_cancel(_peer);
    _peer = nil;
}
- (void)receive:(xpc_object_t)message peer:(xpc_connection_t)peer {
    if (_peer != peer || _stopped) return;
    uint64_t version = 0, operation = 0, lease = 0;
    BOOL valid = xpc_get_type(message) == XPC_TYPE_DICTIONARY && xpc_connection_get_euid(peer) == 0 &&
        cameraWord(message, "version", &version) && version == PLANKCameraLinkVersion &&
        cameraWord(message, "operation", &operation) && cameraWord(message, "lease", &lease) && lease;
    xpc_object_t reply = valid ? xpc_dictionary_create_reply(message) : NULL;
    if (!reply) { [self disconnect]; return; }
    BOOL accepted = NO;
    if (operation == 1 && xpc_dictionary_get_count(message) == 5) {
        uint64_t activation = 0;
        xpc_object_t memory = xpc_dictionary_get_value(message, "memory");
        if (cameraWord(message, "activation", &activation) && activation && memory && xpc_get_type(memory) == XPC_TYPE_SHMEM) {
            void *mapping = NULL; size_t size = xpc_shmem_map(memory, &mapping);
            if (mapping && size == _bytes && atomic_load(&((PLANKCameraLink *)mapping)->version) == PLANKCameraLinkVersion) {
                [self drop]; _link = mapping; _lease = lease;
                _deadline = cameraNow() + 2 * NSEC_PER_SEC;
                _admission(activation); [self requestKeyframe]; accepted = YES;
            } else if (mapping) munmap(mapping, size);
        }
    } else if (operation == 2 && xpc_dictionary_get_count(message) == 3 && lease == _lease && cameraNow() < _deadline) {
        // The producer cannot extend this private deadline via shared memory.
        _deadline = cameraNow() + 2 * NSEC_PER_SEC; accepted = YES;
    } else if (operation == 3 && xpc_dictionary_get_count(message) == 3) {
        if (lease == _lease) [self drop];
        accepted = YES;
    }
    xpc_dictionary_set_bool(reply, "accepted", accepted);
    xpc_connection_send_message(peer, reply);
    if (!accepted) [self disconnect];
}
- (void)connect {
    _peer = xpc_connection_create_mach_service(PLANK_CAMERA_EXTENSION_SERVICE, _queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!_peer) return;
    __weak typeof(self) weakSelf = self;
    // Capture weakly to avoid a peer -> handler -> peer ownership cycle.
    __weak xpc_connection_t weakPeer = _peer;
    xpc_connection_set_event_handler(_peer, ^(xpc_object_t message) {
        xpc_connection_t peer = weakPeer; if (peer) [weakSelf receive:message peer:peer];
    });
    if (xpc_connection_set_peer_code_signing_requirement(_peer, _requirement.UTF8String)) {
        xpc_connection_cancel(_peer); xpc_connection_activate(_peer); _peer = nil; return;
    }
    xpc_connection_activate(_peer);
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(hello, "version", PLANKCameraLinkVersion);
    xpc_connection_send_message(_peer, hello);
}
- (void)rejectLease { dispatch_assert_queue(_queue); [self disconnect]; }
- (void)requestKeyframe {
    dispatch_assert_queue(_queue);
    uint64_t now = cameraNow();
    if (!_link || now >= _deadline || now < _keyAt) return;
    atomic_fetch_add(&_link->keyRequest, 1); _keyAt = now + 200 * NSEC_PER_MSEC;
}
- (void)tick {
    if (_stopped) return;
    uint64_t now = cameraNow();
    if (!_peer && now >= _connectAt) { _connectAt = now + NSEC_PER_SEC; [self connect]; }
    if (!_link) return;
    if (now >= _deadline) { [self disconnect]; return; }
    size_t size = 0; uint64_t time = 0, arrived = 0;
    int result = PLANKCameraLinkReadTimed(_link, &_cursor, _record, PLANKCameraRecordBytes, &size, &time, &arrived, PLANKCameraHostTimeNanos());
    if (result > 0) _frame(_record, size, time, arrived);
    else if (result < 0) { _gap(); [self requestKeyframe]; }
}
- (void)start {
    dispatch_assert_queue(_queue);
    if (_started || _stopped) return;
    _started = YES;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; }); dispatch_resume(_timer);
}
- (void)stop {
    dispatch_assert_queue(_queue);
    if (_stopped) return;
    _stopped = YES; [self disconnect];
    if (_timer) dispatch_source_cancel(_timer);
}
- (void)dealloc {
    if (_link) munmap(_link, _bytes);
    if (_peer) xpc_connection_cancel(_peer);
    if (_timer) dispatch_source_cancel(_timer);
    free(_record);
}
@end
