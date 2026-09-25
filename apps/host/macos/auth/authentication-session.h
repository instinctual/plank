// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "account-channel.h"

// Supplied by the trusted graphical-session owner, never by request JSON.
typedef PLANKMacGraphicalIdentity (^PLANKMacGraphicalSnapshot)(void);

// Opaque, process-local authorization. Only its issuing session can activate
// it. Never log/serialize this object or persist its short-lived transport key.
@interface PLANKMacStreamLease : NSObject
@property(readonly, copy) NSString *transportToken;
@end

// HTTPS start/respond state bound to one verified graphical scope. The trusted
// snapshot must latch revocation and bind the machine/agent generation; console
// observation or a caller-supplied phase alone cannot grant LoginWindow access.
// Its HTTPS adapter must enforce TLS, body limits, no-cache responses,
// and obtain the canonical peer IP bytes from its accepted connection (not a
// forwarded header). Calls belong on a background authentication queue.
// This component opens no socket and does not log or retain passwords.
@interface PLANKMacAuthenticationSession : NSObject
- (instancetype)initWithGraphicalSnapshot:(PLANKMacGraphicalSnapshot)snapshot;
- (NSDictionary *)startForPeer:(NSData *)peer username:(NSString *)username;
- (NSDictionary *)respondForPeer:(NSData *)peer conversation:(NSString *)conversation
                       password:(NSMutableData *)password;
- (BOOL)authorizeToken:(NSString *)token peer:(NSData *)peer
             identity:(PLANKMacAccountIdentity *)identity;
// After validating the requested capture/profile/geometry, atomically consume
// the HTTP token. At most one pending/active lease exists; no implicit takeover.
- (PLANKMacStreamLease *)claimToken:(NSString *)token peer:(NSData *)peer;
// Call only after this lease's token-authenticated QUIC endpoint becomes ready.
// Pending leases expire after 15 seconds; activation does not renew old tokens.
- (BOOL)activateStreamLease:(PLANKMacStreamLease *)lease;
// Check before media/input work and on the lifecycle watchdog. Graphical loss
// latches revocation; caller must stop the endpoint/capture on failure.
- (BOOL)authorizeStreamLease:(PLANKMacStreamLease *)lease
                   identity:(PLANKMacAccountIdentity *)identity;
// Explicit transfer only: the fresh peer-bound setup token must name the
// same verified account as this exact lease, including at LoginWindow.
- (BOOL)authorizeTakeoverToken:(NSString *)token peer:(NSData *)peer
                         lease:(PLANKMacStreamLease *)lease;
- (BOOL)reserveTakeoverToken:(NSString *)token peer:(NSData *)peer
                       lease:(PLANKMacStreamLease *)lease;
// Linearize a bounded, nonblocking media enqueue with revocation. Do not do
// encoding, socket waits, callbacks into UI, or account verification in action.
- (BOOL)performWithStreamLease:(PLANKMacStreamLease *)lease action:(void (^)(void))action;
- (void)endStreamLease:(PLANKMacStreamLease *)lease;
// Advisory, lock-free snapshot for discovery. Includes pending stream setup;
// never prunes tokens, queries accounts or grants authorization.
- (BOOL)hasStreamLease;
- (void)revokeToken:(NSString *)token;
- (void)revokeAll;
@end
