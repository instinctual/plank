// SPDX-License-Identifier: GPL-3.0-or-later
#import "camera-session.h"
#import "../camera-device/camera-producer.h"
#import "../camera-device/camera-signing.h"
#import "../camera-device/camera-clock.h"
#import "../session/agent-registry.h"
#include "plank_transport_camera.h"
#include <unistd.h>

@implementation PLANKMacCameraSession {
    dispatch_queue_t _queue;
    PlankTransportNativeEndpoint *_endpoint;
    PLANKMacCameraProducer *_producer;
    BOOL (^_valid)(void);
    NSString *_requirement;
    uint8_t *_record;
    uint64_t _workerGeneration, _command, _activation, _deadline, _keyAt, _receivedAt;
    uint32_t _state;
    BOOL _stopped, _ackPending, _producerReady, _keyPending;
}
+ (BOOL)available {
    // This advertises installed capability, never camera consent or extension
    // readiness. Explicit activation is acknowledged only after broker admission.
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
        @"Contents/Library/SystemExtensions/la.instinctual.PLANK.Host.Camera.systemextension"];
    return geteuid() != 0 && PLANKCameraPeerRequirement(@"la.instinctual.PLANK.Host.Camera") &&
        [NSBundle bundleWithPath:path] != nil;
}
- (instancetype)init { return nil; }
- (instancetype)initWithQueue:(dispatch_queue_t)queue endpoint:(PlankTransportNativeEndpoint *)endpoint
                   generation:(uint64_t)generation valid:(BOOL (^)(void))valid {
    if (!queue || !endpoint || !generation || !valid || !(self = [super init])) return nil;
    _queue = queue; _endpoint = endpoint; _workerGeneration = generation; _valid = [valid copy];
    _requirement = PLANKMacOwnSigningRequirement();
    _record = malloc(PLANK_CAMERA_HEADER_BYTES + PLANK_CAMERA_MAX_FRAME_BYTES);
    if (!_requirement || !_record) return nil;
    return self;
}
- (void)state:(uint32_t)state { _state = state; _ackPending = _command != 0; }
- (void)close {
    _activation = 0; _producerReady = NO; _keyPending = NO;
    plank_transport_native_camera_activate(_endpoint, 0);
    // Remove the owner before cancellation can call its pending ready callback.
    PLANKMacCameraProducer *producer = _producer; _producer = nil; [producer stop];
}
- (void)fail { [self close]; [self state:PLANK_TRANSPORT_CAMERA_UNAVAILABLE]; }
- (void)advance {
    if (!_activation || _state != PLANK_TRANSPORT_CAMERA_PENDING || !_producerReady) return;
    if (!_valid()) { [self fail]; return; }
    if (plank_transport_native_camera_state(_endpoint) != 2) return;
    if (plank_transport_native_camera_activate(_endpoint, _activation) != PLANK_TRANSPORT_OK) { [self fail]; return; }
    _receivedAt = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    [self state:PLANK_TRANSPORT_CAMERA_ACTIVE];
}
- (BOOL)receive:(const PlankTransportControlPacket *)packet {
    dispatch_assert_queue(_queue);
    uint64_t command = 0; uint32_t flags = 0;
    if (_stopped || !packet || packet->type != PLANK_TRANSPORT_CONTROL_SET_CAMERA ||
        plank_camera_control_decode(packet, &command, &flags) || command <= _command) return NO;
    [self close]; _command = command; _keyAt = 0;
    if (!flags) { [self state:PLANK_TRANSPORT_CAMERA_OFF]; return YES; }
    if (!_valid()) { [self fail]; return YES; }
    _activation = command; [self state:PLANK_TRANSPORT_CAMERA_PENDING];
    _deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 3 * NSEC_PER_SEC;
    __weak typeof(self) weakSelf = self;
    _producer = [[PLANKMacCameraProducer alloc] initWithQueue:_queue generation:_workerGeneration
        activation:command requirement:_requirement valid:^BOOL {
            typeof(self) owner = weakSelf;
            return owner && !owner->_stopped && owner->_activation == command && owner->_valid();
        }];
    if (!_producer) { [self fail]; return YES; }
    __weak PLANKMacCameraProducer *weakProducer = _producer;
    [_producer start:^(BOOL ready) {
        typeof(self) owner = weakSelf;
        if (!owner || owner->_stopped || !owner->_producer || owner->_producer != weakProducer || owner->_activation != command) return;
        if (!ready) { [owner fail]; return; }
        owner->_producerReady = YES; [owner advance];
    }];
    return YES;
}
- (void)tick {
    dispatch_assert_queue(_queue);
    if (_stopped || !_command) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (_activation && (!_valid() || (_producerReady && !_producer.available) ||
        plank_transport_native_camera_state(_endpoint) == 3 ||
        (_state == PLANK_TRANSPORT_CAMERA_PENDING && now >= _deadline) ||
        (_state == PLANK_TRANSPORT_CAMERA_ACTIVE && now - _receivedAt >= 3 * NSEC_PER_SEC))) [self fail];
    [self advance];
    if (_ackPending) {
        uint8_t packet[20]; size_t size = 0;
        uint32_t words[] = {(uint32_t)(_command >> 32), (uint32_t)_command, _state};
        if (!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_CAMERA_APPLIED, words, 3, packet, sizeof(packet), &size) &&
            plank_transport_native_data_send(_endpoint, packet, size) == PLANK_TRANSPORT_OK) _ackPending = NO;
    }
    if (!_activation || _state != PLANK_TRANSPORT_CAMERA_ACTIVE) return;
    for (unsigned i = 0; i < 3; i++) {
        size_t size = 0;
        int32_t result = plank_transport_native_camera_receive(_endpoint, _record,
            PLANK_CAMERA_HEADER_BYTES + PLANK_CAMERA_MAX_FRAME_BYTES, &size);
        if (result == PLANK_TRANSPORT_TIMEOUT) break;
        if (result != PLANK_TRANSPORT_OK) { [self fail]; break; }
        PlankCameraHeader header;
        if (plank_camera_header_decode(_record, size, &header) || header.generation != _activation) continue;
        uint64_t presentation = PLANKCameraHostTimeNanos();
        if (_mediaClock && PLANKReverseMediaClockActive(&_mediaClock->value, presentation)) {
            presentation = PLANKReverseMediaClockMap(&_mediaClock->value, header.capture_time_us * 1000, presentation);
            if (!presentation) { _keyPending = YES; continue; }
        }
        if (!_valid() || ![_producer submit:_record size:size hostTimeNanos:presentation]) { [self fail]; break; }
        _receivedAt = now;
    }
    if (_activation && (plank_transport_native_camera_keyframe_needed(_endpoint) == _activation || [_producer takeKeyframeRequest])) _keyPending = YES;
    if (_activation && now >= _keyAt && _keyPending) {
        uint8_t packet[16]; size_t size = 0;
        uint32_t words[] = {(uint32_t)(_activation >> 32), (uint32_t)_activation};
        if (!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_CAMERA_KEYFRAME, words, 2, packet, sizeof(packet), &size) &&
            plank_transport_native_data_send(_endpoint, packet, size) == PLANK_TRANSPORT_OK) { _keyAt = now + 500 * NSEC_PER_MSEC; _keyPending = NO; }
    }
}
- (void)stop {
    dispatch_assert_queue(_queue);
    if (_stopped) return;
    _stopped = YES; [self close];
}
- (void)dealloc { free(_record); }
@end
