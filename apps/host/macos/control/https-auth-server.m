// SPDX-License-Identifier: GPL-3.0-or-later
#import "https-auth-server.h"
#import "http-request.h"
#import <Network/Network.h>
#include <arpa/inet.h>
#include <sys/resource.h>
#include <time.h>
#include <stdatomic.h>

@interface PLANKMacHTTPSRequest : NSObject {
@public
    atomic_bool cancelled;
}
@property nw_connection_t connection;
@property NSMutableData *bytes;
@property NSData *peer;
@property BOOL finished;
@property BOOL dispatched;
@property uint64_t deadline;
@end
@implementation PLANKMacHTTPSRequest
@end

@implementation PLANKMacHTTPSAuthServer {
    sec_identity_t _identity;
    PLANKMacAuthenticationSession *_sessions;
    PLANKMacServerInformation *_information;
    NSData *_serverInformationXML;
    NSDictionary *(^_topology)(void);
    PLANKMacLaunchHandler _launch;
    uint16_t _controlPort;
    nw_listener_t _listener;
    dispatch_queue_t _networkQueue;
    dispatch_queue_t _authQueue;
    NSMutableSet<PLANKMacHTTPSRequest *> *_requests;
    BOOL _stopped;
    BOOL _authBusy;
    dispatch_source_t _expiryTimer;
    dispatch_group_t _socketDrain;
}

- (instancetype)initWithIdentity:(SecIdentityRef)identity authority:(NSData *)authority
                       sessions:(PLANKMacAuthenticationSession *)sessions
                    information:(PLANKMacServerInformation *)information topology:(NSDictionary *(^)(void))topology
                         launch:(PLANKMacLaunchHandler)launch {
    if (!identity || !sessions || !information || !topology) return nil;
    struct rlimit core;
    if (getrlimit(RLIMIT_CORE, &core) || core.rlim_cur != 0) return nil;
    self = [super init];
    if (self) {
        SecCertificateRef root = authority ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)authority) : NULL;
        if (authority && !root) return nil;
        _identity = root ? sec_identity_create_with_certificates(identity, (__bridge CFArrayRef)@[(__bridge id)root]) :
            sec_identity_create(identity);
        if (root) CFRelease(root);
        if (!_identity) return nil;
        _sessions = sessions;
        _information = information;
        _topology = [topology copy];
        _launch = [launch copy];
        _requests = [NSMutableSet set];
        _networkQueue = dispatch_queue_create("la.instinctual.PLANK.Host.https", DISPATCH_QUEUE_SERIAL);
        _authQueue = dispatch_queue_create("la.instinctual.PLANK.Host.authentication", DISPATCH_QUEUE_SERIAL);
        _socketDrain = dispatch_group_create();
    }
    return self;
}

- (void)finish:(PLANKMacHTTPSRequest *)request {
    if (request.finished) return;
    request.finished = YES;
    atomic_store(&request->cancelled, true);
    [request.bytes resetBytesInRange:NSMakeRange(0, request.bytes.length)];
    request.bytes = nil;
    // Graceful server-first TCP close leaves a root-owned TIME_WAIT socket
    // which can deny the replacement desktop UID the port for 2*MSL. Abort
    // only cancelled/failed requests or connections whose peer has finished
    // receiving the complete Content-Length response (see replyBytes).
    // Keep the request until Network.framework confirms actual cancellation.
    nw_connection_force_cancel(request.connection);
}

- (void)replyBytes:(NSData *)bytes type:(NSString *)type token:(NSString *)token
           status:(unsigned)status request:(PLANKMacHTTPSRequest *)request {
    if (request.finished) {
        if (token) dispatch_async(_authQueue, ^{ [self->_sessions revokeToken:token]; });
        return;
    }
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %u %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nPragma: no-cache\r\nConnection: close\r\n\r\n",
        status, status == 200 ? @"OK" : @"Rejected", type, (unsigned long)bytes.length];
    NSMutableData *response = [[header dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [response appendData:bytes];
    dispatch_data_t content = dispatch_data_create(response.bytes, response.length, _networkQueue, ^{
        [response resetBytesInRange:NSMakeRange(0, response.length)];
    });
    __weak typeof(self) weakSelf = self;
    nw_connection_send(request.connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
        ^(nw_error_t error) {
            typeof(self) owner = weakSelf;
            if (error && owner && token)
                dispatch_async(owner->_authQueue, ^{ [owner->_sessions revokeToken:token]; });
            if (!owner || request.finished) return;
            if (error) { [owner finish:request]; return; }
            // Send completion means queued, NOT acknowledged. Do not reset
            // here: that can truncate a valid authentication reply on a WAN.
            // With Content-Length and Connection: close the HTTP client knows
            // when its response is complete and closes its side. Await that
            // EOF; the existing request deadline bounds an uncooperative peer.
            // No second/pipelined request is admitted on this connection.
            nw_connection_receive(request.connection, 1, 1,
                ^(dispatch_data_t data, nw_content_context_t context, bool complete, nw_error_t receiveError) {
                    (void)data; (void)context; (void)complete; (void)receiveError;
                    [weakSelf finish:request];
                });
        });
}

- (void)reply:(NSDictionary *)object status:(unsigned)status request:(PLANKMacHTTPSRequest *)request {
    [self replyBytes:[NSJSONSerialization dataWithJSONObject:object options:0 error:NULL]
               type:@"application/json" token:object[@"session_token"] status:status request:request];
}

- (void)handlePath:(NSString *)path body:(NSMutableData *)body authorization:(NSString *)authorization
          request:(PLANKMacHTTPSRequest *)request {
    // Body and Foundation's transient JSON values never enter a log. Mutable
    // buffers are wiped; framework-managed NSString copies cannot be promised
    // erased. Bound them to this per-request autorelease pool.
    @autoreleasepool {
        NSString *potentialClaim = nil;
        @try {
            if (request.finished) return;
            id value = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
            NSDictionary *reply = @{@"state": @"denied"};
            NSString *claimedToken = nil;
            unsigned status = 400;
            if ([value isKindOfClass:NSDictionary.class]) {
                if ([path isEqual:@"/plank/auth/start"] && [value count] == 1 &&
                    [value[@"username"] isKindOfClass:NSString.class]) {
                    reply = [_sessions startForPeer:request.peer username:value[@"username"]];
                    status = 200;
                } else if ([path isEqual:@"/plank/auth/respond"] && [value count] == 2 &&
                    [value[@"conversation_id"] isKindOfClass:NSString.class] &&
                    [value[@"responses"] isKindOfClass:NSArray.class] && [value[@"responses"] count] == 1 &&
                    [value[@"responses"][0] isKindOfClass:NSString.class]) {
                    NSMutableData *password = [[value[@"responses"][0] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
                    reply = [_sessions respondForPeer:request.peer conversation:value[@"conversation_id"] password:password];
                    status = 200;
                } else if (([path isEqual:@"/plank/launch"] && _launch) ||
                           ([path isEqual:@"/plank/display"] && self.prepareDisplay)) {
                    NSString *token = [authorization hasPrefix:@"Bearer "] && authorization.length == 51 ?
                        [authorization substringFromIndex:7] : nil;
                    PLANKMacAccountIdentity identity = {0};
                    status = 401;
                    if (token && [_sessions authorizeToken:token peer:request.peer identity:&identity]) {
                        potentialClaim = token;
                        status = 503;
                        if ([path isEqual:@"/plank/display"]) {
                            reply = self.prepareDisplay(value, token, request.peer, ^BOOL {
                                return !atomic_load(&request->cancelled) &&
                                    clock_gettime_nsec_np(CLOCK_MONOTONIC) < request.deadline;
                            }, &status) ?: @{@"state": @"denied"};
                            if (![_sessions authorizeToken:token peer:request.peer identity:&identity]) {
                                status = 401; reply = @{@"state": @"denied"};
                            }
                        } else {
                            reply = _launch(value, token, request.peer, _controlPort, &status) ?: @{@"state": @"denied"};
                            if (status == 200) claimedToken = token;
                        }
                        // An authorized display which is not ready yet may be
                        // polled with the same setup context. Do not extend its
                        // expiry. Launch remains one-shot and all other failures
                        // revoke only after peer-bound authorization succeeded.
                        BOOL readinessPending = [path isEqual:@"/plank/display"] &&
                            (status == 503 || (status == 409 && [reply[@"error"] isEqual:@"session_active"]));
                        BOOL expiredRequest = atomic_load(&request->cancelled) ||
                            clock_gettime_nsec_np(CLOCK_MONOTONIC) >= request.deadline;
                        if ((status != 200 && !readinessPending) || expiredRequest) [_sessions revokeToken:token];
                        if ([path isEqual:@"/plank/display"] && (status == 200 || readinessPending))
                            claimedToken = token; // revoke if delivery fails/cancels
                    }
                }
            }
            dispatch_async(_networkQueue, ^{
                if (claimedToken) {
                    [self replyBytes:[NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL]
                        type:@"application/json" token:claimedToken status:status request:request];
                } else [self reply:reply status:status request:request];
            });
        } @catch (NSException *exception) {
            (void)exception;
            if (potentialClaim) [_sessions revokeToken:potentialClaim];
            dispatch_async(_networkQueue, ^{ [self reply:@{@"state": @"denied"} status:400 request:request]; });
        } @finally {
            [body resetBytesInRange:NSMakeRange(0, body.length)];
            dispatch_async(_networkQueue, ^{ self->_authBusy = NO; });
        }
    }
}

- (void)receive:(PLANKMacHTTPSRequest *)request {
    if (request.finished || request.dispatched) return;
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(request.connection, 1, 4096,
        ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
            (void)context;
            typeof(self) owner = weakSelf;
            if (!owner || request.finished) return;
            if (error) { [owner finish:request]; return; }
            if (content) dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
                (void)region; (void)offset;
                [request.bytes appendBytes:bytes length:size];
                return true;
            });
            NSString *path, *method, *authorization;
            NSRange range;
            PLANKMacHTTPParseResult result = PLANKMacParseControlRequest(request.bytes, &method, &path, &range, &authorization);
            if (result == PLANKMacHTTPInvalid) {
                [owner reply:@{@"state": @"denied"} status:400 request:request];
            } else if (result == PLANKMacHTTPComplete) {
                request.dispatched = YES;
                if ([method isEqual:@"GET"]) {
                    BOOL information = PLANKMacIsServerInformationTarget(path) && owner->_serverInformationXML;
                    if (information && !authorization.length) {
                        [owner replyBytes:owner->_serverInformationXML type:@"application/xml; charset=utf-8"
                                    token:nil status:200 request:request];
                    } else if (information || PLANKMacIsTopologyTarget(path) || PLANKMacIsDesktopTarget(path)) {
                        if (owner->_authBusy) { [owner reply:@{@"state": @"denied"} status:503 request:request]; return; }
                        [request.bytes resetBytesInRange:NSMakeRange(0, request.bytes.length)];
                        request.bytes = nil;
                        owner->_authBusy = YES;
                        dispatch_async(owner->_authQueue, ^{
                            @autoreleasepool {
                                NSDictionary *topology = nil;
                                NSString *setupToken = nil;
                                BOOL authorized = NO;
                                unsigned status = 401;
                                @try {
                                    NSString *token = [authorization hasPrefix:@"Bearer "] && authorization.length == 51 ?
                                        [authorization substringFromIndex:7] : nil;
                                    PLANKMacAccountIdentity before = {0}, after = {0};
                                    if (token && [owner->_sessions authorizeToken:token peer:request.peer identity:&before]) {
                                        authorized = YES;
                                        if (PLANKMacIsTopologyTarget(path)) setupToken = token;
                                        if (!information) topology = owner->_topology();
                                        if (!topology && PLANKMacIsTopologyTarget(path) && owner.recoverTopology) {
                                            // At most one attempt per request, on the existing auth lane.
                                            // Discovery, app-list reads and invalid tokens never wake or
                                            // mutate a display. Cancellation is shared with the network lane.
                                            BOOL (^valid)(void) = ^BOOL {
                                                PLANKMacAccountIdentity current = {0};
                                                return !atomic_load(&request->cancelled) &&
                                                    clock_gettime_nsec_np(CLOCK_MONOTONIC) < request.deadline &&
                                                    [owner->_sessions authorizeToken:token peer:request.peer identity:&current] &&
                                                    before.uid == current.uid && !memcmp(before.uuid, current.uuid, sizeof(before.uuid));
                                            };
                                            if (valid() && owner.recoverTopology(valid)) {
                                                // Display-active arrives before capture geometry settles.
                                                // Poll readiness on this bounded worker, not the main or
                                                // network loop, and never repeat credential verification.
                                                uint64_t settle = clock_gettime_nsec_np(CLOCK_MONOTONIC) + NSEC_PER_SEC;
                                                while (valid()) {
                                                    topology = owner->_topology();
                                                    if (topology || clock_gettime_nsec_np(CLOCK_MONOTONIC) >= settle) break;
                                                    [NSThread sleepForTimeInterval:.05];
                                                }
                                            }
                                        }
                                        status = information || topology ? 200 : 503;
                                        if (![owner->_sessions authorizeToken:token peer:request.peer identity:&after] ||
                                            before.uid != after.uid || memcmp(before.uuid, after.uuid, sizeof(before.uuid))) {
                                            authorized = NO; topology = nil; status = 401;
                                        }
                                    }
                                } @catch (NSException *exception) {
                                    (void)exception; authorized = NO; topology = nil; status = 503;
                                } @finally {
                                    // Retry readiness without repeating OS auth.
                                    // Identity/peer checks and the original expiry
                                    // remain authoritative; cancellation and actual
                                    // rejection still finish this setup context.
                                    if (setupToken && ((status != 200 && !(status == 503 && authorized)) ||
                                                      atomic_load(&request->cancelled) ||
                                                      clock_gettime_nsec_np(CLOCK_MONOTONIC) >= request.deadline))
                                        [owner->_sessions revokeToken:setupToken];
                                }
                                dispatch_async(owner->_networkQueue, ^{
                                    if (information) {
                                        NSData *xml = [owner->_information XMLForControlPort:owner->_controlPort authorized:authorized];
                                        [owner replyBytes:xml type:@"application/xml; charset=utf-8" token:nil
                                                  status:200 request:request];
                                    } else if (status == 200 && PLANKMacIsDesktopTarget(path)) {
                                        // One immutable desktop identity, not an application catalog.
                                        NSData *desktop = [@"<root status_code=\"200\"><App><AppTitle>Desktop</AppTitle><ID>881448767</ID></App></root>"
                                            dataUsingEncoding:NSUTF8StringEncoding];
                                        [owner replyBytes:desktop type:@"application/xml; charset=utf-8" token:nil
                                                  status:200 request:request];
                                    } else [owner replyBytes:[NSJSONSerialization dataWithJSONObject:
                                                topology ?: @{@"state": @"denied"} options:0 error:NULL]
                                                type:@"application/json" token:setupToken status:status request:request];
                                    owner->_authBusy = NO;
                                });
                            }
                        });
                    } else [owner reply:@{@"state": @"denied"} status:404 request:request];
                    return;
                }
                if (owner->_authBusy) {
                    [owner reply:@{@"state": @"denied"} status:503 request:request];
                    return;
                }
                if (![path isEqual:@"/plank/auth/start"] && ![path isEqual:@"/plank/auth/respond"] &&
                    !([path isEqual:@"/plank/launch"] && owner->_launch) &&
                    !([path isEqual:@"/plank/display"] && owner.prepareDisplay)) {
                    [owner reply:@{@"state": @"denied"} status:404 request:request];
                    return;
                }
                NSMutableData *body = [NSMutableData dataWithBytes:(const char *)request.bytes.bytes + range.location length:range.length];
                [request.bytes resetBytesInRange:NSMakeRange(0, request.bytes.length)];
                request.bytes = nil;
                owner->_authBusy = YES;
                // Header/body admission retains its five-second deadline.
                // Only a complete display operation gets time for the bounded
                // graphical mode transaction; slow senders gain no extra time.
                if ([path isEqual:@"/plank/display"])
                    request.deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 10 * NSEC_PER_SEC;
                dispatch_async(owner->_authQueue, ^{ [owner handlePath:path body:body authorization:authorization request:request]; });
            } else if (complete) {
                [owner finish:request];
            } else [owner receive:request];
        });
}

- (void)accept:(nw_connection_t)connection {
    if (_stopped || _requests.count >= 8) { nw_connection_force_cancel(connection); return; }
    nw_endpoint_t endpoint = nw_connection_copy_endpoint(connection);
    const struct sockaddr *address = nw_endpoint_get_address(endpoint);
    NSData *peer = nil;
    if (address && address->sa_family == AF_INET) {
        peer = [NSData dataWithBytes:&((const struct sockaddr_in *)address)->sin_addr length:4];
    } else if (address && address->sa_family == AF_INET6) {
        const struct in6_addr *ip = &((const struct sockaddr_in6 *)address)->sin6_addr;
        peer = IN6_IS_ADDR_V4MAPPED(ip) ? [NSData dataWithBytes:ip->s6_addr + 12 length:4] :
            [NSData dataWithBytes:ip length:16];
    }
    if (!peer) { nw_connection_force_cancel(connection); return; }
    PLANKMacHTTPSRequest *request = [PLANKMacHTTPSRequest new];
    request.connection = connection;
    request.peer = peer;
    request.bytes = [NSMutableData data];
    request.deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 5 * NSEC_PER_SEC;
    [_requests addObject:request];
    dispatch_group_enter(_socketDrain);
    nw_connection_set_queue(connection, _networkQueue);
    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        (void)error;
        typeof(self) owner = weakSelf;
        if (!owner) return;
        if (state == nw_connection_state_cancelled) {
            // Also detach the handler's request reference to break its cycle.
            nw_connection_set_state_changed_handler(connection, NULL);
            if ([owner->_requests containsObject:request]) {
                [owner->_requests removeObject:request];
                dispatch_group_leave(owner->_socketDrain);
            }
        } else if (state == nw_connection_state_ready && !request.finished) [owner receive:request];
        else if (state == nw_connection_state_failed) [owner finish:request];
    });
    nw_connection_start(connection);
}

- (BOOL)startOnAddress:(NSString *)address port:(uint16_t)port ready:(void (^)(uint16_t))ready {
    return [self startOnAddress:address port:port ready:ready failed:nil];
}
- (BOOL)startOnAddress:(NSString *)address port:(uint16_t)port ready:(void (^)(uint16_t))ready
                failed:(void (^)(void))failed {
    struct in_addr ip;
    if (_listener || _stopped || !ready || inet_pton(AF_INET, address.UTF8String, &ip) != 1) return NO;
    sec_identity_t identity = _identity;
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        sec_protocol_options_t security = nw_tls_copy_sec_protocol_options(tls);
        sec_protocol_options_set_local_identity(security, identity);
        sec_protocol_options_set_min_tls_protocol_version(security, tls_protocol_version_TLSv13);
        sec_protocol_options_set_max_tls_protocol_version(security, tls_protocol_version_TLSv13);
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1");
    }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_local_endpoint(parameters, nw_endpoint_create_host(address.UTF8String,
        [NSString stringWithFormat:@"%u", port].UTF8String));
    _listener = nw_listener_create(parameters);
    if (!_listener) return NO;
    dispatch_group_enter(_socketDrain);
    nw_listener_set_queue(_listener, _networkQueue);
    __weak typeof(self) weakSelf = self;
    nw_listener_set_new_connection_handler(_listener, ^(nw_connection_t connection) { [weakSelf accept:connection]; });
    nw_listener_set_state_changed_handler(_listener, ^(nw_listener_state_t state, nw_error_t error) {
        typeof(self) owner = weakSelf;
        if (!owner) return;
        if (state == nw_listener_state_cancelled) {
            nw_listener_set_state_changed_handler(owner->_listener, NULL);
            dispatch_group_leave(owner->_socketDrain);
            return;
        }
        if (owner->_stopped) return;
        if (state == nw_listener_state_ready) {
            uint16_t boundPort = nw_listener_get_port(owner->_listener);
            owner->_controlPort = boundPort;
            owner->_serverInformationXML = [owner->_information XMLForControlPort:boundPort];
            if (!owner->_serverInformationXML) { [owner stop]; if (failed) failed(); return; }
            ready(boundPort);
        }
        else if (state == nw_listener_state_failed) {
            // Numeric OS diagnostics only; never log TLS identities, request
            // contents or framework error descriptions with peer metadata.
            NSLog(@"PLANK Host control listener failed: port=%u error-domain=%d error-code=%d",
                port, error ? (int)nw_error_get_error_domain(error) : 0,
                error ? nw_error_get_error_code(error) : 0);
            [owner stop]; if (failed) failed();
        }
    });
    // One watchdog for at most eight admitted requests. Do not retain a timer
    // closure for every completed/rejected connection during a request flood.
    _expiryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _networkQueue);
    dispatch_source_set_timer(_expiryTimer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_expiryTimer, ^{
        typeof(self) owner = weakSelf;
        if (!owner) return;
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        for (PLANKMacHTTPSRequest *request in owner->_requests.allObjects)
            if (request.deadline <= now) [owner finish:request];
    });
    dispatch_resume(_expiryTimer);
    nw_listener_start(_listener);
    return YES;
}

- (void)stop {
    [self stopWithCompletion:nil];
}
- (void)stopWithCompletion:(void (^)(void))completion {
    dispatch_async(_networkQueue, ^{
        self->_stopped = YES;
        if (self->_listener) nw_listener_cancel(self->_listener);
        if (self->_expiryTimer) dispatch_source_cancel(self->_expiryTimer);
        for (PLANKMacHTTPSRequest *request in self->_requests.allObjects) [self finish:request];
        // Serialized after any in-flight verification: no token survives stop.
        dispatch_async(self->_authQueue, ^{
            [self->_sessions revokeAll];
            // Auth work may already have queued a reply back to the network
            // lane. Drain that lane too before allowing the owner to retire.
            // A queue hop is not proof that asynchronous socket cancellation
            // has completed. Retire only after both listener and accepted
            // connections report cancelled, including incomplete TLS peers.
            dispatch_group_notify(self->_socketDrain, self->_networkQueue, ^{
                if (completion) completion();
            });
        });
    });
}

- (void)dealloc {
    if (_expiryTimer) dispatch_source_cancel(_expiryTimer);
    if (_listener) nw_listener_cancel(_listener);
    for (PLANKMacHTTPSRequest *request in _requests) {
        [request.bytes resetBytesInRange:NSMakeRange(0, request.bytes.length)];
        nw_connection_set_state_changed_handler(request.connection, NULL);
        nw_connection_force_cancel(request.connection);
    }
}
@end
