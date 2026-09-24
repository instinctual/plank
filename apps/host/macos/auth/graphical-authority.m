// SPDX-License-Identifier: GPL-3.0-or-later
#import "graphical-authority.h"
#import "boot-sign-in.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Security/AuthSession.h>
#import <Security/Security.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <membership.h>
#include <time.h>
#include <unistd.h>

// Bound observation age even when the observer or an OS service stalls. Measure
// from before the read: a late reply must never renew an expired authority.
static const uint64_t ObservationInterval = 500 * NSEC_PER_MSEC;
static const uint64_t MaximumObservationAge = NSEC_PER_SEC;
static uint64_t authorityNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }

static BOOL readGraphical(PLANKMacGraphicalPhase phase, PLANKMacAccountIdentity *account, SecuritySessionId *sessionID) {
    memset(account, 0, sizeof(*account));
    if (getuid() != geteuid() ||
        (phase == PLANKMacScopeDesktop ? !geteuid() : phase != PLANKMacScopeSignIn || geteuid() != 0)) return NO;
    SessionAttributeBits attributes = 0;
    if (SessionGetInfo(callerSecuritySession, sessionID, &attributes) != errSecSuccess ||
        *sessionID == noSecuritySession || !(attributes & sessionHasGraphicAccess)) return NO;
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    if (!session || session[(__bridge NSString *)kCGSessionOnConsoleKey] != (__bridge id)kCFBooleanTrue) return NO;
    id done = session[(__bridge NSString *)kCGSessionLoginDoneKey];
    id number = session[(__bridge NSString *)kCGSessionUserIDKey];
    int64_t uid = -1;
    if (!number || CFGetTypeID((__bridge CFTypeRef)number) != CFNumberGetTypeID() ||
        !CFNumberGetValue((__bridge CFNumberRef)number, kCFNumberSInt64Type, &uid)) return NO;
    if (phase == PLANKMacScopeSignIn &&
        PLANKMacBootSignInRecord(session, *sessionID, PLANKMacWindowServerUID()) &&
        PLANKMacBootSignInSession(*sessionID)) return YES;
    if (uid != geteuid()) return NO;
    uid_t consoleUID = (uid_t)-1;
    NSString *name = CFBridgingRelease(SCDynamicStoreCopyConsoleUser(NULL, &consoleUID, NULL));
    if (!name || consoleUID != geteuid()) return NO;
    if (phase == PLANKMacScopeSignIn)
        return done == (__bridge id)kCFBooleanFalse && [name isEqualToString:@"loginwindow"];
    if (done != (__bridge id)kCFBooleanTrue || [name isEqualToString:@"loginwindow"]) return NO;
    account->uid = (uint32_t)uid;
    return !mbr_uid_to_uuid(consoleUID, account->uuid) && plank_macos_account_identity_valid(*account);
}

@implementation PLANKMacGraphicalAuthority {
    PLANKMacGraphicalIdentity _initial;
    SecuritySessionId _sessionID;
    BOOL _revoked;
    BOOL _notified;
    uint64_t _checkedAt;
    dispatch_source_t _watch;
    NSMutableArray *_workspaceObservers;
}

- (instancetype)init { return nil; }
- (instancetype)initWithPhase:(PLANKMacGraphicalPhase)phase {
    if (phase != PLANKMacScopeDesktop && phase != PLANKMacScopeSignIn) return nil;
    self = [super init];
    if (!self) return nil;
    _revoked = YES;
    _initial.phase = phase;
    // Subscribe before sampling. User switching and sleep revoke; locking the
    // current console does not end its authenticated remote connection. The OS
    // still owns the lock screen and requires its normal unlock credentials.
    // Never use screen-unlock notifications to grant or re-arm authority.
    __weak typeof(self) weakSelf = self;
    _workspaceObservers = [NSMutableArray array];
    for (NSNotificationName name in @[NSWorkspaceSessionDidResignActiveNotification, NSWorkspaceWillSleepNotification]) {
        id observer = [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:name
            object:nil queue:nil usingBlock:^(NSNotification *notification) {
                (void)notification; [weakSelf revoke];
            }];
        [_workspaceObservers addObject:observer];
    }
    uint64_t began = authorityNow();
    PLANKMacAccountIdentity account = {0};
    SecuritySessionId sessionID = noSecuritySession;
    BOOL valid = readGraphical(phase, &account, &sessionID);
    @synchronized(self) {
        if (!_notified && valid && authorityNow() - began < MaximumObservationAge &&
            SecRandomCopyBytes(kSecRandomDefault, sizeof(_initial.generation),
                               (uint8_t *)&_initial.generation) == errSecSuccess && _initial.generation) {
            _initial.account = account; _sessionID = sessionID; _checkedAt = began;
            _initial.active = true;
            _revoked = NO;
        }
    }
    dispatch_queue_t observer = dispatch_queue_create("la.instinctual.PLANK.graphical-observation",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, observer);
    dispatch_source_set_timer(_watch, DISPATCH_TIME_NOW, ObservationInterval, 25 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_watch, ^{ [weakSelf refresh]; });
    dispatch_resume(_watch);
    return self;
}

- (void)refresh {
    uint64_t began = authorityNow();
    @synchronized(self) {
        if (_revoked || began < _checkedAt || began - _checkedAt >= MaximumObservationAge) {
            _revoked = YES; return;
        }
    }
    // No WindowServer, SystemConfiguration or account RPC while holding the
    // snapshot/revocation lock. Media and input must never wait for those calls.
    PLANKMacAccountIdentity account = {0};
    SecuritySessionId sessionID = noSecuritySession;
    BOOL valid = readGraphical(_initial.phase, &account, &sessionID);
    @synchronized(self) {
        uint64_t now = authorityNow();
        if (_revoked || now < _checkedAt || now - _checkedAt >= MaximumObservationAge ||
            !valid || sessionID != _sessionID ||
            account.uid != _initial.account.uid || memcmp(account.uuid, _initial.account.uuid, sizeof(account.uuid))) {
            _revoked = YES; return;
        }
        _checkedAt = began;
    }
}

- (PLANKMacGraphicalIdentity)snapshot {
    @synchronized(self) {
        uint64_t now = authorityNow();
        if (_revoked || now < _checkedAt || now - _checkedAt >= MaximumObservationAge) {
            _revoked = YES; return (PLANKMacGraphicalIdentity){0};
        }
        return _initial;
    }
}

- (void)revoke { @synchronized(self) { _notified = YES; _revoked = YES; } }

- (void)dealloc {
    if (_watch) dispatch_source_cancel(_watch);
    for (id observer in _workspaceObservers)
        [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
}
@end
