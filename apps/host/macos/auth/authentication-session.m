// SPDX-License-Identifier: GPL-3.0-or-later
#import "authentication-session.h"
#import <Security/Security.h>
#include <stdio.h>
#include <time.h>
#include <stdatomic.h>

@interface PLANKMacAuthRecord : NSObject
@property(copy) NSData *peer;
@property(copy) NSString *username;
@property uint64_t expires;
@property PLANKMacGraphicalIdentity scope;
@property PLANKMacAccountIdentity account;
@end
@implementation PLANKMacAuthRecord
@end

@interface PLANKMacStreamLease ()
@property(readwrite, copy) NSString *transportToken;
@property(strong) PLANKMacAuthRecord *record;
@property(copy) NSString *claimedToken;
@property uint64_t activateBefore;
@property BOOL active;
@end
@implementation PLANKMacStreamLease
@end

@implementation PLANKMacAuthenticationSession {
    PLANKMacGraphicalSnapshot _snapshot;
    NSMutableDictionary<NSString *, PLANKMacAuthRecord *> *_pending;
    NSMutableDictionary<NSString *, PLANKMacAuthRecord *> *_tokens;
    PLANKMacStreamLease *_lease;
    atomic_bool _hasStreamLease;
    uint64_t _revocationGeneration;
    BOOL _verifying;
    NSString *_takeoverToken;
    uint64_t _takeoverDeadline;
}

static uint64_t monotonicSeconds(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000000ULL;
}

static NSString *randomToken(void) {
    unsigned char bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
    // Base64 is opaque JSON/header data, never a URL parameter or log field.
    NSString *token = [[NSData dataWithBytes:bytes length:sizeof(bytes)] base64EncodedStringWithOptions:0];
    volatile unsigned char *p = bytes;
    for (size_t i = 0; i < sizeof(bytes); ++i) p[i] = 0;
    return token;
}

static BOOL validPeer(NSData *peer) {
    return [peer isKindOfClass:NSData.class] && (peer.length == 4 || peer.length == 16);
}

static NSDictionary *denied(void) { return @{@"state": @"denied"}; }
static NSDictionary *busy(void) { return @{@"state": @"busy"}; }

enum { MaximumPendingChallenges = 16, MaximumSetupTokens = 4 };

- (instancetype)init { return nil; }

- (instancetype)initWithGraphicalSnapshot:(PLANKMacGraphicalSnapshot)snapshot {
    if (!snapshot) return nil;
    self = [super init];
    if (self) {
        _snapshot = [snapshot copy];
        _pending = [NSMutableDictionary dictionary];
        _tokens = [NSMutableDictionary dictionary];
        atomic_init(&_hasStreamLease, false);
    }
    return self;
}

- (void)prune {
    uint64_t now = monotonicSeconds();
    PLANKMacGraphicalIdentity current = _snapshot();
    for (NSMutableDictionary *records in @[_pending, _tokens]) {
        for (NSString *key in records.allKeys) {
            PLANKMacAuthRecord *record = records[key];
            if (record.expires <= now || !plank_macos_same_graphical_scope(record.scope, current))
                [records removeObjectForKey:key];
        }
    }
    if (_takeoverToken && (now >= _takeoverDeadline || !_tokens[_takeoverToken])) _takeoverToken = nil;
    if (_lease && ((!_lease.active && _lease.activateBefore <= now) ||
            !plank_macos_account_may_attach(_lease.record.account, _lease.record.scope, current))) {
        [self endStreamLease:_lease];
    }
}

- (NSDictionary *)startForPeer:(NSData *)peer username:(NSString *)username {
    @synchronized(self) {
        if (!validPeer(peer) || ![username isKindOfClass:NSString.class]) return denied();
        NSData *nameBytes = [username dataUsingEncoding:NSUTF8StringEncoding];
        if (!nameBytes.length || nameBytes.length > 255 || memchr(nameBytes.bytes, 0, nameBytes.length))
            return denied();
        [self prune];
        // A full setup table must not prevent an existing owner from verifying
        // and replacing their abandoned token. Challenges have their own bound.
        if (_pending.count >= MaximumPendingChallenges) return busy();
        PLANKMacGraphicalIdentity scope = _snapshot();
        if (!plank_macos_graphical_identity_valid(scope)) return denied();
        NSString *conversation = randomToken();
        if (!conversation || _pending[conversation]) return denied();
        PLANKMacAuthRecord *record = [PLANKMacAuthRecord new];
        record.peer = peer;
        record.username = username;
        record.expires = monotonicSeconds() + 120;
        record.scope = scope;
        _pending[conversation] = record;
        return @{@"state": @"challenge", @"conversation_id": conversation,
            @"messages": @[@{@"style": @1, @"text": @"Password:"}]};
    }
}

- (NSDictionary *)respondForPeer:(NSData *)peer conversation:(NSString *)conversation
                       password:(NSMutableData *)password {
    @try {
        PLANKMacAuthRecord *record;
        uint64_t generation;
        @synchronized(self) {
            if (!validPeer(peer) || ![conversation isKindOfClass:NSString.class] || conversation.length != 44)
                return denied();
            [self prune];
            record = _pending[conversation];
            if (!record || ![record.peer isEqual:peer]) return denied();
            // Consume BEFORE any verification. A response can never be replayed.
            [_pending removeObjectForKey:conversation];
            if (_verifying) return busy();
            _verifying = YES;
            generation = _revocationGeneration;
        }
        // Open Directory/helper waits must not hold the lock needed to revoke
        // or validate an active stream. Recheck the revocation epoch afterward.
        @try {
            PLANKMacAccountIdentity account = {0};
            PLANKMacAuthenticationResult result = PLANKMacVerifyAccountIsolated(record.username, password, &account);
            @synchronized(self) {
                if (generation != _revocationGeneration) {
                    fprintf(stderr, "macos_auth_setup rejected=revoked-during-verification\n");
                    return denied();
                }
                // A helper timeout/cooldown is not a rejected OS password.
                if (result == PLANKMacAuthenticationUnavailable) return busy();
                if (result != PLANKMacAuthenticationVerified) return denied();
                if (!plank_macos_account_may_attach(account, record.scope, _snapshot())) {
                    fprintf(stderr, "macos_auth_setup rejected=desktop-authority\n");
                    return denied();
                }
                [self prune];
                // Only a VERIFIED account can supersede its unused setup on
                // this peer. Never let an unauthenticated name/IP invalidate
                // another login, a different account behind NAT, or a lease.
                NSMutableArray<NSString *> *superseded = [NSMutableArray array];
                for (NSString *key in _tokens) {
                    PLANKMacAuthRecord *old = _tokens[key];
                    if (![key isEqual:_takeoverToken] && [old.peer isEqual:peer] && old.account.uid == account.uid &&
                            !memcmp(old.account.uuid, account.uuid, sizeof(account.uuid)))
                        [superseded addObject:key];
                }
                if (_tokens.count - superseded.count >= MaximumSetupTokens) return busy();
                NSString *token = randomToken();
                if (!token || _tokens[token]) return denied();
                [_tokens removeObjectsForKeys:superseded];
                record.account = account;
                record.username = nil;
                record.expires = monotonicSeconds() + 300;
                _tokens[token] = record;
                return @{@"state": @"authenticated", @"session_token": token,
                    @"desktop_stage": record.scope.phase == PLANKMacScopeSignIn ? @"greeter" : @"desktop"};
            }
        } @finally {
            @synchronized(self) { _verifying = NO; }
        }
    } @finally {
        [password resetBytesInRange:NSMakeRange(0, password.length)];
    }
}

- (BOOL)authorizeToken:(NSString *)token peer:(NSData *)peer identity:(PLANKMacAccountIdentity *)identity {
    if (identity) memset(identity, 0, sizeof(*identity));
    @synchronized(self) {
        if (!identity || !validPeer(peer) || ![token isKindOfClass:NSString.class] || token.length != 44)
            return NO;
        [self prune];
        PLANKMacAuthRecord *record = _tokens[token];
        if (!record || ![record.peer isEqual:peer] ||
            !plank_macos_account_may_attach(record.account, record.scope, _snapshot())) return NO;
        *identity = record.account;
        return YES;
    }
}

- (void)revokeAll {
    @synchronized(self) {
        ++_revocationGeneration;
        [_pending removeAllObjects];
        [_tokens removeAllObjects];
        _takeoverToken = nil;
        [self endStreamLease:_lease];
    }
}

- (void)revokeToken:(NSString *)token {
    @synchronized(self) {
        if ([token isKindOfClass:NSString.class]) {
            if ([_takeoverToken isEqual:token]) _takeoverToken = nil;
            [_tokens removeObjectForKey:token];
            if ([_lease.claimedToken isEqual:token]) [self endStreamLease:_lease];
        }
    }
}

- (PLANKMacStreamLease *)claimToken:(NSString *)token peer:(NSData *)peer {
    @synchronized(self) {
        [self prune];
        PLANKMacAccountIdentity account = {0};
        if (_lease || ![self authorizeToken:token peer:peer identity:&account]) return nil;
        NSString *transportToken = randomToken();
        if (!transportToken || [transportToken isEqual:token]) return nil;
        PLANKMacStreamLease *lease = [PLANKMacStreamLease new];
        lease.record = _tokens[token];
        lease.claimedToken = token;
        lease.transportToken = transportToken;
        lease.activateBefore = monotonicSeconds() + 15;
        [_tokens removeObjectForKey:token];
        _lease = lease;
        atomic_store_explicit(&_hasStreamLease, true, memory_order_relaxed);
        return lease;
    }
}

- (BOOL)activateStreamLease:(PLANKMacStreamLease *)lease {
    @synchronized(self) {
        [self prune];
        if (!lease || lease != _lease || lease.active) return NO;
        lease.active = YES;
        return YES;
    }
}

- (BOOL)authorizeStreamLease:(PLANKMacStreamLease *)lease identity:(PLANKMacAccountIdentity *)identity {
    if (identity) memset(identity, 0, sizeof(*identity));
    @synchronized(self) {
        [self prune];
        if (!identity || !lease || lease != _lease || !lease.active) return NO;
        *identity = lease.record.account;
        return YES;
    }
}

- (void)endStreamLease:(PLANKMacStreamLease *)lease {
    @synchronized(self) {
        if (!lease || lease != _lease) return;
        lease.active = NO;
        lease.transportToken = nil;
        lease.claimedToken = nil;
        lease.record = nil;
        _lease = nil;
        atomic_store_explicit(&_hasStreamLease, false, memory_order_relaxed);
    }
}

- (BOOL)hasStreamLease {
    return atomic_load_explicit(&_hasStreamLease, memory_order_relaxed);
}

- (BOOL)authorizeTakeoverToken:(NSString *)token peer:(NSData *)peer
                         lease:(PLANKMacStreamLease *)lease {
    @synchronized(self) {
        PLANKMacAccountIdentity account = {0};
        return [self authorizeToken:token peer:peer identity:&account] &&
            lease && lease == _lease && lease.record &&
            account.uid == lease.record.account.uid &&
            !memcmp(account.uuid, lease.record.account.uuid, sizeof(account.uuid));
    }
}

- (BOOL)reserveTakeoverToken:(NSString *)token peer:(NSData *)peer
                       lease:(PLANKMacStreamLease *)lease {
    @synchronized(self) {
        if (![self authorizeTakeoverToken:token peer:peer lease:lease] ||
                (_takeoverToken && ![_takeoverToken isEqual:token])) return NO;
        // Another reconnect behind the same relay/NAT must not supersede the
        // setup token while the explicitly approved transfer drains the peer.
        _takeoverToken = [token copy];
        _takeoverDeadline = monotonicSeconds() + 15;
        return YES;
    }
}

- (BOOL)performWithStreamLease:(PLANKMacStreamLease *)lease action:(void (^)(void))action {
    @synchronized(self) {
        [self prune];
        if (!action || !lease || lease != _lease || !lease.active) return NO;
        action();
        return YES;
    }
}
@end
