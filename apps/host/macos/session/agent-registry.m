// SPDX-License-Identifier: GPL-3.0-or-later
#import "agent-registry.h"
#import "../auth/boot-sign-in.h"
#import <Security/Security.h>
#import <Security/AuthSession.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <time.h>
#include <membership.h>

PLANKMacAgentPhase PLANKMacObserveAgentScope(PLANKMacAgentPeer peer) {
    if (peer.pid <= 1 || peer.uid == (uid_t)-1 || !peer.auditSession || peer.auditSession == UINT32_MAX)
        return PLANKMacAgentUnavailable;
    SecuritySessionId actual = noSecuritySession;
    SessionAttributeBits attributes = 0;
    if (SessionGetInfo(peer.auditSession, &actual, &attributes) != errSecSuccess ||
        actual != peer.auditSession || !(attributes & sessionHasGraphicAccess))
        return PLANKMacAgentUnavailable;
    if (peer.uid == 0 && PLANKMacBootSignInSession(peer.auditSession))
        return PLANKMacAgentLoginWindow;
    uid_t console = (uid_t)-1;
    NSString *name = CFBridgingRelease(SCDynamicStoreCopyConsoleUser(NULL, &console, NULL));
    if (!name || console != peer.uid) return PLANKMacAgentUnavailable;
    if (!console) return [name isEqualToString:@"loginwindow"] ? PLANKMacAgentLoginWindow : PLANKMacAgentUnavailable;
    return [name isEqualToString:@"loginwindow"] ? PLANKMacAgentUnavailable : PLANKMacAgentDesktop;
}

NSString *PLANKMacOwnSigningRequirement(void) {
    SecCodeRef own = NULL;
    SecRequirementRef requirement = NULL;
    CFStringRef text = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &own) == errSecSuccess &&
        SecCodeCopyDesignatedRequirement(own, kSecCSDefaultFlags, &requirement) == errSecSuccess)
        SecRequirementCopyString(requirement, kSecCSDefaultFlags, &text);
    if (requirement) CFRelease(requirement);
    if (own) CFRelease(own);
    return CFBridgingRelease(text);
}

@interface PLANKMacAgentLease ()
@property(readwrite) PLANKMacAgentPeer peer;
@property(readwrite) PLANKMacAgentPhase phase;
@property(readwrite) uint64_t generation;
@property(readwrite) BOOL active;
@end
@implementation PLANKMacAgentLease
@end

@interface PLANKMacAgentLink : NSObject
@property xpc_connection_t connection;
@property PLANKMacAgentLease *lease;
@property uint64_t sequence, created;
@property BOOL closed, retired;
@property BOOL identityRequested;
@end
@implementation PLANKMacAgentLink
@end

@implementation PLANKMacAgentRegistry {
    dispatch_queue_t _queue;
    NSString *_requirement;
    PLANKMacAgentScope _scope;
    void (^_event)(PLANKMacAgentLease *, PLANKMacAgentEvent);
    NSMutableArray<PLANKMacAgentLink *> *_links;
    PLANKMacAgentLink *_current;
    dispatch_source_t _watch;
    BOOL _stopped;
    BOOL _issuing;
    dispatch_queue_t _identityQueue;
}

- (instancetype)init { return nil; }
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
                         scope:(PLANKMacAgentScope)scope
                         event:(void (^)(PLANKMacAgentLease *, PLANKMacAgentEvent))event {
    if (!queue || !scope || !event || !requirement.length || requirement.length > 8192 ||
        strlen(requirement.UTF8String) != [requirement lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return nil;
    SecRequirementRef parsed = NULL;
    if (SecRequirementCreateWithString((__bridge CFStringRef)requirement, kSecCSDefaultFlags, &parsed) != errSecSuccess) return nil;
    CFRelease(parsed);
    self = [super init];
    if (!self) return nil;
    _queue = queue; _requirement = [requirement copy]; _scope = [scope copy]; _event = [event copy];
    _links = [NSMutableArray array];
    _identityQueue = dispatch_queue_create("la.instinctual.PLANK.Host.identity-issuer", DISPATCH_QUEUE_SERIAL);
    __weak typeof(self) weakSelf = self;
    _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(_watch, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 25 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_watch, ^{
        typeof(self) owner = weakSelf;
        if (!owner) return;
        [owner refresh];
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        for (PLANKMacAgentLink *link in owner->_links.copy)
            if (!link.lease && now - link.created >= 5 * NSEC_PER_SEC) [owner close:link];
    });
    dispatch_resume(_watch);
    return self;
}

static BOOL word(xpc_object_t message, const char *key, uint64_t *value) {
    xpc_object_t item = xpc_dictionary_get_value(message, key);
    if (!item || xpc_get_type(item) != XPC_TYPE_UINT64) return NO;
    *value = xpc_uint64_get_value(item); return YES;
}

- (void)close:(PLANKMacAgentLink *)link {
    if (link.closed) return;
    if (link == _current && link.lease.active) [self revoke];
    link.closed = YES;
    if (link.retired) {
        // Let the retirement reply leave XPC before cancelling, including when
        // the trusted controller completes cleanup inside its retired callback.
        xpc_connection_t peer = link.connection;
        xpc_connection_send_barrier(peer, ^{ xpc_connection_cancel(peer); });
    } else xpc_connection_cancel(link.connection);
    [_links removeObject:link];
    if (link == _current && !link.retired) _event(link.lease, PLANKMacAgentLost);
    // Keep _current until the controller verifies independent cleanup.
}

- (void)reply:(xpc_object_t)response status:(uint64_t)status link:(PLANKMacAgentLink *)link {
    xpc_dictionary_set_uint64(response, "version", 1);
    xpc_dictionary_set_uint64(response, "status", status);
    if (!status) xpc_dictionary_set_uint64(response, "generation", link.lease.generation);
    xpc_connection_send_message(link.connection, response);
}

- (void)receive:(xpc_object_t)message link:(PLANKMacAgentLink *)link {
    if (link.closed || _stopped) return;
    // A certificate request is one-shot, never a route into a graphical lease.
    if (link.identityRequested) { [self close:link]; return; }
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) { [self close:link]; return; }
    // Reject one-way calls before claiming an exclusive slot or mutating it.
    xpc_object_t response = xpc_dictionary_create_reply(message);
    if (!response) { [self close:link]; return; }
    uint64_t version = 0, operation = 0;
    if (!word(message, "version", &version) || version != 1 || !word(message, "operation", &operation)) {
        [self close:link]; return;
    }
    if (operation == 5) {
        // A separate short-lived connection obtains only a certificate, not a
        // graphical lease. The kernel and signing requirement identify its
        // caller; a network request cannot choose a UID, key path or authority.
        size_t length = 0;
        const void *bytes = xpc_dictionary_get_data(message, "csr", &length);
        PLANKMacAgentPeer peer = {xpc_connection_get_euid(link.connection),
            xpc_connection_get_pid(link.connection), (uint32_t)xpc_connection_get_asid(link.connection)};
        if (link.lease || link.identityRequested || _issuing || !self.issueIdentity ||
            xpc_dictionary_get_count(message) != 3 || !bytes || !length || length > 16384 ||
            !peer.uid || _scope(peer) != PLANKMacAgentDesktop) { [self close:link]; return; }
        link.identityRequested = YES;
        _issuing = YES;
        NSData *csr = [NSData dataWithBytes:bytes length:length];
        NSDictionary<NSString *, NSData *> *(^issue)(NSData *) = self.issueIdentity;
        dispatch_async(_identityQueue, ^{
            NSDictionary<NSString *, NSData *> *issued = issue(csr);
            dispatch_async(self->_queue, ^{
                self->_issuing = NO;
                if (link.closed || self->_stopped) return;
                if (self->_scope(peer) != PLANKMacAgentDesktop || issued.count != 3) { [self close:link]; return; }
                for (NSString *name in @[@"certificate", @"der", @"authority"]) {
                    NSData *value = issued[name];
                    if (![value isKindOfClass:NSData.class] || !value.length || value.length > 16384) {
                        [self close:link]; return;
                    }
                    xpc_dictionary_set_data(response, name.UTF8String, value.bytes, value.length);
                }
                xpc_dictionary_set_uint64(response, "version", 1);
                xpc_dictionary_set_uint64(response, "status", 0);
                xpc_connection_send_message(link.connection, response);
                // A send barrier drains this sender, not the receiving client's
                // reply handler. Cancelling here can race a valid reply into an
                // XPC error. The caller closes after consuming it; abandoned
                // one-shot links retain the existing five-second expiry.
            });
        });
        return;
    }
    if (operation == 1) { // Register: no caller-supplied UID/PID/audit session.
        uint64_t phase = 0;
        if (link.lease || xpc_dictionary_get_count(message) != 3 || !word(message, "phase", &phase) ||
            (phase != PLANKMacAgentLoginWindow && phase != PLANKMacAgentDesktop)) { [self close:link]; return; }
        PLANKMacAgentPeer peer = {xpc_connection_get_euid(link.connection),
            xpc_connection_get_pid(link.connection), (uint32_t)xpc_connection_get_asid(link.connection)};
        if (_scope(peer) != phase) { [self close:link]; return; }
        if (_current) { [self reply:response status:1 link:link]; return; }
        uint64_t generation = 0;
        if (SecRandomCopyBytes(kSecRandomDefault, sizeof(generation), (uint8_t *)&generation) != errSecSuccess || !generation) {
            [self close:link]; return;
        }
        PLANKMacAgentLease *lease = [PLANKMacAgentLease new];
        lease.peer = peer; lease.phase = (PLANKMacAgentPhase)phase;
        lease.generation = generation; lease.active = YES;
        link.lease = lease; _current = link;
        [self reply:response status:0 link:link];
        if (lease.active) _event(lease, PLANKMacAgentAttached);
        return;
    }
    uint64_t generation = 0, sequence = 0;
    if (!link.lease || link != _current || xpc_dictionary_get_count(message) != 4 ||
        !word(message, "generation", &generation) || generation != link.lease.generation ||
        !word(message, "sequence", &sequence) || link.sequence == UINT64_MAX || sequence != link.sequence + 1) {
        [self close:link]; return;
    }
    link.sequence = sequence;
    if (operation == 2) { // Health/authority check; cannot revive retired leases.
        [self refresh];
        [self reply:response status:link.lease.active ? 0 : 2 link:link];
    } else if (operation == 3 && !link.retired) {
        [self revoke]; link.retired = YES;
        [self reply:response status:2 link:link];
        _event(link.lease, PLANKMacAgentRetired);
    } else [self close:link];
}

- (PLANKMacGraphicalIdentity)authenticationScope:(PLANKMacAgentLease *)lease {
    dispatch_assert_queue(_queue);
    [self refresh];
    PLANKMacGraphicalIdentity identity = {0};
    if (_stopped || !lease || _current.lease != lease || !lease.active) return identity;
    if (lease.phase == PLANKMacAgentLoginWindow && lease.peer.uid == 0) {
        identity.phase = PLANKMacScopeSignIn;
    } else if (lease.phase == PLANKMacAgentDesktop && lease.peer.uid != 0 && lease.peer.uid != (uid_t)-1) {
        identity.phase = PLANKMacScopeDesktop;
        identity.account.uid = lease.peer.uid;
        if (mbr_uid_to_uuid(lease.peer.uid, identity.account.uuid) ||
            !plank_macos_account_identity_valid(identity.account)) { [self revoke]; return (PLANKMacGraphicalIdentity){0}; }
    } else { [self revoke]; return identity; }
    // Directory resolution may wait; never grant a scope that changed meanwhile.
    [self refresh];
    if (_current.lease != lease || !lease.active) return (PLANKMacGraphicalIdentity){0};
    identity.active = true;
    identity.generation = lease.generation;
    return identity;
}

- (void)accept:(xpc_connection_t)peer {
    dispatch_assert_queue(_queue);
    // XPC requires each accepted inactive connection to be activated or cancelled.
    if (_stopped || _links.count >= 4 ||
        xpc_connection_set_peer_code_signing_requirement(peer, _requirement.UTF8String)) {
        xpc_connection_cancel(peer); return;
    }
    PLANKMacAgentLink *link = [PLANKMacAgentLink new];
    link.connection = peer; link.created = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    [_links addObject:link];
    __weak typeof(self) weakSelf = self;
    __weak PLANKMacAgentLink *weakLink = link;
    xpc_connection_set_target_queue(peer, _queue);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        typeof(self) owner = weakSelf;
        PLANKMacAgentLink *current = weakLink;
        if (owner && current) [owner receive:message link:current];
    });
    xpc_connection_activate(peer);
}

- (void)refresh {
    dispatch_assert_queue(_queue);
    if (_current.lease.active && _scope(_current.lease.peer) != _current.lease.phase) [self revoke];
}
- (BOOL)admitsDesktopPeer:(PLANKMacAgentPeer)peer generation:(uint64_t)generation {
    dispatch_assert_queue(_queue);
    [self refresh];
    PLANKMacAgentLease *lease = _current.lease;
    return !_stopped && lease.active && lease.phase == PLANKMacAgentDesktop &&
        generation && lease.generation == generation && peer.uid != 0 &&
        lease.peer.uid == peer.uid && lease.peer.pid == peer.pid &&
        lease.peer.auditSession == peer.auditSession;
}
- (void)revoke {
    dispatch_assert_queue(_queue);
    if (!_current.lease.active) return;
    _current.lease.active = NO;
    _event(_current.lease, PLANKMacAgentRevoked);
    if (_current && !_current.closed) {
        xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(message, "version", 1);
        xpc_dictionary_set_uint64(message, "operation", 4);
        xpc_dictionary_set_uint64(message, "generation", _current.lease.generation);
        xpc_connection_send_message(_current.connection, message);
    }
}
- (BOOL)completeRetirement:(PLANKMacAgentLease *)lease {
    dispatch_assert_queue(_queue);
    if (!lease || lease != _current.lease || lease.active) return NO;
    PLANKMacAgentLink *old = _current; _current = nil;
    [self close:old];
    return YES;
}
- (void)stop {
    dispatch_assert_queue(_queue);
    if (_stopped) return;
    _stopped = YES; [self revoke];
    dispatch_source_cancel(_watch);
    for (PLANKMacAgentLink *link in _links.copy) [self close:link];
}
- (void)dealloc {
    // Abandonment cannot keep a live lease or an XPC handler/owner retain cycle.
    _current.lease.active = NO;
    if (_watch) dispatch_source_cancel(_watch);
    for (PLANKMacAgentLink *link in _links) xpc_connection_cancel(link.connection);
}
@end
