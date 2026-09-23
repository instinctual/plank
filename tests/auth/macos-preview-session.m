// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic capture/account, actual native QUIC; no desktop pixels or changes.
#import "preview-session.h"
#import "fixed-capture.h"
#import "macos-fake-input.h"
#import "agent-connection.h"
#include "plank_transport_control.h"
#include "plank_transport_input.h"
#include <unistd.h>
#include <sys/resource.h>

static unsigned checks;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "check failed line %d: %s\n", __LINE__, #x); exit(1); } ++checks; } while (0)
static BOOL until(BOOL (^predicate)(void)) {
    for (unsigned i = 0; i < 350; ++i) { if (predicate()) return YES; usleep(20000); }
    return NO;
}
PLANKMacAuthenticationResult PLANKMacVerifyAccountIsolated(
        NSString *name, NSMutableData *password, PLANKMacAccountIdentity *identity) {
    BOOL valid = [name isEqual:@"synthetic"] && password.length == 4 && !memcmp(password.bytes, "test", 4);
    [password resetBytesInRange:NSMakeRange(0, password.length)];
    *identity = valid ? (PLANKMacAccountIdentity){123, {1}} : (PLANKMacAccountIdentity){0};
    return valid ? PLANKMacAuthenticationVerified : PLANKMacAuthenticationDenied;
}
@interface PLANKFakeCapture : NSObject <PLANKMacPreviewCapture>
@property unsigned starts, stops;
@property unsigned bitrateChanges;
@property BOOL deferBitrate, failBitrate;
@property(copy) void (^pendingBitrate)(uint32_t);
@property BOOL deferStart, failStart, deferStop, revokedBeforeStop;
@property uint32_t bitrate;
@property PLANKMacNativeVideo *video;
@property PLANKMacNativeAudio *audio;
@property dispatch_queue_t queue;
@property(copy) void (^pendingStop)(void);
@end
@implementation PLANKFakeCapture
- (BOOL)available { return YES; }
- (void)startWithTopology:(NSDictionary *)topology bitrate:(uint32_t)bitrate video:(PLANKMacNativeVideo *)video
                   audio:(PLANKMacNativeAudio *)audio
                   queue:(dispatch_queue_t)queue started:(void (^)(uint32_t))started failed:(void (^)(void))failed {
    (void)topology; self.queue = queue;
    self.starts++; self.bitrate = bitrate; self.video = video;
    self.audio = audio;
    CHECK(audio != nil);
    if (self.failStart) failed();
    else if (!self.deferStart) started(2 * bitrate);
}
- (void)setBitrate:(uint32_t)bitrate completion:(void (^)(uint32_t))completion {
    self.bitrateChanges++;
    self.bitrate = bitrate;
    if (self.deferBitrate) self.pendingBitrate = completion;
    else completion(self.failBitrate ? 0 : 2 * bitrate);
}
- (void)stopWithCompletion:(void (^)(void))completion {
    self.revokedBeforeStop = [self.video sendSample:NULL processingLatency:0] == PLANK_TRANSPORT_ERROR_INVALID_STATE;
    self.revokedBeforeStop &= [self.audio sendOpusPacket:nil presentationTime:kCMTimeZero discontinuity:YES] == PLANK_TRANSPORT_ERROR_INVALID_STATE;
    self.stops++; self.video = nil;
    self.audio = nil;
    if (self.deferStop) self.pendingStop = completion;
    else completion();
}
@end

// Real local XPC registry/agent, synthetic graphical observation. This fixture
// never acknowledges resource retirement on its own: the test must first prove
// the real native stream owner finished its asynchronous drain.
@interface PLANKSessionAgent : NSObject
@property dispatch_queue_t queue;
@property xpc_connection_t listener;
@property PLANKMacAgentRegistry *registry;
@property PLANKMacAgentConnection *connection;
@property PLANKMacAgentLease *lease;
@property unsigned retired;
- (void)close;
@end
@implementation PLANKSessionAgent
- (instancetype)init {
    self = [super init]; if (!self) return nil;
    _queue = dispatch_queue_create("plank.test.session-agent", DISPATCH_QUEUE_SERIAL);
    NSString *requirement = PLANKMacOwnSigningRequirement();
    __weak typeof(self) weakSelf = self;
    _registry = [[PLANKMacAgentRegistry alloc] initWithQueue:_queue requirement:requirement
        scope:^PLANKMacAgentPhase(PLANKMacAgentPeer peer) { (void)peer; return PLANKMacAgentDesktop; }
        event:^(PLANKMacAgentLease *lease, PLANKMacAgentEvent event) {
            if (event == PLANKMacAgentAttached) weakSelf.lease = lease;
            if (event == PLANKMacAgentRetired) weakSelf.retired++;
        }];
    _listener = xpc_connection_create(NULL, _queue);
    xpc_connection_set_event_handler(_listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        PLANKMacAgentRegistry *registry = weakSelf.registry;
        if (registry) [registry accept:peer]; else xpc_connection_cancel(peer);
    });
    xpc_connection_activate(_listener);
    xpc_endpoint_t endpoint = xpc_endpoint_create(_listener);
    _connection = [[PLANKMacAgentConnection alloc] initWithPeer:xpc_connection_create_from_endpoint(endpoint)
        queue:_queue requirement:requirement serverUID:geteuid() phase:PLANKMacAgentDesktop
        valid:^BOOL { return YES; }
        event:^(PLANKMacAgentConnectionState state, uint64_t generation) { (void)state; (void)generation; }];
    CHECK(_registry && _connection);
    dispatch_sync(_queue, ^{ CHECK([self.connection start]); });
    return self;
}
- (void)close {
    dispatch_sync(_queue, ^{ [self.connection stop]; [self.registry stop]; });
    xpc_connection_cancel(_listener);
}
@end

static NSString *authenticate(PLANKMacAuthenticationSession *auth, NSData *peer) {
    NSDictionary *start = [auth startForPeer:peer username:@"synthetic"];
    NSString *token = [auth respondForPeer:peer conversation:start[@"conversation_id"]
        password:[NSMutableData dataWithBytes:"test" length:4]][@"session_token"];
    CHECK(token != nil);
    return token;
}

int main(int argc, const char **argv) {
    if (argc != 5) return 2; // cert, key, pin, shared request fixture
    alarm(90);
    struct rlimit core = {0, 0}; CHECK(!setrlimit(RLIMIT_CORE, &core));
    @autoreleasepool {
        __block PLANKMacGraphicalIdentity desktop = {true, 1, {123, {1}}, PLANKMacScopeDesktop};
        __block PLANKSessionAgent *agent = nil;
        NSObject *guard = [NSObject new];
        __block NSDictionary *topology = PLANKMacFixedCaptureDescription(@"98454815-80ab-4a88-b187-92f59353afca",
            @"cgdisplay:42", 3840, 2160, CGRectMake(-1920, 0, 1920, 1080), @"hevc-10-420-videotoolbox");
        NSDictionary *(^snapshot)(void) = ^{ @synchronized(guard) { return topology; } };
        PLANKMacAuthenticationSession *auth = [[PLANKMacAuthenticationSession alloc] initWithGraphicalSnapshot:^{
            @synchronized(guard) { return agent ? [agent.connection bindGraphicalScope:desktop] : desktop; }
        }];
        NSData *fixture = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[4]]];
        NSDictionary *request = fixture ? [NSJSONSerialization JSONObjectWithData:fixture options:0 error:NULL] : nil;
        CHECK(PLANKMacPreviewRequestMatchesTopology(request, topology));
        NSMutableDictionary *fullRequest = [request mutableCopy];
        fullRequest[@"encoding_mode"] = @"hevc-10-444-videotoolbox";
        NSDictionary *fullTopology = PLANKMacFixedCaptureDescription(topology[@"generation"], @"cgdisplay:42",
            3840, 2160, CGRectMake(-1920, 0, 1920, 1080), @"hevc-10-444-videotoolbox");
        CHECK(PLANKMacPreviewRequestMatchesTopology(fullRequest, fullTopology));
        CHECK(!PLANKMacPreviewRequestMatchesTopology(fullRequest, topology));
        CHECK(!PLANKMacPreviewRequestMatchesTopology(request, fullTopology));
        CHECK(!PLANKMacPreviewRequestMatchesTopology(nil, topology));
        CHECK(!PLANKMacPreviewRequestMatchesTopology(request, nil));
        for (NSString *field in request) {
            NSMutableDictionary *bad = [request mutableCopy]; [bad removeObjectForKey:field];
            CHECK(!PLANKMacPreviewRequestMatchesTopology(bad, topology));
            for (id value in @[[NSNull null], @[], @{}, @YES, @"invalid"]) {
                bad[field] = value;
                BOOL validBoolean = ([field isEqual:@"clipboard"] || [field isEqual:@"microphone"]) &&
                    value == (__bridge id)kCFBooleanTrue;
                CHECK(PLANKMacPreviewRequestMatchesTopology(bad, topology) == validBoolean);
            }
        }
        for (id value in @[@0, @1, @1.5, @"true"]) {
            NSMutableDictionary *bad = [request mutableCopy]; bad[@"clipboard"] = value;
            CHECK(!PLANKMacPreviewRequestMatchesTopology(bad, topology));
        }
        for (NSString *field in @[@"width", @"height", @"frame_rate", @"bitrate_kbps", @"max_udp_payload_size"]) {
            for (NSNumber *value in @[@(-1), @1.5, @(UINT64_MAX)]) {
                NSMutableDictionary *bad = [request mutableCopy]; bad[field] = value;
                CHECK(!PLANKMacPreviewRequestMatchesTopology(bad, topology));
            }
        }
        NSMutableDictionary *extra = [request mutableCopy]; extra[@"audio"] = @YES;
        CHECK(!PLANKMacPreviewRequestMatchesTopology(extra, topology));

        PlankTransportConfig cfg = {0}; cfg.struct_size = sizeof(cfg); cfg.abi_version = PLANK_TRANSPORT_ABI_VERSION;
        cfg.mode = PLANK_TRANSPORT_MODE_SERVER; cfg.bind_address = "127.0.0.1:47492";
        cfg.certificate_path = argv[1]; cfg.private_key_path = argv[2];
        cfg.idle_timeout_ms = 10000; cfg.keep_alive_interval_ms = 1000;
        NSData *peer = [NSData dataWithBytes:"test" length:4];
        NSData *wrongPeer = [NSData dataWithBytes:"nope" length:4];
        NSString *token = authenticate(auth, peer);
        PLANKFakeCapture *source = [PLANKFakeCapture new];
        PLANKFakeInput *input = [PLANKFakeInput new];
        CHECK(![[PLANKMacPreviewSession alloc] initWithSessions:auth token:token peer:wrongPeer request:request
            topology:snapshot config:&cfg capture:source input:input microphoneGeneration:0]);
        CHECK(![[PLANKMacPreviewSession alloc] initWithSessions:auth token:token peer:peer request:extra
            topology:snapshot config:&cfg capture:source input:input microphoneGeneration:0]);
        PLANKMacAccountIdentity identity = {0};
        CHECK([auth authorizeToken:token peer:peer identity:&identity]);
        for (unsigned scenario = 0; scenario < 24; ++scenario) {
            printf("macos_preview_scenario=%u\n", scenario); fflush(stdout);
            if (scenario >= 11 && scenario < 15) {
                @synchronized(guard) { agent = [PLANKSessionAgent new]; }
                CHECK(until(^BOOL { return [agent.connection bindGraphicalScope:desktop].active; }));
            }
            if (scenario) token = authenticate(auth, peer);
            source = [PLANKFakeCapture new];
            input = [PLANKFakeInput new];
            input.repeatEnabled = scenario == 20;
            source.failStart = scenario == 4;
            source.deferStart = scenario == 5;
            source.deferStop = scenario == 8 || scenario == 11;
            source.deferBitrate = scenario == 16 || scenario == 18;
            source.failBitrate = scenario == 17;
            PLANKMacPreviewSession *session = [[PLANKMacPreviewSession alloc] initWithSessions:auth token:token peer:peer
                request:request topology:snapshot config:&cfg capture:source input:input microphoneGeneration:0];
            CHECK(session && session.state == PLANKMacPreviewPrepared);
            CHECK(![auth authorizeToken:token peer:peer identity:&identity]);
            NSString *transportToken = session.transportToken;
            CHECK(transportToken.length == 44 && ![transportToken isEqual:token]);
            CHECK(!source.starts);
            [session start];
            PlankTransportConfig cc = cfg; cc.mode = PLANK_TRANSPORT_MODE_CLIENT;
            cc.remote_address = cfg.bind_address; cc.server_name = "localhost"; cc.certificate_sha256 = argv[3];
            cc.session_token = transportToken.UTF8String; cc.max_udp_payload_size = 1200;
            PlankTransportNativeEndpoint *client = NULL;
            CHECK(plank_transport_native_endpoint_create(&cc, &client) == PLANK_TRANSPORT_OK);
            CHECK(plank_transport_native_endpoint_start(client) == PLANK_TRANSPORT_OK);
            CHECK(plank_transport_native_endpoint_wait_ready(client, 5000) == PLANK_TRANSPORT_OK);
            if (scenario < 4 || scenario >= 6) {
                CHECK(until(^BOOL { return session.state == PLANKMacPreviewStreaming; }));
                CHECK(source.starts == 1 && source.bitrate == 50000);
                CHECK(plank_transport_native_input_send(client, 5, (uint8_t[]){0x80, 0x41, 1, 0, 0}, 5) == PLANK_TRANSPORT_OK);
                CHECK(plank_transport_native_input_send(client, 2, (uint8_t[]){1, 1}, 2) == PLANK_TRANSPORT_OK);
                CHECK(until(^BOOL { return input.delivered == 2; }));
                CHECK(input.releases == 0);
            }
            uint8_t control[20]; size_t length = 0;
            if (scenario == 20) {
                CHECK(until(^BOOL { return input.delivered >= 4; })); // timer repeats without new packets
                CHECK(plank_transport_native_input_send(client, 5, (uint8_t[]){0x80, 0x41, 0, 0, 0}, 5) == PLANK_TRANSPORT_OK);
                CHECK(until(^BOOL { return input.releases == 1; }));
                unsigned stoppedCount = input.delivered;
                usleep(150000);
                CHECK(input.delivered == stoppedCount);
                CHECK(plank_transport_native_input_send(client, 5, (uint8_t[]){0x80, 0x41, 1, 0, 0}, 5) == PLANK_TRANSPORT_OK);
                CHECK(until(^BOOL { return input.delivered >= stoppedCount + 3; }));
                CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_CLIENT_DISCONNECT,
                    NULL, 0, control, sizeof(control), &length));
                CHECK(plank_transport_native_data_send(client, control, length) == PLANK_TRANSPORT_OK);
            } else if (scenario == 21 || scenario == 22 || scenario == 23) {
                uint8_t motion[PLANK_TRANSPORT_INPUT_ABSOLUTE_MOUSE_SIZE];
                if (scenario == 23) {
                    // The last pixel is valid at every corner, with a held
                    // button; the Host must not disconnect a correctly clamped drag.
                    const uint16_t corners[][2] = {{0, 0}, {3839, 0}, {3839, 2159}, {0, 2159}};
                    for (unsigned corner = 0; corner < 4; ++corner) {
                        plank_transport_input_encode_absolute_mouse(motion, corners[corner][0], corners[corner][1], 3839, 2159);
                        CHECK(plank_transport_native_input_send(client, PLANK_TRANSPORT_INPUT_ABSOLUTE_MOUSE, motion, sizeof(motion)) == PLANK_TRANSPORT_OK);
                        CHECK(until(^BOOL { return input.delivered == 3 + corner; }));
                        CHECK(session.state == PLANKMacPreviewStreaming && session.stopReason == nil);
                    }
                    CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_CLIENT_DISCONNECT,
                        NULL, 0, control, sizeof(control), &length));
                    CHECK(plank_transport_native_data_send(client, control, length) == PLANK_TRANSPORT_OK);
                } else {
                    // Reproduce the original one-pixel overrun. Keep the strict
                    // wire guard, release held input, and retain the precise reason.
                    plank_transport_input_encode_absolute_mouse(motion,
                        scenario == 21 ? 3840 : 0, scenario == 22 ? 2160 : 0, 3839, 2159);
                    CHECK(plank_transport_native_input_send(client, PLANK_TRANSPORT_INPUT_ABSOLUTE_MOUSE, motion, sizeof(motion)) == PLANK_TRANSPORT_OK);
                }
            } else if (scenario >= 15) {
                uint32_t rate = scenario == 19 ? 50000 : 10000;
                unsigned requests = scenario == 15 ? 8 : 1;
                for (unsigned requestIndex = 0; requestIndex < requests; ++requestIndex) {
                    rate += requestIndex ? 500 : 0;
                    CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_SET_VIDEO_BITRATE,
                        &rate, 1, control, sizeof(control), &length));
                    CHECK(plank_transport_native_data_send(client, control, length) == PLANK_TRANSPORT_OK);
                }
                if (scenario == 15 || scenario == 19) {
                    CHECK(plank_transport_native_data_receive(client, control, sizeof(control), &length, 5000) == PLANK_TRANSPORT_OK);
                    PlankTransportControlPacket ack;
                    CHECK(!plank_transport_control_decode(control, length, &ack));
                    CHECK(ack.type == PLANK_TRANSPORT_CONTROL_VIDEO_BITRATE_APPLIED &&
                        plank_transport_control_read_u32(ack.payload + 4) == rate);
                    CHECK(source.bitrateChanges == (scenario == 15 ? 1u : 0u));
                } else if (scenario == 16 || scenario == 18) {
                    CHECK(until(^BOOL { return source.pendingBitrate != nil; }));
                    CHECK(plank_transport_native_data_receive(client, control, sizeof(control), &length, 50) == PLANK_TRANSPORT_TIMEOUT);
                }
                if (scenario != 17 && scenario != 18) {
                    CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_CLIENT_DISCONNECT,
                        NULL, 0, control, sizeof(control), &length));
                    CHECK(plank_transport_native_data_send(client, control, length) == PLANK_TRANSPORT_OK);
                }
            } else if (scenario == 0) {
                uint32_t bitrate = 76500;
                CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_SET_VIDEO_BITRATE, &bitrate, 1,
                    control, sizeof(control), &length));
                CHECK(plank_transport_native_data_send(client, control, length) == PLANK_TRANSPORT_OK);
                CHECK(plank_transport_native_data_receive(client, control, sizeof(control), &length, 5000) == PLANK_TRANSPORT_OK);
                PlankTransportControlPacket ack;
                CHECK(!plank_transport_control_decode(control, length, &ack));
                CHECK(ack.type == PLANK_TRANSPORT_CONTROL_VIDEO_BITRATE_APPLIED && ack.payload_size == 12);
                CHECK(plank_transport_control_read_u32(ack.payload) == bitrate &&
                    plank_transport_control_read_u32(ack.payload + 4) == bitrate &&
                    plank_transport_control_read_u32(ack.payload + 8) == 2 * bitrate);
                CHECK(source.bitrate == bitrate);
                CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_CLIENT_DISCONNECT, NULL, 0, control, sizeof(control), &length));
                CHECK(plank_transport_native_data_send(client, control, length) == PLANK_TRANSPORT_OK);
            } else if (scenario == 1) {
                @synchronized(guard) { desktop.generation++; }
            } else if (scenario == 2) {
                @synchronized(guard) { topology = nil; }
            } else if (scenario == 3) {
                CHECK(!plank_transport_control_encode(999, NULL, 0, control, sizeof(control), &length));
                CHECK(plank_transport_native_data_send(client, control, length) == PLANK_TRANSPORT_OK);
            } else if (scenario == 6) {
                [auth revokeToken:token]; // failed HTTPS launch delivery cancellation
            } else if (scenario == 7) {
                session = nil; // accidental owner abandonment must still drain safely
                CHECK(until(^BOOL { return source.stops == 1; }));
                CHECK(source.revokedBeforeStop);
                plank_transport_native_endpoint_destroy(client);
                continue;
            } else if (scenario == 8) {
                CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_CLIENT_DISCONNECT, NULL, 0,
                    control, sizeof(control), &length));
                CHECK(plank_transport_native_data_send(client, control, length) == PLANK_TRANSPORT_OK);
                CHECK(until(^BOOL { return source.pendingStop != nil; }));
                CHECK(session.state == PLANKMacPreviewStopping);
                CHECK(until(^BOOL { return plank_transport_native_endpoint_state(client) != PLANK_TRANSPORT_STATE_READY; }));
                dispatch_async(source.queue, ^{
                    void (^completion)(void) = source.pendingStop; source.pendingStop = nil; completion();
                });
            } else if (scenario == 9) {
                input.availableFlag = NO;
                CHECK(plank_transport_native_input_send(client, 1, (uint8_t[]){0, 1, 0, 1, 0, 10, 0, 10}, 8) == PLANK_TRANSPORT_OK);
            } else if (scenario == 10) {
                CHECK(plank_transport_native_input_send(client, 2, (uint8_t[]){1, 2}, 2) == PLANK_TRANSPORT_OK);
            } else if (scenario == 11) {
                dispatch_sync(agent.queue, ^{ [agent.registry revoke]; });
                CHECK(until(^BOOL { return source.pendingStop != nil; }));
                CHECK(session.state == PLANKMacPreviewStopping && source.revokedBeforeStop);
                dispatch_sync(agent.queue, ^{ CHECK(agent.retired == 0); });
                CHECK(until(^BOOL { return plank_transport_native_endpoint_state(client) != PLANK_TRANSPORT_STATE_READY; }));
                dispatch_async(source.queue, ^{
                    void (^completion)(void) = source.pendingStop; source.pendingStop = nil; completion();
                });
            } else if (scenario == 12) {
                dispatch_sync(agent.queue, ^{ [agent.registry stop]; });
            } else if (scenario == 13) {
                // Neither the auth owner nor the native stream's teardown may
                // wait on the stopped IPC queue or renew a late service reply.
                dispatch_suspend(agent.queue);
                BOOL drained = until(^BOOL { return session.state == PLANKMacPreviewStopped; });
                dispatch_resume(agent.queue);
                CHECK(drained);
                CHECK(![agent.connection bindGraphicalScope:desktop].active);
            } else if (scenario == 14) {
                @synchronized(guard) { desktop.generation++; }
            }
            CHECK(until(^BOOL { return session.state == PLANKMacPreviewStopped; }));
            NSString *firstReason = session.stopReason;
            CHECK(firstReason.length > 0);
            if (scenario == 3) CHECK([firstReason isEqual:@"control-unsupported"]);
            if (scenario == 4) CHECK([firstReason isEqual:@"capture-failed"]);
            if (scenario == 5) CHECK([firstReason isEqual:@"capture-start-timeout"]);
            if (scenario == 10) CHECK([firstReason isEqual:@"input-malformed type=2"]);
            if (scenario == 17) CHECK([firstReason isEqual:@"bitrate-update-failed"]);
            if (scenario == 18) CHECK([firstReason isEqual:@"encoder-replacement-timeout"]);
            if (scenario == 21 || scenario == 22) CHECK([firstReason isEqual:@"input-malformed type=1"]);
            if (scenario == 0 || scenario == 8 || scenario == 15 || scenario == 16 || scenario == 19 || scenario == 20 || scenario == 23)
                CHECK([firstReason isEqual:@"client-disconnect"]);
            if (source.pendingBitrate) {
                dispatch_sync(source.queue, ^{
                    void (^late)(uint32_t) = source.pendingBitrate; source.pendingBitrate = nil;
                    late(20000); // A late completion cannot revive or acknowledge a stopped owner.
                });
                CHECK(session.state == PLANKMacPreviewStopped);
            }
            CHECK(source.stops == 1 && source.revokedBeforeStop && session.transportToken == nil);
            CHECK(input.releases == (scenario == 20 ? 3u : (scenario == 0 || scenario == 3 || scenario == 8 || scenario == 10 || scenario >= 15) ? 2u : 0u));
            if (scenario == 20) {
                unsigned stoppedCount = input.delivered;
                usleep(150000);
                CHECK(input.delivered == stoppedCount);
            }
            dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
            [session stopWithCompletion:^{ dispatch_semaphore_signal(stopped); }];
            CHECK(dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
            CHECK(source.stops == 1);
            CHECK([session.stopReason isEqual:firstReason]);
            plank_transport_native_endpoint_destroy(client);
            if (agent) {
                if (scenario == 11) {
                    dispatch_sync(agent.queue, ^{ [agent.connection retire]; });
                    CHECK(until(^BOOL {
                        __block BOOL done;
                        dispatch_sync(agent.queue, ^{ done = agent.retired == 1; });
                        return done;
                    }));
                }
                dispatch_sync(agent.queue, ^{
                    [agent.registry revoke];
                    CHECK([agent.registry completeRetirement:agent.lease]);
                });
                [agent close];
                @synchronized(guard) { agent = nil; }
            }
            @synchronized(guard) {
                topology = PLANKMacFixedCaptureDescription(@"98454815-80ab-4a88-b187-92f59353afca", @"cgdisplay:42",
                    3840, 2160, CGRectMake(-1920, 0, 1920, 1080), @"hevc-10-420-videotoolbox");
            }
        }
        [auth revokeAll];
        printf("macos_preview_session=pass checks=%u scenarios=24 synthetic_capture=1 real_quic=1 cleanup=1 agent_bound=1 edge_bounds=1 stop_reason=1\n", checks);
    }
}
