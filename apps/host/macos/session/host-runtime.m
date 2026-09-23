// SPDX-License-Identifier: GPL-3.0-or-later
#import "host-runtime.h"
#import "fixed-capture.h"
#include <arpa/inet.h>
#include <stdatomic.h>
#include <time.h>

@implementation PLANKMacHostRuntime {
    PLANKMacAuthenticationSession *_sessions;
    PLANKMacHTTPSAuthServer *_server;
    PLANKMacPreviewSession *_stream;
    PLANKMacGraphicalSnapshot _snapshot;
    NSDictionary *(^_topology)(void);
    id<PLANKMacPreviewCapture> (^_capture)(void);
    id<PLANKMacInputDevice> (^_input)(void);
    NSString *_address, *_certificate, *_privateKey;
    BOOL _started;
    atomic_bool _stopping;
    NSString *_takeoverToken;
    NSData *_takeoverPeer;
    uint64_t _takeoverDeadline;
}
- (instancetype)init { return nil; }
- (instancetype)initWithIdentity:(SecIdentityRef)identity
                       authority:(NSData *)authority
                     information:(PLANKMacServerInformation *)information
                        snapshot:(PLANKMacGraphicalSnapshot)snapshot
                        topology:(NSDictionary *(^)(void))topology address:(NSString *)address
                     certificate:(NSString *)certificate privateKey:(NSString *)privateKey
                         capture:(id<PLANKMacPreviewCapture> (^)(void))capture
                           input:(id<PLANKMacInputDevice> (^)(void))input {
    struct in_addr ip;
    if (!identity || !information || !snapshot || !topology || !capture || !input ||
        !address || inet_pton(AF_INET, address.UTF8String, &ip) != 1 ||
        !certificate.isAbsolutePath || !privateKey.isAbsolutePath) return nil;
    self = [super init];
    if (!self) return nil;
    _snapshot = [snapshot copy]; _topology = [topology copy];
    _capture = [capture copy]; _input = [input copy];
    _address = [address copy]; _certificate = [certificate copy]; _privateKey = [privateKey copy];
    _sessions = [[PLANKMacAuthenticationSession alloc] initWithGraphicalSnapshot:snapshot];
    __weak typeof(self) weakSelf = self;
    _server = [[PLANKMacHTTPSAuthServer alloc] initWithIdentity:identity authority:authority sessions:_sessions
        information:information topology:topology
        launch:^NSDictionary *(NSDictionary *request, NSString *token, NSData *peer, uint16_t port, unsigned *status) {
            typeof(self) owner = weakSelf;
            if (!owner) { *status = 503; return nil; }
            return [owner launch:request token:token peer:peer port:port status:status];
        }];
    _server.prepareDisplay = ^NSDictionary *(NSDictionary *request, NSString *token, NSData *peer,
                                             BOOL (^requestValid)(void), unsigned *status) {
        typeof(self) owner = weakSelf;
        if (!owner) { *status = 503; return nil; }
        return [owner prepareDisplayRequest:request token:token peer:peer valid:requestValid status:status];
    };
    _server.recoverTopology = ^BOOL(BOOL (^authorized)(void)) {
        typeof(self) owner = weakSelf;
        if (!owner) return NO;
        @synchronized(owner) {
            if (!owner.recoverDisplay || !owner->_started || atomic_load(&owner->_stopping) ||
                (owner->_stream && owner->_stream.state != PLANKMacPreviewStopped)) return NO;
            PLANKMacGraphicalIdentity scope = owner->_snapshot();
            BOOL (^valid)(void) = ^BOOL {
                return !atomic_load(&owner->_stopping) && authorized() &&
                    plank_macos_same_graphical_scope(scope, owner->_snapshot());
            };
            unsigned status = 0;
            if (!valid() || [owner permissionError:&status]) return NO;
            return owner.recoverDisplay(valid) && valid();
        }
    };
    return _server ? self : nil;
}
- (NSDictionary *)prepareDisplayRequest:(NSDictionary *)request token:(NSString *)token
                                  peer:(NSData *)peer valid:(BOOL (^)(void))requestValid status:(unsigned *)status {
    @synchronized(self) {
        if (!self.prepareDisplay || atomic_load(&_stopping) || !_started) {
            NSLog(@"PLANK desktop preparation unavailable: provider=%d stopping=%d started=%d",
                self.prepareDisplay != nil, atomic_load(&_stopping), _started);
            *status = 503; return nil;
        }
        id takeover = request[@"takeover_session_id"];
        if ((request.count != 5 && request.count != 6) ||
                (request.count == 6 && (![takeover isKindOfClass:NSString.class] ||
                 ![[[NSUUID alloc] initWithUUIDString:takeover].UUIDString.lowercaseString isEqual:takeover])) ||
                !PLANKMacEncodingProfile(request[@"encoding_mode"])) { *status = 400; return nil; }
        for (NSString *key in @[@"schema_version", @"width", @"height", @"scale"]) {
            id number = request[key];
            if (![number isKindOfClass:NSNumber.class] ||
                CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID() ||
                [number doubleValue] != [number unsignedIntValue]) { *status = 400; return nil; }
        }
        unsigned width = [request[@"width"] unsignedIntValue], height = [request[@"height"] unsignedIntValue];
        unsigned scale = [request[@"scale"] unsignedIntValue];
        if ([request[@"schema_version"] unsignedIntValue] != 3 || (scale != 1 && scale != 2) ||
            width < 2 || height < 2 || width > 8192 || height > 8192 || width % 2 || height % 2) { *status = 400; return nil; }
        PLANKMacGraphicalIdentity scope = _snapshot();
        BOOL (^valid)(void) = ^BOOL {
            PLANKMacAccountIdentity account = {0};
            return requestValid() && !atomic_load(&self->_stopping) &&
                plank_macos_same_graphical_scope(scope, self->_snapshot()) &&
                [self->_sessions authorizeToken:token peer:peer identity:&account];
        };
        if (!valid()) { *status = 401; return nil; }
        NSDictionary *permissionError = [self permissionError:status];
        if (permissionError) return permissionError;
        if (takeover && ![takeover isEqual:_stream.sessionID]) {
            *status = 409; return @{@"state": @"denied", @"error": @"session_changed"};
        }
        if ([self takeoverReservedForAnotherToken:token peer:peer] ||
                (_stream && _stream.state != PLANKMacPreviewStopped &&
                 ![takeover isEqual:_stream.sessionID])) {
            *status = 409;
            return @{@"state": @"conflict", @"error": @"session_active", @"session_id": _stream.sessionID};
        }
        if (_stream && _stream.state != PLANKMacPreviewStopped) {
            // The authentication lane is serial. Reserve the next launch while
            // normal asynchronous teardown releases input/capture/QUIC. Neither
            // the GUI nor network queue waits for this bounded drain.
            if (!_takeoverToken) {
                if (![_stream reserveTakeoverWithToken:token peer:peer]) { *status = 403; return nil; }
                _takeoverToken = [token copy]; _takeoverPeer = [peer copy];
                _takeoverDeadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 15*NSEC_PER_SEC;
                __block BOOL accepted = NO;
                dispatch_semaphore_t drained = dispatch_semaphore_create(0);
                [_stream takeOverWithToken:token peer:peer valid:valid completion:^(BOOL ok) {
                    accepted = ok; dispatch_semaphore_signal(drained);
                }];
                if (dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) != 0) {
                    *status = 503; return nil;
                }
                if (!accepted || !valid()) {
                    _takeoverToken = nil; _takeoverPeer = nil;
                    *status = 403; return nil;
                }
                NSLog(@"PLANK authenticated session transfer drained; preparing replacement display");
            }
            if (_stream.state != PLANKMacPreviewStopped) { *status = 503; return nil; }
        }
        if (!self.prepareDisplay(width, height, scale, request[@"encoding_mode"], valid) || !valid()) {
            NSLog(@"PLANK desktop preparation failed: %ux%u", width, height);
            *status = 503; return nil;
        }
        NSDictionary *topology = _topology();
        if (!topology || [topology[@"capture"][@"width"] unsignedIntValue] != width ||
            [topology[@"capture"][@"height"] unsignedIntValue] != height ||
            [topology[@"capture"][@"logical_bounds"][@"width"] doubleValue] != width / scale ||
            [topology[@"capture"][@"logical_bounds"][@"height"] doubleValue] != height / scale ||
            ![topology[@"capture"][@"encoding_profile"] isEqual:PLANKMacEncodingProfile(request[@"encoding_mode"])] || !valid()) {
            *status = 503; return nil;
        }
        *status = 200; return topology;
    }
}
- (BOOL)takeoverReservedForAnotherToken:(NSString *)token peer:(NSData *)peer {
    PLANKMacAccountIdentity account = {0};
    if (_takeoverToken && (clock_gettime_nsec_np(CLOCK_MONOTONIC) >= _takeoverDeadline ||
            ![_sessions authorizeToken:_takeoverToken peer:_takeoverPeer identity:&account])) {
        _takeoverToken = nil; _takeoverPeer = nil;
    }
    return _takeoverToken && (![_takeoverToken isEqual:token] || ![_takeoverPeer isEqual:peer]);
}
- (BOOL)startOnPort:(uint16_t)port ready:(void (^)(uint16_t))ready failed:(void (^)(void))failed {
    @synchronized(self) {
        if (_started || atomic_load(&_stopping) || !ready || !plank_macos_graphical_identity_valid(_snapshot())) return NO;
        _started = YES;
        return [_server startOnAddress:_address port:port ready:ready failed:failed];
    }
}
// Called only after HTTPS authentication, before changing display geometry or
// consuming a stream lease. Discovery/auth remain available for remediation.
- (NSDictionary *)permissionError:(unsigned *)status {
    BOOL screen = [_capture() available], input = [_input() available];
    if (screen && input) return nil;
    NSLog(@"PLANK stream admission denied: screen-capture=%d input=%d; approve PLANK Host in System Settings > Privacy & Security", screen, input);
    *status = 403;
    return @{@"state": @"denied", @"error": @"host_permissions_required"};
}
- (NSDictionary *)launch:(NSDictionary *)request token:(NSString *)token peer:(NSData *)peer
                    port:(uint16_t)port status:(unsigned *)status {
    // Serialize endpoint construction with shutdown's stream snapshot, NOT
    // account verification or capture/encoding. Shutdown never waits on the UI.
    @synchronized(self) {
        if (atomic_load(&_stopping) || !_started || !plank_macos_graphical_identity_valid(_snapshot())) {
            *status = 503; return nil;
        }
        NSDictionary *selected = _topology();
        if ([self takeoverReservedForAnotherToken:token peer:peer]) { *status = 409; return nil; }
        if (!PLANKMacPreviewRequestMatchesTopology(request, selected)) { *status = 400; return nil; }
        if (_stream && _stream.state != PLANKMacPreviewStopped) { *status = 409; return nil; }
        NSDictionary *permissionError = [self permissionError:status];
        if (permissionError) return permissionError;
        NSString *bind = [NSString stringWithFormat:@"%@:%u", _address, port];
        PlankTransportConfig config = {0};
        config.struct_size = sizeof(config); config.abi_version = PLANK_TRANSPORT_ABI_VERSION;
        config.mode = PLANK_TRANSPORT_MODE_SERVER;
        config.bind_address = bind.UTF8String;
        config.certificate_path = _certificate.UTF8String;
        config.private_key_path = _privateKey.UTF8String;
        config.idle_timeout_ms = 10000; config.keep_alive_interval_ms = 1000;
        _stream = [[PLANKMacPreviewSession alloc] initWithSessions:_sessions token:token peer:peer
            request:request topology:_topology config:&config capture:_capture() input:_input()
            microphoneGeneration:_snapshot().generation];
        if (!_stream) { *status = 503; return nil; }
        _takeoverToken = nil; _takeoverPeer = nil;
        // Snapshot after endpoint creation as well. Do not put a later display
        // generation into a manifest for a stream created against an older one.
        NSString *transportToken = _stream.transportToken;
        if (atomic_load(&_stopping) || !transportToken || ![selected isEqual:_topology()] ||
            !plank_macos_graphical_identity_valid(_snapshot())) {
            [_stream stopWithCompletion:nil]; *status = 503; return nil;
        }
        NSDictionary *reply = @{@"schema_version": @4, @"state": @"connecting",
            @"transport_token": transportToken, @"udp_port": @(port),
            @"max_udp_payload_size": request[@"max_udp_payload_size"], @"capture": selected[@"capture"],
            @"services": @{@"audio": @YES, @"input": @YES, @"pen": @"normalized", @"cursor": @"embedded",
                @"clipboard": @(_stream.clipboardEnabled), @"microphone": @(_stream.microphoneEnabled)}};
        [_stream start]; *status = 200; return reply;
    }
}
- (void)stopWithCompletion:(void (^)(void))completion {
    atomic_store(&_stopping, true);
    // Endpoint construction may still be finishing on the auth lane. Never
    // make the graphical event loop wait for its lock or filesystem I/O.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        PLANKMacPreviewSession *stream;
        @synchronized(self) { stream = self->_stream; }
        // Normal stop releases held input before the HTTP owner revokes tokens.
        // Scope loss independently blocks release into another account. During
        // this bounded drain HTTP can still answer, but launch is already closed.
        void (^finish)(void) = ^{
            [self->_server stopWithCompletion:completion];
        };
        if (stream) [stream stopWithCompletion:finish]; else finish();
    });
}
@end
