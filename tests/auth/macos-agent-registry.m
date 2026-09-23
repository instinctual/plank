// SPDX-License-Identifier: GPL-3.0-or-later
// Real anonymous XPC, synthetic controller scope except the explicit native gate.
// No media, input, credentials, persistent service or discoverable Mach endpoint.
#import "agent-registry.h"
#import "agent-connection.h"
#import <Security/AuthSession.h>
#include <unistd.h>

static unsigned checks;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #x); exit(1); } ++checks; } while (0)

static xpc_object_t message(uint64_t operation, uint64_t generation, uint64_t sequence) {
    xpc_object_t value = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(value, "version", 1);
    xpc_dictionary_set_uint64(value, "operation", operation);
    if (operation == 1) xpc_dictionary_set_uint64(value, "phase", PLANKMacAgentDesktop);
    else {
        xpc_dictionary_set_uint64(value, "generation", generation);
        xpc_dictionary_set_uint64(value, "sequence", sequence);
    }
    return value;
}
static xpc_object_t request(xpc_connection_t peer, xpc_object_t value) {
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block xpc_object_t response = nil;
    xpc_connection_send_message_with_reply(peer, value, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(xpc_object_t reply) {
        response = reply; dispatch_semaphore_signal(ready);
    });
    if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) return nil;
    return response;
}
static BOOL status(xpc_object_t reply, uint64_t expected) {
    return reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
        xpc_dictionary_get_uint64(reply, "version") == 1 &&
        xpc_dictionary_get_uint64(reply, "status") == expected;
}

@interface Fixture : NSObject
@property dispatch_queue_t queue;
@property PLANKMacAgentRegistry *registry;
@property xpc_connection_t listener;
@property PLANKMacAgentLease *lease;
@property unsigned attached, revoked, retired, lost;
@property BOOL allowed;
@property BOOL stall;
@property NSMutableArray *held;
- (instancetype)initWithNative:(BOOL)native requirement:(NSString *)requirement;
- (xpc_connection_t)client;
- (xpc_connection_t)inactiveClient;
- (void)close;
@end
@implementation Fixture
- (instancetype)initWithNative:(BOOL)native requirement:(NSString *)requirement {
    self = [super init]; if (!self) return nil;
    self.queue = dispatch_queue_create("plank.agent.registry.test",
        dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL,
            DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    self.allowed = YES;
    self.held = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    self.registry = [[PLANKMacAgentRegistry alloc] initWithQueue:self.queue requirement:requirement
        scope:^PLANKMacAgentPhase(PLANKMacAgentPeer peer) {
            typeof(self) owner = weakSelf;
            if (!owner.allowed) return PLANKMacAgentUnavailable;
            return native ? PLANKMacObserveAgentScope(peer) : PLANKMacAgentDesktop;
        } event:^(PLANKMacAgentLease *lease, PLANKMacAgentEvent event) {
            typeof(self) owner = weakSelf;
            if (event == PLANKMacAgentAttached) { owner.lease = lease; owner.attached++; }
            if (event == PLANKMacAgentRevoked) owner.revoked++;
            if (event == PLANKMacAgentRetired) owner.retired++;
            if (event == PLANKMacAgentLost) owner.lost++;
        }];
    if (!self.registry) return nil;
    self.listener = xpc_connection_create(NULL, self.queue);
    xpc_connection_set_event_handler(self.listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        typeof(self) owner = weakSelf;
        if (!owner || !owner.registry) { xpc_connection_cancel(peer); return; }
        if (owner.stall) { // Test-only stalled service: deliberately never replies.
            [owner.held addObject:peer];
            xpc_connection_set_event_handler(peer, ^(xpc_object_t message) { (void)message; });
            xpc_connection_activate(peer);
        } else [owner.registry accept:peer];
    });
    xpc_connection_activate(self.listener);
    return self;
}
- (xpc_connection_t)inactiveClient {
    xpc_endpoint_t endpoint = xpc_endpoint_create(self.listener);
    return xpc_connection_create_from_endpoint(endpoint);
}
- (xpc_connection_t)client {
    xpc_connection_t peer = [self inactiveClient];
    CHECK(!xpc_connection_set_peer_code_signing_requirement(peer, PLANKMacOwnSigningRequirement().UTF8String));
    // XPC otherwise permits implicit reconnection after interruption. Like the
    // real agent, this test peer treats interruption as terminal for its lease.
    __block xpc_connection_t retained = peer;
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR && retained) {
            xpc_connection_cancel(retained); retained = nil;
        }
    });
    xpc_connection_activate(peer);
    return peer;
}
- (void)close {
    dispatch_sync(self.queue, ^{
        [self.registry stop];
        for (xpc_connection_t peer in self.held) xpc_connection_cancel(peer);
        [self.held removeAllObjects];
    });
    xpc_connection_cancel(self.listener);
}
@end

static BOOL until(Fixture *f, BOOL (^predicate)(void)) {
    for (unsigned i = 0; i < 150; ++i) {
        __block BOOL done;
        dispatch_sync(f.queue, ^{ done = predicate(); });
        if (done) return YES;
        usleep(20000);
    }
    return NO;
}

static void identityTests(NSString *requirement) {
    // Certificate issuance is independent of the exclusive graphical lease.
    // Use signed anonymous XPC and synthetic scope; never create machine keys.
    for (unsigned scenario = 0; scenario < 5; ++scenario) {
        Fixture *fixture = [[Fixture alloc] initWithNative:NO requirement:requirement];
        __weak Fixture *weakFixture = fixture;
        __block unsigned issuedCount = 0;
        dispatch_sync(fixture.queue, ^{
            fixture.registry.issueIdentity = ^NSDictionary<NSString *, NSData *> *(NSData *csr) {
                ++issuedCount;
                Fixture *current = weakFixture;
                if (scenario == 3 && current) dispatch_sync(current.queue, ^{ current.allowed = NO; });
                return @{@"certificate": csr, @"der": csr, @"authority": csr};
            };
        });
        // Match PLANKMacAuthorizeDesktopIdentity: this is a one-shot request,
        // not a graphical lease. An interruption may race the queued reply;
        // leave cancellation to the caller after consuming that reply.
        xpc_connection_t peer = [fixture inactiveClient];
        CHECK(!xpc_connection_set_peer_code_signing_requirement(peer, requirement.UTF8String));
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) { (void)event; });
        xpc_connection_activate(peer);
        xpc_object_t csrRequest = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(csrRequest, "version", 1);
        xpc_dictionary_set_uint64(csrRequest, "operation", 5);
        NSData *csr = [@"synthetic-public-csr" dataUsingEncoding:NSUTF8StringEncoding];
        xpc_dictionary_set_data(csrRequest, "csr", csr.bytes, csr.length);
        if (scenario == 1) xpc_dictionary_set_uint64(csrRequest, "uid", getuid());
        if (scenario == 2) xpc_dictionary_set_string(csrRequest, "csr", "wrong-type");
        if (scenario == 4) dispatch_sync(fixture.queue, ^{ fixture.allowed = NO; });
        xpc_object_t reply = request(peer, csrRequest);
        if (status(reply, 0) != (scenario == 0 && getuid() != 0))
            fprintf(stderr, "identity scenario=%u reply=%s\n", scenario,
                !reply ? "timeout" : xpc_get_type(reply) == XPC_TYPE_ERROR ? "xpc-error" : "dictionary");
        CHECK(status(reply, 0) == (scenario == 0 && getuid() != 0));
        if (status(reply, 0)) {
            CHECK(xpc_dictionary_get_count(reply) == 5);
            CHECK(!xpc_dictionary_get_value(reply, "generation"));
            CHECK(!xpc_dictionary_get_value(reply, "key"));
            CHECK(!status(request(peer, message(1, 0, 0)), 0));
        }
        CHECK(until(fixture, ^BOOL { return fixture.attached == 0; }));
        dispatch_sync(fixture.queue, ^{
            CHECK(issuedCount == ((scenario == 0 || scenario == 3) && getuid() != 0 ? 1u : 0u));
            fixture.registry.issueIdentity = nil;
        });
        [fixture close]; xpc_connection_cancel(peer);
    }
}

static void connectionTests(NSString *requirement) {
    identityTests(requirement);
    @autoreleasepool {
        Fixture *f = [[Fixture alloc] initWithNative:NO requirement:requirement];
        for (unsigned invalid = 0; invalid < 3; ++invalid) {
            PLANKMacAgentConnection *bad = [[PLANKMacAgentConnection alloc] initWithPeer:[f inactiveClient]
                queue:f.queue requirement:invalid == 1 ? @"" : requirement
                serverUID:invalid == 2 ? (uid_t)-1 : geteuid()
                phase:invalid == 0 ? PLANKMacAgentUnavailable : PLANKMacAgentDesktop
                valid:^BOOL { return YES; } event:^(PLANKMacAgentConnectionState state, uint64_t generation) {
                    (void)state; (void)generation;
                }];
            CHECK(bad == nil);
        }
        PLANKMacAgentConnection *unstarted = [[PLANKMacAgentConnection alloc] initWithPeer:[f inactiveClient]
            queue:f.queue requirement:requirement serverUID:geteuid() phase:PLANKMacAgentDesktop
            valid:^BOOL { return YES; } event:^(PLANKMacAgentConnectionState state, uint64_t generation) {
                (void)state; (void)generation;
            }];
        CHECK(unstarted != nil); unstarted = nil;
        [f close];
    } // Includes actual XPC release, not just assertions before a deferred trap.
    for (unsigned scenario = 0; scenario < 11; ++scenario) {
        Fixture *f = [[Fixture alloc] initWithNative:NO requirement:requirement];
        f.stall = scenario == 6;
        __block BOOL localValid = scenario != 4;
        __block unsigned ready = 0, retired = 0;
        __block PLANKMacAgentConnectionState state = PLANKMacAgentConnecting;
        __block uint64_t generation = 0;
        PLANKMacAgentConnection *agent = [[PLANKMacAgentConnection alloc] initWithPeer:[f inactiveClient]
            queue:f.queue requirement:scenario == 5 ? @"identifier \"la.instinctual.PLANK.NotTheService\"" : requirement
            serverUID:scenario == 2 ? geteuid() + 1 : geteuid() phase:PLANKMacAgentDesktop
            valid:^BOOL { return localValid; }
            event:^(PLANKMacAgentConnectionState next, uint64_t token) {
                state = next; generation = token;
                ready += next == PLANKMacAgentReady; retired += next == PLANKMacAgentFinished;
            }];
        CHECK(agent != nil);
        __block BOOL started, active;
        dispatch_sync(f.queue, ^{ started = [agent start]; }); CHECK(started == (scenario != 4));
        PLANKMacGraphicalIdentity localScope = {true, 500, {123, {1}}, PLANKMacScopeDesktop};
        if ((scenario >= 4 && scenario <= 6) || scenario == 2) {
            CHECK(until(f, ^BOOL { return state == PLANKMacAgentDisconnected; })); CHECK(ready == 0);
            CHECK(![agent bindGraphicalScope:localScope].active);
        } else {
            CHECK(until(f, ^BOOL { return ready == 1 && f.attached == 1; })); CHECK(generation != 0);
            dispatch_sync(f.queue, ^{ active = [agent authorized]; }); CHECK(active);
            PLANKMacGraphicalIdentity bound = [agent bindGraphicalScope:localScope];
            CHECK(bound.active && bound.generation == generation && bound.account.uid == 123);
            // Exercise an ordinary asynchronous health check before retirement.
            usleep(800000);
            if (scenario >= 7) {
                if (scenario < 9) {
                    PLANKMacGraphicalIdentity changed = localScope;
                    if (scenario == 7) changed.generation++;
                    else { changed.phase = PLANKMacScopeSignIn; changed.account = (PLANKMacAccountIdentity){0}; }
                    CHECK(![agent bindGraphicalScope:changed].active);
                    CHECK(![agent bindGraphicalScope:localScope].active);
                } else {
                    // The auth/media caller must not block behind stalled IPC.
                    dispatch_suspend(f.queue);
                    usleep(2200000);
                    if (scenario == 9) CHECK(![agent bindGraphicalScope:localScope].active);
                    dispatch_resume(f.queue);
                }
                CHECK(until(f, ^BOOL { return state == PLANKMacAgentDisconnected; }));
                CHECK(![agent bindGraphicalScope:localScope].active);
            } else if (scenario == 3) {
                dispatch_sync(f.queue, ^{ [f.registry stop]; });
                CHECK(until(f, ^BOOL { return state == PLANKMacAgentDisconnected; }));
            } else {
                dispatch_sync(f.queue, ^{
                    if (scenario == 1) { localValid = NO; (void)[agent authorized]; localValid = YES; }
                    else [f.registry revoke];
                });
                CHECK(until(f, ^BOOL { return state == PLANKMacAgentRetiring; }));
                CHECK(![agent bindGraphicalScope:localScope].active);
                dispatch_sync(f.queue, ^{ active = [agent authorized]; }); CHECK(!active);
                dispatch_sync(f.queue, ^{ [agent retire]; });
                CHECK(until(f, ^BOOL { return retired == 1 && f.retired == 1; }));
                __block BOOL done;
                dispatch_sync(f.queue, ^{ done = [f.registry completeRetirement:f.lease]; }); CHECK(done);
            }
            CHECK(ready == 1);
        }
        dispatch_sync(f.queue, ^{ active = [agent authorized]; [agent stop]; }); CHECK(!active);
        [f close];
    }
}

int main(int argc, const char **argv) {
    BOOL native = argc == 1;
    BOOL identityOnly = argc == 2 && !strcmp(argv[1], "--identity-only");
    if (argc != 1 && !identityOnly && (argc != 2 || strcmp(argv[1], "--synthetic"))) return 2;
    alarm(60); setbuf(stdout, NULL);
    @autoreleasepool {
        NSString *requirement = PLANKMacOwnSigningRequirement(); CHECK(requirement.length > 0);
        if (identityOnly) {
            for (unsigned i = 0; i < 100; ++i) identityTests(requirement);
            printf("agent_identity_checks=%u result=0\n", checks);
            return 0;
        }
        CHECK(PLANKMacObserveAgentScope((PLANKMacAgentPeer){0}) == PLANKMacAgentUnavailable);
        CHECK(PLANKMacObserveAgentScope((PLANKMacAgentPeer){(uid_t)-1, getpid(), 1}) == PLANKMacAgentUnavailable);
        CHECK(PLANKMacObserveAgentScope((PLANKMacAgentPeer){getuid(), getpid(), UINT32_MAX}) == PLANKMacAgentUnavailable);
        if (native) {
            SecuritySessionId asid = noSecuritySession; SessionAttributeBits attributes = 0;
            CHECK(SessionGetInfo(callerSecuritySession, &asid, &attributes) == errSecSuccess);
            PLANKMacAgentPhase phase = PLANKMacObserveAgentScope((PLANKMacAgentPeer){geteuid(), getpid(), asid});
            CHECK(phase != PLANKMacAgentUnavailable);
            CHECK(PLANKMacObserveAgentScope((PLANKMacAgentPeer){geteuid() + 1, getpid(), asid}) == PLANKMacAgentUnavailable);
            Fixture *f = [[Fixture alloc] initWithNative:YES requirement:requirement]; CHECK(f != nil);
            xpc_connection_t peer = [f client]; xpc_object_t registration = message(1, 0, 0);
            xpc_dictionary_set_uint64(registration, "phase", phase);
            CHECK(status(request(peer, registration), 0));
            CHECK(until(f, ^BOOL { return f.attached == 1; }));
            __block BOOL matches;
            dispatch_sync(f.queue, ^{
                matches = f.lease.peer.uid == geteuid() && f.lease.peer.pid == getpid() &&
                    f.lease.peer.auditSession == asid && f.lease.phase == phase;
            });
            CHECK(matches);
            dispatch_sync(f.queue, ^{
                PLANKMacGraphicalIdentity scope = [f.registry authenticationScope:f.lease];
                CHECK(plank_macos_graphical_identity_valid(scope));
                CHECK(scope.generation == f.lease.generation);
                CHECK(scope.account.uid == geteuid());
                CHECK((scope.phase == PLANKMacScopeSignIn) == (phase == PLANKMacAgentLoginWindow));
                CHECK(![f.registry authenticationScope:nil].active);
                CHECK(![f.registry authenticationScope:[PLANKMacAgentLease new]].active);
                [f.registry revoke];
                CHECK(![f.registry authenticationScope:f.lease].active);
            });
            [f close]; xpc_connection_cancel(peer);
            printf("agent_registry_native_scope=%u peer_identity_match=1\n", phase);
        }

        Fixture *f = [[Fixture alloc] initWithNative:NO requirement:requirement]; CHECK(f != nil);
        xpc_connection_t peer = [f client]; xpc_object_t reply = request(peer, message(1, 0, 0));
        CHECK(status(reply, 0)); uint64_t generation = xpc_dictionary_get_uint64(reply, "generation"); CHECK(generation != 0);
        CHECK(until(f, ^BOOL { return f.attached == 1; }));
        dispatch_sync(f.queue, ^{
            PLANKMacAgentPeer actual = f.lease.peer;
            CHECK([f.registry admitsDesktopPeer:actual generation:generation] == (actual.uid != 0));
            CHECK(![f.registry admitsDesktopPeer:actual generation:0]);
            CHECK(![f.registry admitsDesktopPeer:actual generation:generation ^ 1]);
            PLANKMacAgentPeer other = actual; other.pid++;
            CHECK(![f.registry admitsDesktopPeer:other generation:generation]);
            other = actual; other.auditSession++;
            CHECK(![f.registry admitsDesktopPeer:other generation:generation]);
            other = actual; other.uid++;
            CHECK(![f.registry admitsDesktopPeer:other generation:generation]);
        });
        CHECK(status(request(peer, message(2, generation, 1)), 0));
        __block BOOL completed;
        dispatch_sync(f.queue, ^{ completed = [f.registry completeRetirement:f.lease]; }); CHECK(!completed);
        xpc_connection_t contender = [f client]; CHECK(status(request(contender, message(1, 0, 0)), 1));
        dispatch_sync(f.queue, ^{ f.allowed = NO; [f.registry refresh]; f.allowed = YES; [f.registry refresh]; });
        CHECK(until(f, ^BOOL { return f.revoked == 1 && !f.lease.active; }));
        dispatch_sync(f.queue, ^{ CHECK(![f.registry admitsDesktopPeer:f.lease.peer generation:generation]); });
        CHECK(status(request(peer, message(2, generation, 2)), 2));
        CHECK(status(request(contender, message(1, 0, 0)), 1)); // Scope recovery cannot revive or replace.
        CHECK(status(request(peer, message(3, generation, 3)), 2));
        CHECK(until(f, ^BOOL { return f.retired == 1; }));
        CHECK(status(request(contender, message(1, 0, 0)), 1)); // Agent's ack alone cannot release resources.
        PLANKMacAgentLease *old = f.lease;
        dispatch_sync(f.queue, ^{ completed = [f.registry completeRetirement:old]; }); CHECK(completed);
        reply = request(contender, message(1, 0, 0)); CHECK(status(reply, 0));
        CHECK(xpc_dictionary_get_uint64(reply, "generation") != generation);
        dispatch_sync(f.queue, ^{ completed = [f.registry completeRetirement:old]; }); CHECK(!completed);
        [f close]; xpc_connection_cancel(peer); xpc_connection_cancel(contender);

        for (unsigned scenario = 0; scenario < 12; ++scenario) {
            f = [[Fixture alloc] initWithNative:NO requirement:requirement]; CHECK(f != nil);
            peer = [f client]; xpc_object_t bad = message(1, 0, 0);
            switch (scenario) {
                case 0: xpc_dictionary_set_uint64(bad, "uid", 0); break;
                case 1: xpc_dictionary_set_bool(bad, "version", true); break;
                case 2: xpc_dictionary_set_int64(bad, "phase", 2); break;
                case 3: xpc_dictionary_set_uint64(bad, "phase", 0); break;
                case 4: xpc_dictionary_set_uint64(bad, "phase", 1); break;
                case 5: xpc_dictionary_set_uint64(bad, "operation", 99); break;
                default: {
                    reply = request(peer, bad); CHECK(status(reply, 0));
                    generation = xpc_dictionary_get_uint64(reply, "generation");
                    CHECK(until(f, ^BOOL { return f.attached == 1; }));
                    bad = message(2, generation, 1);
                    if (scenario == 6) xpc_dictionary_set_uint64(bad, "generation", generation ^ 1);
                    if (scenario == 7) xpc_dictionary_set_uint64(bad, "sequence", 0);
                    if (scenario == 8) xpc_dictionary_set_uint64(bad, "sequence", 2);
                    if (scenario == 9) xpc_dictionary_set_uint64(bad, "operation", 99);
                    if (scenario == 10) bad = message(1, 0, 0);
                    if (scenario == 11) CHECK(status(request(peer, bad), 0)); // Replay.
                }
            }
            CHECK(!status(request(peer, bad), 0));
            if (scenario >= 6) {
                CHECK(until(f, ^BOOL { return f.revoked == 1 && f.lost == 1 && !f.lease.active; }));
                contender = [f client]; CHECK(status(request(contender, message(1, 0, 0)), 1));
                xpc_connection_cancel(contender);
            } else CHECK(until(f, ^BOOL { return f.attached == 0; }));
            [f close]; xpc_connection_cancel(peer);
        }

        // Wrong server-side signing requirement must reject before scope/attach.
        f = [[Fixture alloc] initWithNative:NO requirement:@"identifier \"la.instinctual.PLANK.NotTheAgent\""];
        CHECK(f != nil); peer = [f client]; CHECK(!status(request(peer, message(1, 0, 0)), 0));
        CHECK(until(f, ^BOOL { return f.attached == 0; })); [f close]; xpc_connection_cancel(peer);

        // One-way registration cannot consume the exclusive attachment slot.
        f = [[Fixture alloc] initWithNative:NO requirement:requirement]; peer = [f client];
        xpc_connection_send_message(peer, message(1, 0, 0));
        CHECK(!status(request(peer, message(1, 0, 0)), 0));
        CHECK(until(f, ^BOOL { return f.attached == 0; }));
        contender = [f client]; CHECK(status(request(contender, message(1, 0, 0)), 0));
        [f close]; xpc_connection_cancel(peer); xpc_connection_cancel(contender);

        // One active agent plus three bounded pending peers. The fifth is
        // rejected; pending peers expire without expiring the active agent.
        f = [[Fixture alloc] initWithNative:NO requirement:requirement]; peer = [f client];
        reply = request(peer, message(1, 0, 0)); CHECK(status(reply, 0));
        generation = xpc_dictionary_get_uint64(reply, "generation");
        NSMutableArray *pending = [NSMutableArray array];
        for (unsigned i = 0; i < 3; ++i) {
            xpc_connection_t p = [f client]; [pending addObject:p];
            CHECK(status(request(p, message(1, 0, 0)), 1));
        }
        contender = [f client]; CHECK(!status(request(contender, message(1, 0, 0)), 1));
        xpc_connection_cancel(contender);
        sleep(6);
        for (xpc_connection_t p in pending) { CHECK(!status(request(p, message(1, 0, 0)), 1)); xpc_connection_cancel(p); }
        CHECK(status(request(peer, message(2, generation, 1)), 0));
        contender = [f client]; CHECK(status(request(contender, message(1, 0, 0)), 1));
        [f close]; xpc_connection_cancel(peer); xpc_connection_cancel(contender);

        @autoreleasepool {
        f = [[Fixture alloc] initWithNative:NO requirement:requirement]; peer = [f client];
        CHECK(status(request(peer, message(1, 0, 0)), 0)); CHECK(until(f, ^BOOL { return f.attached == 1; }));
        xpc_connection_cancel(peer);
        CHECK(until(f, ^BOOL { return f.revoked == 1 && f.lost == 1; }));
        contender = [f client]; CHECK(status(request(contender, message(1, 0, 0)), 1));
        dispatch_sync(f.queue, ^{ completed = [f.registry completeRetirement:f.lease]; }); CHECK(completed);
        CHECK(status(request(contender, message(1, 0, 0)), 0));
        CHECK(until(f, ^BOOL { return f.attached == 2; }));
        old = f.lease;
        dispatch_sync(f.queue, ^{ f.registry = nil; }); // Abandoned owner cannot leave an active lease.
        }
        CHECK(until(f, ^BOOL { return !old.active; }));
        xpc_connection_cancel(contender); xpc_connection_cancel(f.listener);
        connectionTests(requirement);
        printf("agent_registry_checks=%u native_scope=%d result=0\n", checks, native);
    }
    return 0;
}
