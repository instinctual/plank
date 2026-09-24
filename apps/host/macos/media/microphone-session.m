// SPDX-License-Identifier: GPL-3.0-or-later
#import "microphone-session.h"
#import "microphone-decoder.h"
#import "../audio-device/microphone-producer.h"
#import "../audio-device/microphone-selection.h"
#import "../session/agent-registry.h"
#include <unistd.h>

@implementation PLANKMacMicrophoneSession {
    dispatch_queue_t _queue;
    PlankTransportNativeEndpoint *_endpoint;
    PLANKMacMicrophoneProducer *_producer;
    PLANKMicDecoder _decoder;
    BOOL (^_valid)(void);
    NSString *_requirement;
    uint64_t _workerGeneration, _command, _activation, _nextSample;
    uint64_t _deadline;
    uint32_t _state;
    BOOL _enabled, _stopped, _failed, _hasSample, _ackPending;
    BOOL _producerReady, _configured, _automaticInput;
}
+ (BOOL)available { return geteuid() != 0 && PLANKMicDeviceHasCurrentFormat(PLANKMicDeviceForUID(@PLANK_MIC_DEVICE_UID)); }
- (instancetype)initWithQueue:(dispatch_queue_t)queue endpoint:(PlankTransportNativeEndpoint *)endpoint
                   generation:(uint64_t)generation valid:(BOOL (^)(void))valid {
    if (!queue || !endpoint || !generation || !valid) return nil;
    self = [super init]; if (!self) return nil;
    _queue = queue; _endpoint = endpoint; _workerGeneration = generation;
    _valid = [valid copy]; _requirement = PLANKMacOwnSigningRequirement();
    _failed = !_requirement || !PLANKMicDecoderCreate(&_decoder);
    return self;
}
- (void)state:(uint32_t)state { _state = state; _ackPending = _command != 0; }
- (void)mute {
    _activation = 0; _hasSample = NO;
    plank_transport_native_microphone_activate(_endpoint, 0);
    [_producer silence]; PLANKMicDecoderReset(&_decoder);
}
- (void)fail {
    [self mute]; _failed = YES;
    // Keep an already selected virtual input silent until session teardown.
    // Reverting to a physical microphone on a media failure is not safe.
    [self state:PLANK_TRANSPORT_MICROPHONE_UNAVAILABLE];
}
- (void)advance {
    if (_stopped || _failed || !_configured) return;
    if (!_valid()) { [self fail]; return; }
    if (!_producerReady || plank_transport_native_microphone_state(_endpoint) != 2) return;
    if (_enabled && !_activation) {
        if (plank_transport_native_microphone_activate(_endpoint, _command) != PLANK_TRANSPORT_OK) {
            [self fail]; return;
        }
        _activation = _command;
    }
    [self state:_enabled ? PLANK_TRANSPORT_MICROPHONE_ACTIVE : PLANK_TRANSPORT_MICROPHONE_OFF];
}
- (BOOL)receive:(const PlankTransportControlPacket *)packet {
    dispatch_assert_queue(_queue);
    if (_stopped || !packet || packet->type != PLANK_TRANSPORT_CONTROL_SET_MICROPHONE || packet->payload_size != 12) return NO;
    uint64_t command = (uint64_t)plank_transport_control_read_u32(packet->payload) << 32 |
        plank_transport_control_read_u32(packet->payload + 4);
    uint32_t flags = plank_transport_control_read_u32(packet->payload + 8);
    if (!command || command <= _command || (flags & ~3u)) return NO;
    [self mute]; _command = command; _enabled = (flags & PLANK_TRANSPORT_MICROPHONE_ENABLED) != 0;
    BOOL automatic = (flags & PLANK_TRANSPORT_MICROPHONE_AUTO_INPUT) != 0;
    if (_failed || (_configured && automatic != _automaticInput)) { [self fail]; return YES; }
    [self state:PLANK_TRANSPORT_MICROPHONE_PENDING];
    _deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 3*NSEC_PER_SEC;
    if (!_configured) {
        _configured = YES; _automaticInput = automatic;
        __weak typeof(self) weakSelf = self;
        _producer = [[PLANKMacMicrophoneProducer alloc] initWithQueue:_queue generation:_workerGeneration
            requirement:_requirement automaticInput:automatic valid:^BOOL {
                typeof(self) owner = weakSelf;
                return owner && !owner->_stopped && owner->_valid();
            }];
        if (!_producer) { [self fail]; return YES; }
        [_producer start:^(BOOL ready) {
            typeof(self) owner = weakSelf;
            if (!owner || owner->_stopped) return;
            if (!ready) { [owner fail]; return; }
            owner->_producerReady = YES; [owner advance];
        }];
    } else [self advance];
    return YES;
}
- (void)tick {
    dispatch_assert_queue(_queue);
    if (_stopped || !_command) return;
    if (!_failed && (! _valid() || (_producerReady && !_producer.available) ||
        plank_transport_native_microphone_state(_endpoint) == 3 ||
        (_state == PLANK_TRANSPORT_MICROPHONE_PENDING && clock_gettime_nsec_np(CLOCK_MONOTONIC) >= _deadline))) [self fail];
    if (_state == PLANK_TRANSPORT_MICROPHONE_PENDING) [self advance];
    if (_ackPending) {
        uint8_t bytes[20]; size_t size = 0;
        uint32_t words[] = {(uint32_t)(_command >> 32), (uint32_t)_command, _state};
        if (!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_MICROPHONE_APPLIED, words, 3, bytes, sizeof(bytes), &size) &&
            plank_transport_native_data_send(_endpoint, bytes, size) == PLANK_TRANSPORT_OK) _ackPending = NO;
    }
    if (!_activation || _failed) return;
    for (unsigned i = 0; i < 8; i++) {
        uint8_t packet[1275]; size_t size = 0; uint64_t generation = 0, sampleTime = 0;
        int32_t result = plank_transport_native_microphone_receive(_endpoint, &generation, &sampleTime,
            packet, sizeof(packet), &size);
        if (result == PLANK_TRANSPORT_TIMEOUT) break;
        if (result != PLANK_TRANSPORT_OK) { [self fail]; break; }
        if (generation != _activation) continue;
        if (_hasSample && sampleTime != _nextSample && !PLANKMicDecoderReset(&_decoder)) { [self fail]; break; }
        float samples[480 * PLANKMicChannels];
        if (!PLANKMicDecode(&_decoder, packet, size, samples) || !_valid() ||
            ![_producer submit:samples count:480 sampleTime:sampleTime]) { [self fail]; break; }
        _hasSample = YES; _nextSample = sampleTime + 480;
    }
}
- (void)stop {
    dispatch_assert_queue(_queue);
    if (_stopped) return;
    [self mute]; _stopped = YES;
    [_producer stop]; _producer = nil;
    PLANKMicDecoderDestroy(&_decoder);
}
- (void)dealloc { PLANKMicDecoderDestroy(&_decoder); }
@end
