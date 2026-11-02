// SPDX-License-Identifier: GPL-3.0-or-later
#import "host-runtime.h"
#import "fixed-capture.h"
#import "media-features.h"
#include "host-network-policy.h"
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
    BOOL _started, _displayPrepared, _displayRestorationFailed;
    dispatch_group_t _displayOperation;
    uint64_t _displayGeneration;
    atomic_bool _stopping;
    NSString *_takeoverToken;
    NSData *_takeoverPeer;
    uint64_t _takeoverDeadline;
    uint32_t _idleTimeoutMs;
}
- (instancetype)init { return nil; }
- (instancetype)initWithIdentity:(SecIdentityRef)identity
                       authority:(NSData *)authority
                     information:(PLANKMacServerInformation *)information
                        snapshot:(PLANKMacGraphicalSnapshot)snapshot
                        topology:(NSDictionary *(^)(void))topology address:(NSString *)address
         idleTimeoutMilliseconds:(uint32_t)idleTimeoutMilliseconds
                     certificate:(NSString *)certificate privateKey:(NSString *)privateKey
                         capture:(id<PLANKMacPreviewCapture> (^)(void))capture
                           input:(id<PLANKMacInputDevice> (^)(void))input {
    struct in_addr ip;
    if (!identity || !information || !snapshot || !topology || !capture || !input ||
        !address || inet_pton(AF_INET, address.UTF8String, &ip) != 1 ||
        !certificate.isAbsolutePath || !privateKey.isAbsolutePath ||
        !plank_macos_valid_ping_timeout(idleTimeoutMilliseconds)) return nil;
    self = [super init];
    if (!self) return nil;
    _snapshot = [snapshot copy]; _topology = [topology copy];
    _idleTimeoutMs = idleTimeoutMilliseconds;
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
    _server.negotiateMedia = ^NSDictionary *(NSDictionary *request, unsigned *status) {
        typeof(self) owner = weakSelf;
        if (!owner) { *status = 503; return nil; }
        @synchronized(owner) {
            if (atomic_load(&owner->_stopping) || !owner->_started) { *status = 503; return nil; }
        }
        return PLANKMacNegotiateMedia(request, status);
    };
    _server.prepareDisplay = ^NSDictionary *(NSDictionary *request, NSString *token, NSData *peer,
                                             BOOL (^requestValid)(void), unsigned *status) {
        typeof(self) owner = weakSelf;
        if (!owner) { *status = 503; return nil; }
        return [owner prepareDisplayRequest:request token:token peer:peer valid:requestValid status:status];
    };
    _server.recoverTopology = ^BOOL(BOOL (^authorized)(void)) {
        typeof(self) owner = weakSelf;
        if (!owner) return NO;
        return [owner recoverTopologyAuthorized:authorized];
    };
    return _server ? self : nil;
}
// Runtime state is guarded briefly. Display/WindowServer work and stream drain
// happen only after reserving this slot, never while holding the runtime lock.
- (dispatch_group_t)reserveDisplayOperation {
    @synchronized(self) {
        if (_displayOperation || !_started || atomic_load(&_stopping)) return nil;
        _displayOperation = dispatch_group_create();
        dispatch_group_enter(_displayOperation);
        return _displayOperation;
    }
}
- (void)finishDisplayOperation:(dispatch_group_t)operation {
    @synchronized(self) {
        NSAssert(_displayOperation == operation, @"display operation ownership changed");
        _displayOperation = nil;
    }
    dispatch_group_leave(operation);
}
// Caller owns a display reservation. Restoration cannot overlap preparation.
- (BOOL)restoreReservedDisplay {
    BOOL prepared;
    @synchronized(self) { ++_displayGeneration; prepared = _displayPrepared; }
    BOOL restored = !prepared || !self.releaseDisplay || self.releaseDisplay();
    @synchronized(self) {
        _displayRestorationFailed = !restored;
        if (restored) _displayPrepared = NO;
    }
    return restored;
}
- (void)releaseDisplayGeneration:(uint64_t)generation completion:(void (^)(void))completion {
    dispatch_group_t pending, operation = nil;
    @synchronized(self) {
        pending = _displayOperation;
        if (!pending) {
            if ((generation != UINT64_MAX && generation != _displayGeneration) ||
                    (_stream && _stream.state != PLANKMacPreviewStopped)) {
                if (completion) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), completion);
                return;
            }
            // Shutdown may reserve restoration after closing admission.
            operation = _displayOperation = dispatch_group_create();
            dispatch_group_enter(operation);
        }
    }
    if (pending) {
        dispatch_group_notify(pending, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self releaseDisplayGeneration:generation completion:completion];
        });
        return;
    }
    @try { [self restoreReservedDisplay]; }
    @finally { [self finishDisplayOperation:operation]; }
    if (completion) completion();
}
- (BOOL)recoverTopologyAuthorized:(BOOL (^)(void))authorized {
    if (!self.recoverDisplay) return NO;
    dispatch_group_t operation = [self reserveDisplayOperation];
    if (!operation) return NO;
    @try {
        @synchronized(self) {
            if (_stream && _stream.state != PLANKMacPreviewStopped) return NO;
        }
        PLANKMacGraphicalIdentity scope = _snapshot();
        BOOL (^valid)(void) = ^BOOL {
            return !atomic_load(&self->_stopping) && authorized() &&
                plank_macos_same_graphical_scope(scope, self->_snapshot());
        };
        unsigned status = 0;
        if (!valid() || [self permissionError:&status] || ![self restoreReservedDisplay]) return NO;
        return self.recoverDisplay(valid) && valid();
    } @finally { [self finishDisplayOperation:operation]; }
}
- (NSDictionary *)prepareDisplayRequest:(NSDictionary *)request token:(NSString *)token
                                  peer:(NSData *)peer valid:(BOOL (^)(void))requestValid status:(unsigned *)status {
    if (!self.prepareDisplay) { *status = 503; return nil; }
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
    dispatch_group_t operation = [self reserveDisplayOperation];
    if (!operation) { *status = 503; return nil; }
    @try {
        PLANKMacPreviewSession *stream;
        BOOL needsTakeover;
        @synchronized(self) {
            stream = _stream;
            if (takeover && ![takeover isEqual:stream.sessionID]) {
                *status = 409; return @{@"state": @"denied", @"error": @"session_changed"};
            }
            if ([self takeoverReservedForAnotherToken:token peer:peer] ||
                    (stream && stream.state != PLANKMacPreviewStopped && ![takeover isEqual:stream.sessionID])) {
                *status = 409;
                NSMutableDictionary *conflict = [@{@"state": @"conflict", @"error": @"session_active"} mutableCopy];
                if (stream.sessionID) conflict[@"session_id"] = stream.sessionID;
                return conflict;
            }
            needsTakeover = stream && stream.state != PLANKMacPreviewStopped && !_takeoverToken;
        }
        if (needsTakeover) {
            if (!valid() || ![stream reserveTakeoverWithToken:token peer:peer]) { *status = 403; return nil; }
            @synchronized(self) {
                _takeoverToken = [token copy]; _takeoverPeer = [peer copy];
                _takeoverDeadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 15*NSEC_PER_SEC;
            }
            // The request lane may wait for bounded teardown. The runtime lock
            // stays available to shutdown, launch rejection and drain callbacks.
            __block BOOL accepted = NO;
            dispatch_semaphore_t drained = dispatch_semaphore_create(0);
            [stream takeOverWithToken:token peer:peer valid:valid completion:^(BOOL ok) {
                accepted = ok; dispatch_semaphore_signal(drained);
            }];
            if (dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) != 0) {
                *status = 503; return nil;
            }
            if (!accepted || !valid()) {
                @synchronized(self) { _takeoverToken = nil; _takeoverPeer = nil; }
                *status = 403; return nil;
            }
            NSLog(@"PLANK authenticated session transfer drained; preparing replacement display");
        }
        if ((stream && stream.state != PLANKMacPreviewStopped) || !valid() || ![self restoreReservedDisplay]) {
            *status = 503; return nil;
        }
        @synchronized(self) { _displayPrepared = self.releaseDisplay != nil; }
        if (!self.prepareDisplay(width, height, scale, request[@"encoding_mode"], valid) || !valid()) {
            [self restoreReservedDisplay];
            NSLog(@"PLANK desktop preparation failed: %ux%u", width, height);
            *status = 503; return nil;
        }
        NSDictionary *topology = _topology();
        if (!topology || [topology[@"capture"][@"width"] unsignedIntValue] != width ||
            [topology[@"capture"][@"height"] unsignedIntValue] != height ||
            [topology[@"capture"][@"logical_bounds"][@"width"] doubleValue] != width / scale ||
            [topology[@"capture"][@"logical_bounds"][@"height"] doubleValue] != height / scale ||
            ![topology[@"capture"][@"encoding_profile"] isEqual:PLANKMacEncodingProfile(request[@"encoding_mode"])] || !valid()) {
            [self restoreReservedDisplay]; *status = 503; return nil;
        }
        uint64_t generation;
        BOOL prepared;
        @synchronized(self) { generation = _displayGeneration; prepared = _displayPrepared; }
        if (prepared) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60*NSEC_PER_SEC),
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [weakSelf releaseDisplayGeneration:generation completion:nil];
                });
        }
        *status = 200; return topology;
    } @finally { [self finishDisplayOperation:operation]; }
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
        if (atomic_load(&_stopping) || !_started || _displayOperation || _displayRestorationFailed ||
                !plank_macos_graphical_identity_valid(_snapshot())) {
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
        config.idle_timeout_ms = _idleTimeoutMs;
        config.keep_alive_interval_ms = plank_macos_keep_alive_interval(_idleTimeoutMs);
        _stream = [[PLANKMacPreviewSession alloc] initWithSessions:_sessions token:token peer:peer
            request:request topology:_topology config:&config capture:_capture() input:_input()
            microphoneGeneration:_snapshot().generation];
        if (!_stream) {
            const uint64_t generation = _displayGeneration;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [self releaseDisplayGeneration:generation completion:nil];
            });
            *status = 503; return nil;
        }
        if (_displayPrepared) {
            uint64_t generation = _displayGeneration;
            __weak typeof(self) weakSelf = self;
            _stream.didStop = ^{
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [weakSelf releaseDisplayGeneration:generation completion:nil];
                });
            };
        }
        NSArray *required = request[@"required_features"];
        if (([required containsObject:@"clipboard"] && !_stream.clipboardEnabled) ||
            ([required containsObject:@"microphone"] && !_stream.microphoneEnabled) ||
            ([required containsObject:@"camera"] && !_stream.cameraEnabled)) {
            [_stream stopWithCompletion:nil];
            *status = 426; return @{@"state": @"denied", @"error": @"protocol_incompatible"};
        }
        _takeoverToken = nil; _takeoverPeer = nil;
        // Snapshot after endpoint creation as well. Do not put a later display
        // generation into a manifest for a stream created against an older one.
        NSString *transportToken = _stream.transportToken;
        if (atomic_load(&_stopping) || !transportToken || ![selected isEqual:_topology()] ||
            !plank_macos_graphical_identity_valid(_snapshot())) {
            [_stream stopWithCompletion:nil]; *status = 503; return nil;
        }
        unsigned schema = [request[@"schema_version"] unsignedIntValue];
        NSDictionary *normalized = PLANKMacNormalizeMediaLaunch(request);
        NSMutableDictionary *reply = [@{@"schema_version": @(schema), @"state": @"connecting",
            @"transport_token": transportToken, @"udp_port": @(port),
            @"max_udp_payload_size": normalized[@"max_udp_payload_size"], @"capture": selected[@"capture"]} mutableCopy];
        reply[@"transport"] = @"plank-native/2";
        reply[@"required_features"] = request[@"required_features"];
        reply[@"features"] = PLANKMacMediaReplyFeatures(request, _stream.clipboardEnabled,
            _stream.microphoneEnabled, _stream.cameraEnabled);
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
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [self releaseDisplayGeneration:UINT64_MAX completion:^{
                    [self->_server stopWithCompletion:completion];
                }];
            });
        };
        if (stream) [stream stopWithCompletion:finish]; else finish();
    });
}
@end
