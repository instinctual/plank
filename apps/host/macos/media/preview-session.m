// SPDX-License-Identifier: GPL-3.0-or-later
#import "preview-session.h"
#import "fixed-capture.h"
#import "native-input.h"
#import "clipboard-sync.h"
#import "microphone-session.h"
#import "camera-session.h"
#import "media-features.h"
#include "stream-diagnostics.h"
#include "plank_transport_control.h"
#include "plank_transport_input.h"
#include "plank_transport_event.h"
#include <unistd.h>
#include <math.h>
#include <time.h>

static BOOL integerInRange(id value, uint32_t minimum, uint32_t maximum) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= minimum && number <= maximum && number == floor(number);
}

BOOL PLANKMacPreviewRequestMatchesTopology(NSDictionary *request, NSDictionary *topology) {
    request = PLANKMacNormalizeMediaLaunch(request);
    if (![request isKindOfClass:NSDictionary.class] || request.count != 12 ||
        ![topology isKindOfClass:NSDictionary.class] ||
        !integerInRange(request[@"schema_version"], 6, 6) ||
        ![request[@"clipboard"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)request[@"clipboard"]) != CFBooleanGetTypeID() ||
        ![request[@"microphone"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)request[@"microphone"]) != CFBooleanGetTypeID() ||
        ![request[@"camera"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)request[@"camera"]) != CFBooleanGetTypeID() ||
        !PLANKMacEncodingProfile(request[@"encoding_mode"]) ||
        !integerInRange(request[@"frame_rate"], 60, 60) ||
        !integerInRange(request[@"bitrate_kbps"], 10000, 150000) ||
        !integerInRange(request[@"max_udp_payload_size"], 1200, 65527) ||
        !integerInRange(request[@"width"], 2, 8192) ||
        !integerInRange(request[@"height"], 2, 8192)) return NO;
    NSDictionary *capture = topology[@"capture"];
    if (![capture isKindOfClass:NSDictionary.class] ||
        ![request[@"capture_generation"] isKindOfClass:NSString.class] ||
        ![request[@"capture_id"] isKindOfClass:NSString.class] ||
        ![request[@"capture_generation"] isEqual:topology[@"generation"]] ||
        ![request[@"capture_id"] isEqual:capture[@"id"]] ||
        ![request[@"width"] isEqual:capture[@"width"]] ||
        ![request[@"height"] isEqual:capture[@"height"]]) return NO;
    // Compare the whole trusted contract; never negotiate away precision or
    // accept a provider advertising capabilities this preview cannot implement.
    NSDictionary *bounds = capture[@"logical_bounds"];
    if (![bounds isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"x", @"y", @"width", @"height"])
        if (![bounds[key] isKindOfClass:NSNumber.class]) return NO;
    NSDictionary *expected = PLANKMacFixedCaptureDescription(topology[@"generation"], capture[@"id"],
        [request[@"width"] unsignedIntegerValue], [request[@"height"] unsignedIntegerValue],
        CGRectMake([bounds[@"x"] doubleValue], [bounds[@"y"] doubleValue],
                   [bounds[@"width"] doubleValue], [bounds[@"height"] doubleValue]), request[@"encoding_mode"]);
    return expected && [expected isEqual:topology];
}

@interface PLANKMacPreviewSession ()
@property(atomic, readwrite) PLANKMacPreviewState state;
@property(atomic, readwrite, copy) NSString *stopReason;
@end

@implementation PLANKMacPreviewSession {
    PLANKMacAuthenticationSession *_sessions;
    PLANKMacStreamLease *_lease;
    NSDictionary *(^_topology)(void);
    NSDictionary *_selected;
    id<PLANKMacPreviewCapture> _capture;
    PLANKMacNativeVideo *_video;
    PLANKMacNativeAudio *_audio;
    id<PLANKMacInputDevice> _inputDevice;
    PLANKMacNativeInput *_input;
    PLANKMacClipboardSync *_clipboard;
    PLANKMacMicrophoneSession *_microphone;
    PLANKMacCameraSession *_camera;
    uint64_t _microphoneGeneration;
    unsigned _microphoneSchema;
    PLANKMacReverseMediaClock *_mediaClock;
    dispatch_group_t _inputGroup;
    BOOL _captureDrained;
    PlankTransportNativeEndpoint *_endpoint;
    dispatch_queue_t _queue;
    dispatch_source_t _watch;
    dispatch_source_t _repeatWatch;
    uint32_t _bitrate;
    uint32_t _pendingBitrate;
    BOOL _changingBitrate;
    uint64_t _bitrateDue, _bitrateFirstRequest, _bitrateDeadline;
    BOOL _captureStarted;
    uint64_t _captureDeadline;
    NSMutableArray *_stopCallbacks;
    PLANKMacInputTiming _inputWaitTiming, _inputDeliveryTiming;
}
- (BOOL)mayBeTakenOverWithToken:(NSString *)token peer:(NSData *)peer {
    return [_sessions authorizeTakeoverToken:token peer:peer lease:_lease];
}
- (BOOL)reserveTakeoverWithToken:(NSString *)token peer:(NSData *)peer {
    return [_sessions reserveTakeoverToken:token peer:peer lease:_lease];
}

- (void)takeOverWithToken:(NSString *)token peer:(NSData *)peer
                   valid:(BOOL (^)(void))valid completion:(void (^)(BOOL))completion {
    dispatch_async(_queue, ^{
        if (!valid() || ![self mayBeTakenOverWithToken:token peer:peer]) {
            completion(NO); return;
        }
        uint32_t reason = PLANK_TRANSPORT_TERMINATION_SESSION_TAKEN_OVER;
        uint8_t packet[12]; size_t size = 0;
        if (plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_HOST_TERMINATE,
                &reason, 1, packet, sizeof(packet), &size) == 0)
            plank_transport_native_data_send(self->_endpoint, packet, size);
        // The normal stop path releases held input, revokes the lease and drains
        // capture/encoder/transport before the replacement may change geometry.
        [self->_stopCallbacks addObject:^{ completion(YES); }];
        // Give the reliable control lane a bounded opportunity to deliver the
        // terminal notice. Correctness does not depend on delivery: the Host's
        // setup reservation also rejects the old Client's reconnect attempt.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), self->_queue, ^{
            [self stopOnQueueForReason:@"session-taken-over"];
        });
    });
}
- (instancetype)init { return nil; }
- (instancetype)initWithSessions:(PLANKMacAuthenticationSession *)sessions
                           token:(NSString *)token peer:(NSData *)peer
                         request:(NSDictionary *)request topology:(NSDictionary *(^)(void))topology
                          config:(const PlankTransportConfig *)config
                         capture:(id<PLANKMacPreviewCapture>)capture
                           input:(id<PLANKMacInputDevice>)input
             microphoneGeneration:(uint64_t)microphoneGeneration {
    if (!sessions || !topology || !capture || !input || !config ||
        config->struct_size != sizeof(*config) || config->abi_version != PLANK_TRANSPORT_ABI_VERSION ||
        config->mode != PLANK_TRANSPORT_MODE_SERVER || config->session_mode != PLANK_TRANSPORT_SESSION_ACTIVE)
        return nil;
    PLANKMacAccountIdentity account = {0};
    if (![sessions authorizeToken:token peer:peer identity:&account]) return nil;
    unsigned microphoneSchema = PLANKMacMicrophoneSchema(request);
    request = PLANKMacNormalizeMediaLaunch(request);
    NSDictionary *selected = topology();
    if (!PLANKMacPreviewRequestMatchesTopology(request, selected)) return nil;
    self = [super init];
    if (!self) return nil;
    _sessionID = NSUUID.UUID.UUIDString.lowercaseString;
    _state = PLANKMacPreviewPrepared;
    _sessions = sessions;
    _selected = [selected copy]; _topology = [topology copy]; _capture = capture;
    _bitrate = [request[@"bitrate_kbps"] unsignedIntValue];
    _queue = dispatch_queue_create("la.instinctual.PLANK.Host.preview", DISPATCH_QUEUE_SERIAL);
    _stopCallbacks = [NSMutableArray array];
    _inputDevice = input; _inputGroup = dispatch_group_create();
    // LoginWindow worker is root; only the authenticated user's own desktop
    // process can enable a pasteboard. Tokens cannot cross graphical scopes.
    _clipboardEnabled = [request[@"clipboard"] boolValue] && geteuid() != 0 && account.uid == geteuid();
    _microphoneGeneration = microphoneGeneration;
    _microphoneSchema = microphoneSchema;
    if (microphoneSchema == 3) _mediaClock = [[PLANKMacReverseMediaClock alloc] init];
    _microphoneEnabled = [request[@"microphone"] boolValue] && microphoneGeneration &&
        account.uid == geteuid() && [PLANKMacMicrophoneSession available];
    _cameraEnabled = [request[@"camera"] boolValue] && microphoneGeneration &&
        account.uid == geteuid() && [PLANKMacCameraSession available];
    _lease = [sessions claimToken:token peer:peer];
    if (!_lease) return nil;
    PlankTransportConfig configuration = *config;
    configuration.session_token = _lease.transportToken.UTF8String;
    configuration.max_udp_payload_size = [request[@"max_udp_payload_size"] unsignedIntValue];
    configuration.initial_video_bitrate_kbps = _bitrate;
    // Bound incomplete connection setup; no user-controlled timeout override.
    configuration.handshake_timeout_ms = 10000;
    if (plank_transport_native_endpoint_create(&configuration, &_endpoint) != PLANK_TRANSPORT_OK ||
        ![_selected isEqual:_topology()]) return nil;
    return self;
}
- (NSString *)transportToken { return _lease.transportToken; }

- (void)start {
    dispatch_async(_queue, ^{
        if (self.state != PLANKMacPreviewPrepared) return;
        self.state = PLANKMacPreviewConnecting;
        if (plank_transport_native_endpoint_start(self->_endpoint) != PLANK_TRANSPORT_OK) {
            [self stopOnQueueForReason:@"transport-start-failed"]; return;
        }
        __weak typeof(self) weakSelf = self;
        self->_watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        // One bounded lifecycle/control source, no blocking receive worker or
        // per-frame timer. The encoder itself remains capture-driven.
        dispatch_source_set_timer(self->_watch, DISPATCH_TIME_NOW,
            ((self->_microphoneEnabled || self->_cameraEnabled) ? 10 : 20) * NSEC_PER_MSEC, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(self->_watch, ^{ [weakSelf tick]; });
        dispatch_resume(self->_watch);
    });
}

- (void)tick {
    @autoreleasepool {
        if (self.state != PLANKMacPreviewConnecting && self.state != PLANKMacPreviewStreaming) return;
        PLANKMacAccountIdentity identity = {0};
        // Also prunes an expired pending lease before QUIC has authenticated.
        BOOL active = [_sessions authorizeStreamLease:_lease identity:&identity];
        if (!_lease.transportToken) { [self stopOnQueueForReason:@"lease-ended"]; return; }
        if (![_selected isEqual:_topology()]) { [self stopOnQueueForReason:@"topology-changed"]; return; }
        uint32_t state = plank_transport_native_endpoint_state(_endpoint);
        if (state == PLANK_TRANSPORT_STATE_FAILED || state == PLANK_TRANSPORT_STATE_STOPPING ||
            state == PLANK_TRANSPORT_STATE_STOPPED || state == PLANK_TRANSPORT_STATE_INVALID) {
            [self stopOnQueueForReason:@"transport-ended"]; return;
        }
        if (self.state == PLANKMacPreviewConnecting && !_captureStarted && state == PLANK_TRANSPORT_STATE_READY) {
            if (![_sessions activateStreamLease:_lease]) { [self stopOnQueueForReason:@"lease-activation-failed"]; return; }
            if (_microphoneEnabled && plank_transport_native_microphone_enable_version(_endpoint, _microphoneSchema) != PLANK_TRANSPORT_OK)
                NSLog(@"PLANK microphone endpoint could not be enabled; video and output audio remain available");
            if (_cameraEnabled && plank_transport_native_camera_enable(_endpoint, _microphoneEnabled ? 1 : 0) != PLANK_TRANSPORT_OK)
                NSLog(@"PLANK camera endpoint could not be enabled; other media remain available");
            __weak typeof(self) weakSelf = self;
            _video = [[PLANKMacNativeVideo alloc] initWithEndpoint:_endpoint sessions:_sessions lease:_lease
                width:[_selected[@"capture"][@"width"] intValue] height:[_selected[@"capture"][@"height"] intValue]
                validity:^BOOL {
                    typeof(self) owner = weakSelf;
                    return owner && [owner->_selected isEqual:owner->_topology()];
                }];
            _audio = [[PLANKMacNativeAudio alloc] initWithEndpoint:_endpoint sessions:_sessions lease:_lease
                validity:^BOOL {
                    typeof(self) owner = weakSelf;
                    return owner && [owner->_selected isEqual:owner->_topology()];
                }];
            PLANKMacInputEvents *events = [_inputDevice eventsForTopology:_selected];
            id<PLANKMacInputDevice> device = _inputDevice;
            _input = [[PLANKMacNativeInput alloc] initWithEndpoint:_endpoint sessions:_sessions lease:_lease
                events:events validity:^BOOL {
                    typeof(self) owner = weakSelf;
                    return owner && [owner->_selected isEqual:owner->_topology()] && [device available];
                } deliver:^(CGEventRef event, BOOL userActivity) {
                    [device postEvent:event userActivity:userActivity];
                }];
            if (!_video || !_audio || !_input) { [self stopOnQueueForReason:@"media-input-initialization-failed"]; return; }
            _captureStarted = YES;
            _captureDeadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 5 * NSEC_PER_SEC;
            [_capture startWithTopology:_selected bitrate:_bitrate video:_video audio:_audio queue:_queue
                started:^(uint32_t peak) {
                    typeof(self) owner = weakSelf;
                    if (!owner || owner.state != PLANKMacPreviewConnecting) return;
                    if (peak < owner->_bitrate ||
                        plank_transport_native_set_video_bitrate(owner->_endpoint, owner->_bitrate, peak) != PLANK_TRANSPORT_OK) {
                        [owner stopOnQueueForReason:@"initial-bitrate-failed"]; return;
                    }
                    owner.state = PLANKMacPreviewStreaming;
                    [owner startClipboard];
                    [owner startMicrophone];
                    [owner startCamera];
                    [owner startInputReceiver];
                }
                failed:^{ [weakSelf stopOnQueueForReason:@"capture-failed"]; }];
        } else if (_captureStarted && !active) {
            [self stopOnQueueForReason:@"stream-authorization-ended"]; return;
        }
        if (_captureStarted && ![_inputDevice available]) { [self stopOnQueueForReason:@"input-permission-unavailable"]; return; }
        if (_captureStarted && self.state == PLANKMacPreviewConnecting &&
            clock_gettime_nsec_np(CLOCK_MONOTONIC) >= _captureDeadline) { [self stopOnQueueForReason:@"capture-start-timeout"]; return; }
        if (self.state == PLANKMacPreviewStreaming) {
            [self receiveControls];
            [self applyPendingBitrate];
            [_clipboard tick];
            [_microphone tick];
            [_camera tick];
        }
    }
}

- (void)startMicrophone {
    if (!_microphoneEnabled) return;
    __weak typeof(self) weakSelf = self;
    _microphone = [[PLANKMacMicrophoneSession alloc] initWithQueue:_queue endpoint:_endpoint
        generation:_microphoneGeneration valid:^BOOL {
            typeof(self) owner = weakSelf;
            PLANKMacAccountIdentity account = {0};
            return owner && owner.state == PLANKMacPreviewStreaming &&
                [owner->_sessions authorizeStreamLease:owner->_lease identity:&account] &&
                account.uid == geteuid() && [owner->_selected isEqual:owner->_topology()];
        }];
    _microphone.mediaClock = _mediaClock;
}
- (void)startCamera {
    if (!_cameraEnabled) return;
    __weak typeof(self) weakSelf = self;
    _camera = [[PLANKMacCameraSession alloc] initWithQueue:_queue endpoint:_endpoint
        generation:_microphoneGeneration valid:^BOOL {
            typeof(self) owner = weakSelf;
            PLANKMacAccountIdentity account = {0};
            return owner && owner.state == PLANKMacPreviewStreaming &&
                [owner->_sessions authorizeStreamLease:owner->_lease identity:&account] &&
                account.uid == geteuid() && [owner->_selected isEqual:owner->_topology()];
        }];
    _camera.mediaClock = _mediaClock;
}
- (void)startClipboard {
    if (!_clipboardEnabled) return;
    __weak typeof(self) weakSelf = self;
    _clipboard = [[PLANKMacClipboardSync alloc] initWithQueue:_queue allowed:^BOOL {
        typeof(self) owner = weakSelf;
        PLANKMacAccountIdentity account = {0};
        return owner && owner.state == PLANKMacPreviewStreaming &&
            [owner->_sessions authorizeStreamLease:owner->_lease identity:&account] &&
            account.uid == geteuid() && geteuid() != 0;
    } send:^int32_t(NSData *frame) {
        typeof(self) owner = weakSelf;
        if (!owner || owner.state != PLANKMacPreviewStreaming) return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        NSMutableData *packet = [NSMutableData dataWithLength:PLANK_TRANSPORT_EVENT_HEADER_SIZE + frame.length];
        size_t size = 0;
        if (plank_transport_event_encode(PLANK_TRANSPORT_EVENT_CLIPBOARD_OFFER, frame.bytes, frame.length,
                packet.mutableBytes, packet.length, &size)) return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        __block int32_t result = PLANK_TRANSPORT_ERROR_INVALID_STATE;
        [owner->_sessions performWithStreamLease:owner->_lease action:^{
            result = plank_transport_native_data_send(owner->_endpoint, packet.bytes, size);
        }];
        return result;
    }];
}

- (void)startInputReceiver {
    // Native receive sleeps on the transport's condition variable, not on a
    // polling timer. At most one received packet awaits the serial owner queue;
    // no extra input backlog and no input latency from the 20-ms watchdog.
    __weak typeof(self) weakSelf = self;
    _repeatWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_repeatWatch, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(_repeatWatch, ^{
        typeof(self) owner = weakSelf;
        if (!owner || owner.state != PLANKMacPreviewStreaming) return;
        PLANKMacInputResult result = [owner->_input repeatAtTime:clock_gettime_nsec_np(CLOCK_UPTIME_RAW)];
        if (result == PLANKMacInputDenied || result == PLANKMacInputStopped || result == PLANKMacInputMalformed) {
            [owner stopOnQueueForReason:[NSString stringWithFormat:@"key-repeat-rejected result=%u", (unsigned)result]]; return;
        }
        [owner scheduleKeyRepeat];
    });
    dispatch_resume(_repeatWatch);
    PlankTransportNativeEndpoint *endpoint = _endpoint;
    dispatch_queue_t ownerQueue = _queue;
    dispatch_group_async(_inputGroup, dispatch_queue_create("la.instinctual.PLANK.Host.input", DISPATCH_QUEUE_SERIAL), ^{
        BOOL running = YES;
        while (running) @autoreleasepool {
            uint8_t bytes[PLANK_TRANSPORT_INPUT_MAX_PAYLOAD_SIZE], type = 0; size_t size = 0;
            int32_t result = plank_transport_native_input_receive(endpoint, &type, bytes, sizeof(bytes), &size, 1000);
            uint64_t receivedAt = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            const uint8_t *payload = bytes;
            // The synchronous handoff bounds outstanding work to one packet.
            // It also prevents input from racing capture/control teardown.
            __block BOOL keepGoing = NO;
            dispatch_sync(ownerQueue, ^{
                typeof(self) owner = weakSelf;
                if (!owner || owner.state != PLANKMacPreviewStreaming) return;
                if (result == PLANK_TRANSPORT_TIMEOUT) { keepGoing = YES; return; }
                if (result != PLANK_TRANSPORT_OK) {
                    [owner stopOnQueueForReason:[NSString stringWithFormat:@"input-receive-failed result=%d", result]]; return;
                }
                PLANKMacInputTimingNote(&owner->_inputWaitTiming, receivedAt, clock_gettime_nsec_np(CLOCK_MONOTONIC));
                if (type == PLANK_TRANSPORT_INPUT_CLIPBOARD_OFFER) {
                    if (!owner->_clipboard || ![owner->_clipboard receive:[NSData dataWithBytes:payload length:size]]) {
                        [owner stopOnQueueForReason:@"clipboard-rejected"]; return;
                    }
                    keepGoing = YES; return;
                }
                uint64_t deliveryAt = clock_gettime_nsec_np(CLOCK_MONOTONIC);
                PLANKMacInputResult delivered = [owner->_input consumeType:type
                    payload:[NSData dataWithBytes:payload length:size] time:clock_gettime_nsec_np(CLOCK_UPTIME_RAW)];
                PLANKMacInputTimingNote(&owner->_inputDeliveryTiming, deliveryAt, clock_gettime_nsec_np(CLOCK_MONOTONIC));
                if (delivered == PLANKMacInputMalformed || delivered == PLANKMacInputDenied || delivered == PLANKMacInputStopped) {
                    NSString *cause = delivered == PLANKMacInputMalformed ? @"malformed" :
                        delivered == PLANKMacInputDenied ? @"denied" : @"stopped";
                    [owner stopOnQueueForReason:[NSString stringWithFormat:@"input-%@ type=%u", cause, (unsigned)type]]; return;
                }
                [owner scheduleKeyRepeat];
                keepGoing = YES; // Unsupported platform-specific keys do not become unrelated keys.
            });
            running = keepGoing;
        }
    });
    dispatch_group_notify(_inputGroup, _queue, ^{ [weakSelf finishStop]; });
}

- (void)scheduleKeyRepeat {
    if (!_repeatWatch) return;
    uint64_t due = _input.nextRepeatTime, now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    dispatch_time_t start = due ? dispatch_time(DISPATCH_TIME_NOW, due > now ? (int64_t)(due - now) : 0) : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(_repeatWatch, start, DISPATCH_TIME_FOREVER, 500000);
}

- (void)receiveControls {
    // Bound each iteration so a client cannot starve teardown/encoder callbacks.
    for (unsigned index = 0; index < 8; ++index) {
        uint8_t bytes[PLANK_TRANSPORT_CONTROL_MAX_PACKET_SIZE]; size_t size = 0;
        int32_t result = plank_transport_native_data_receive(_endpoint, bytes, sizeof(bytes), &size, 0);
        if (result == PLANK_TRANSPORT_TIMEOUT) return;
        PlankTransportControlPacket packet;
        if (result != PLANK_TRANSPORT_OK) {
            [self stopOnQueueForReason:[NSString stringWithFormat:@"control-receive-failed result=%d", result]]; return;
        }
        if (plank_transport_control_decode(bytes, size, &packet)) {
            [self stopOnQueueForReason:@"control-malformed"]; return;
        }
        if (packet.type == PLANK_TRANSPORT_CONTROL_CLIENT_DISCONNECT && !packet.payload_size) {
            [self stopOnQueueForReason:@"client-disconnect"]; return;
        } else if (packet.type == PLANK_TRANSPORT_CONTROL_REQUEST_IDR && !packet.payload_size) {
            [_video requestKeyFrame];
        } else if (packet.type == PLANK_TRANSPORT_CONTROL_INVALIDATE_REFERENCE_FRAMES && packet.payload_size == 8 &&
                   plank_transport_control_read_u32(packet.payload) <= plank_transport_control_read_u32(packet.payload + 4)) {
            // VideoToolbox recovery is a fresh keyframe, not selective invalidation.
            [_video requestKeyFrame];
        } else if (packet.type == PLANK_TRANSPORT_CONTROL_SET_VIDEO_BITRATE && packet.payload_size == 4) {
            uint32_t bitrate = plank_transport_control_read_u32(packet.payload);
            if (bitrate < 10000 || bitrate > 150000) {
                [self stopOnQueueForReason:@"bitrate-out-of-range"]; return;
            }
            uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            if (!_pendingBitrate) _bitrateFirstRequest = now;
            if (_pendingBitrate != bitrate) {
                _pendingBitrate = bitrate;
                _bitrateDue = MIN(now + 150*NSEC_PER_MSEC, _bitrateFirstRequest + 500*NSEC_PER_MSEC);
            }
        } else if (packet.type == PLANK_TRANSPORT_CONTROL_SET_CAMERA && _cameraEnabled) {
            if (!_camera || ![_camera receive:&packet]) {
                [self stopOnQueueForReason:@"camera-control-rejected"]; return;
            }
        } else if (packet.type == PLANK_TRANSPORT_CONTROL_SET_MICROPHONE && _microphoneEnabled) {
            if (!_microphone || ![_microphone receive:&packet]) {
                [self stopOnQueueForReason:@"microphone-control-rejected"]; return;
            }
        } else { [self stopOnQueueForReason:@"control-unsupported"]; return; }
    }
}

- (void)acknowledgeBitrate:(uint32_t)bitrate peak:(uint32_t)peak {
    uint32_t values[] = {bitrate, bitrate, peak};
    uint8_t reply[20]; size_t size = 0;
    if (plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_VIDEO_BITRATE_APPLIED,
        values, 3, reply, sizeof(reply), &size) ||
        plank_transport_native_data_send(_endpoint, reply, size) != PLANK_TRANSPORT_OK)
        [self stopOnQueueForReason:@"bitrate-acknowledgment-failed"];
}
- (void)applyPendingBitrate {
    if (self.state != PLANKMacPreviewStreaming) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (_changingBitrate) {
        if (now >= _bitrateDeadline) {
            [self stopOnQueueForReason:@"encoder-replacement-timeout"];
        }
        return;
    }
    if (!_pendingBitrate || now < _bitrateDue) return;
    uint32_t bitrate = _pendingBitrate; _pendingBitrate = 0;
    if (bitrate == _bitrate) { [self acknowledgeBitrate:bitrate peak:bitrate * 2]; return; }
    _changingBitrate = YES; _bitrateDeadline = now + 5*NSEC_PER_SEC;
    __weak typeof(self) weakSelf = self;
    [_capture setBitrate:bitrate completion:^(uint32_t peak) {
        typeof(self) owner = weakSelf;
        if (!owner || owner.state != PLANKMacPreviewStreaming) return;
        owner->_changingBitrate = NO;
        if (peak < bitrate ||
            plank_transport_native_set_video_bitrate(owner->_endpoint, bitrate, peak) != PLANK_TRANSPORT_OK) {
            [owner stopOnQueueForReason:@"bitrate-update-failed"]; return;
        }
        owner->_bitrate = bitrate;
        [owner acknowledgeBitrate:bitrate peak:peak];
    }];
}

- (void)stopWithCompletion:(void (^)(void))completion {
    dispatch_async(_queue, ^{
        if (self.state == PLANKMacPreviewStopped) { if (completion) completion(); return; }
        if (completion) [self->_stopCallbacks addObject:[completion copy]];
        [self stopOnQueueForReason:@"owner-stop"];
    });
}
- (void)stopOnQueueForReason:(NSString *)reason {
    if (self.state == PLANKMacPreviewStopping || self.state == PLANKMacPreviewStopped) return;
    self.stopReason = reason;
    // One first-cause line per session, before revocation/drain hides the cause.
    // Log no remote strings, coordinates, keys, text, accounts or tokens.
    char transportError[1024] = {0};
    if (_endpoint) plank_transport_native_endpoint_last_error(_endpoint, transportError, sizeof(transportError));
    NSLog(@"PLANK stream stopping: reason=%@ state=%u transport-state=%u transport-failure=%s", reason,
        (unsigned)self.state, _endpoint ? plank_transport_native_endpoint_state(_endpoint) : PLANK_TRANSPORT_STATE_INVALID,
        PLANKMacTransportFailureClass(transportError));
    NSLog(@"PLANK input timing: owner-wait-count=%llu owner-wait-over20ms=%llu owner-wait-max-ms=%.3f delivery-count=%llu delivery-over20ms=%llu delivery-max-ms=%.3f",
        (unsigned long long)_inputWaitTiming.count, (unsigned long long)_inputWaitTiming.slow,
        (double)_inputWaitTiming.maximum / NSEC_PER_MSEC,
        (unsigned long long)_inputDeliveryTiming.count, (unsigned long long)_inputDeliveryTiming.slow,
        (double)_inputDeliveryTiming.maximum / NSEC_PER_MSEC);
    self.state = PLANKMacPreviewStopping;
    [_clipboard stop];
    [_microphone stop]; _microphone = nil;
    [_camera stop]; _camera = nil;
    if (_repeatWatch) { dispatch_source_cancel(_repeatWatch); _repeatWatch = nil; }
    [_input stop]; // authorized releases first; never release into a replacement desktop
    [_inputDevice stopUserActivity]; // release even if capture/input startup failed
    [_sessions endStreamLease:_lease]; // revoke before any asynchronous drain
    if (_watch) { dispatch_source_cancel(_watch); _watch = nil; }
    // Close the network even if a framework stop callback stalls. Keep the
    // allocated endpoint until drain so no borrowed callback sees freed memory.
    if (_endpoint) plank_transport_native_endpoint_stop(_endpoint);
    if (_captureStarted) [_capture stopWithCompletion:^{ self->_captureDrained = YES; [self finishStop]; }];
    else { _captureDrained = YES; [self finishStop]; }
}
- (void)finishStop {
    if (self.state != PLANKMacPreviewStopping || !_captureDrained ||
        dispatch_group_wait(_inputGroup, DISPATCH_TIME_NOW) != 0) return;
    _video = nil;
    _audio = nil;
    _input = nil; _inputDevice = nil;
    _clipboard = nil;
    if (_endpoint) {
        PlankTransportNativeStats stats = {0}; stats.struct_size = sizeof(stats);
        if (plank_transport_native_endpoint_stats(_endpoint, &stats) == PLANK_TRANSPORT_OK)
            NSLog(@"PLANK transport summary: video-sent=%llu video-send-drops=%llu audio-sent=%llu audio-send-drops=%llu",
                (unsigned long long)stats.video_frames_sent, (unsigned long long)stats.video_send_drops,
                (unsigned long long)stats.audio_packets_sent, (unsigned long long)stats.audio_send_drops);
        plank_transport_native_endpoint_destroy(_endpoint); _endpoint = NULL;
    }
    _capture = nil;
    self.state = PLANKMacPreviewStopped;
    NSArray *callbacks = [_stopCallbacks copy]; [_stopCallbacks removeAllObjects];
    for (void (^callback)(void) in callbacks) callback();
}
- (void)dealloc {
    [_clipboard stop];
    [_sessions endStreamLease:_lease];
    if (_watch) dispatch_source_cancel(_watch);
    if (_repeatWatch) dispatch_source_cancel(_repeatWatch);
    // Fail closed even if a caller abandons the owner: retain the borrowed
    // endpoint/video until asynchronous capture drain, without capturing self.
    PlankTransportNativeEndpoint *endpoint = _endpoint;
    PLANKMacMicrophoneSession *microphone = _microphone;
    PLANKMacCameraSession *camera = _camera;
    // Wake the condition-variable receiver before waiting for its bounded
    // handoff. Never block the serial owner queue waiting for that handoff.
    if (endpoint) plank_transport_native_endpoint_stop(endpoint);
    if (_captureStarted && _capture && _queue) {
        id<PLANKMacPreviewCapture> capture = _capture;
        PLANKMacNativeVideo *video = _video;
        PLANKMacNativeAudio *audio = _audio;
        PLANKMacNativeInput *input = _input;
        dispatch_group_notify(_inputGroup, _queue, ^{
            [microphone stop]; [camera stop];
            [capture stopWithCompletion:^{
                (void)video;
                (void)audio;
                (void)input;
                if (endpoint) plank_transport_native_endpoint_destroy(endpoint);
            }];
        });
    } else if (endpoint) {
        // Normal teardown runs on the owner queue. Abandonment may not; retain
        // the optional input owner until it has revoked capture on that queue.
        if (microphone || camera) dispatch_async(_queue, ^{
            [microphone stop]; [camera stop]; plank_transport_native_endpoint_destroy(endpoint);
        });
        else plank_transport_native_endpoint_destroy(endpoint);
    }
}
@end
