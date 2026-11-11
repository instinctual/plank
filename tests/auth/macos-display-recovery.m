// SPDX-License-Identifier: GPL-3.0-or-later
// Link-time synthetic CG/IOKit/virtual-display substitutes; no real display,
// input, power assertion, account or WindowServer access.
#ifdef NDEBUG
#undef NDEBUG
#endif
#import "desktop-display.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <objc/runtime.h>
#include <assert.h>
#include <unistd.h>

static unsigned creations, applications, selections, wakes, releases, protections, unprotections, failedWakes;
static BOOL asleep, bootstrapAsleep, failProtection;
static unsigned rejectedCreations;
static BOOL online = YES, active = YES, authorized = YES, refuseMode, revokeOnWake;
static BOOL bootstrapActive = YES, failWake;
static CGDirectDisplayID bootstrapID = 43;
static unsigned pixelWidth = 3840, pixelHeight = 2160;
static unsigned currentScale = 1, configuredScale = 1;
static NSArray *registeredModes;

@interface FakeDescriptor : NSObject
@property(copy) NSString *name;
@property unsigned maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
@property(strong) dispatch_queue_t queue;
@end
@implementation FakeDescriptor
@end
@interface FakeMode : NSObject
@property unsigned width, height;
@property unsigned scale;
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height refreshRate:(double)rate;
@end
@implementation FakeMode
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height refreshRate:(double)rate {
    self = [super init]; if (self) { assert(rate == 60); _width = width; _height = height; _scale = 1; } return self;
}
@end
@interface FakeSettings : NSObject
@property unsigned hiDPI;
@property(strong) NSArray *modes;
@end
@implementation FakeSettings
@end
@interface FakeDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(readonly) unsigned displayID;
@end
@implementation FakeDisplay
- (instancetype)initWithDescriptor:(id)descriptor {
    if (rejectedCreations) { rejectedCreations--; return nil; }
    self = [super init]; if (self) {
        assert(!asleep && !bootstrapAsleep);
        assert([descriptor maxPixelsWide] == 8192 && [descriptor maxPixelsHigh] == 8192);
        creations++;
    } return self;
}
- (BOOL)applySettings:(id)settings {
    assert(settings && [settings hiDPI] <= 1 && active && !asleep);
    configuredScale = [settings hiDPI] ? 2 : 1;
    registeredModes = [settings modes];
    for (FakeMode *mode in registeredModes) mode.scale = configuredScale;
    assert(registeredModes.count >= 12 && registeredModes.count <= 13);
    applications++; online = YES; return YES;
}
- (unsigned)displayID { return 42; }
@end

// The fixture build renames NSClassFromString only in desktop-display.m.
Class PLANKTestClassFromString(NSString *name) {
    if ([name isEqual:@"CGVirtualDisplayDescriptor"]) return FakeDescriptor.class;
    if ([name isEqual:@"CGVirtualDisplayMode"]) return FakeMode.class;
    if ([name isEqual:@"CGVirtualDisplaySettings"]) return FakeSettings.class;
    if ([name isEqual:@"CGVirtualDisplay"]) return FakeDisplay.class;
    assert(!"unexpected class lookup"); return Nil;
}
CGDirectDisplayID CGMainDisplayID(void) { return bootstrapID; }
boolean_t CGDisplayIsAsleep(CGDirectDisplayID display) {
    assert(display == 42 || display == 43); return display == 42 ? asleep : bootstrapAsleep;
}
boolean_t CGDisplayIsActive(CGDirectDisplayID display) {
    assert(display == 42 || display == 43); return display == 42 ? active : bootstrapActive;
}
boolean_t CGDisplayIsOnline(CGDirectDisplayID display) { assert(display == 42); return online; }
boolean_t CGDisplayIsInMirrorSet(CGDirectDisplayID display) { assert(display == 42); return NO; }
size_t CGDisplayPixelsWide(CGDirectDisplayID display) { assert(display == 42); return pixelWidth; }
size_t CGDisplayPixelsHigh(CGDirectDisplayID display) { assert(display == 42); return pixelHeight; }
CGRect CGDisplayBounds(CGDirectDisplayID display) { assert(display == 42); return CGRectMake(0, 0, pixelWidth / currentScale, pixelHeight / currentScale); }
CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID display, CFDictionaryRef options) {
    assert(display == 42 && CFDictionaryGetValue(options, kCGDisplayShowDuplicateLowResolutionModes) == kCFBooleanTrue);
    return CFBridgingRetain(registeredModes);
}
CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID display) {
    assert(display == 42);
    FakeMode *mode = [[FakeMode alloc] initWithWidth:pixelWidth / currentScale height:pixelHeight / currentScale refreshRate:60];
    mode.scale = currentScale;
    return (CGDisplayModeRef)CFBridgingRetain(mode);
}
void CGDisplayModeRelease(CGDisplayModeRef mode) { CFRelease(mode); }
size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef mode) { FakeMode *m = (__bridge FakeMode *)mode; return m.width * m.scale; }
size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef mode) { FakeMode *m = (__bridge FakeMode *)mode; return m.height * m.scale; }
size_t CGDisplayModeGetWidth(CGDisplayModeRef mode) { return [(__bridge FakeMode *)mode width]; }
size_t CGDisplayModeGetHeight(CGDisplayModeRef mode) { return [(__bridge FakeMode *)mode height]; }
double CGDisplayModeGetRefreshRate(CGDisplayModeRef mode) { assert(mode); return 60; }
CGError CGDisplaySetDisplayMode(CGDirectDisplayID display, CGDisplayModeRef mode, CFDictionaryRef options) {
    assert(display == 42 && !options && active && !asleep); selections++;
    if (refuseMode) return kCGErrorFailure;
    pixelWidth = (unsigned)CGDisplayModeGetPixelWidth(mode);
    pixelHeight = (unsigned)CGDisplayModeGetPixelHeight(mode);
    currentScale = [(__bridge FakeMode *)mode scale];
    return kCGErrorSuccess;
}
IOReturn IOPMAssertionDeclareUserActivity(CFStringRef name, IOPMUserActiveType type, IOPMAssertionID *result) {
    assert(name && type == kIOPMUserActiveLocal && *result == kIOPMNullAssertionID);
    wakes++;
    if (failWake) { failedWakes++; return kIOReturnError; }
    *result = 19;
    if (revokeOnWake) authorized = NO;
    return kIOReturnSuccess;
}
IOReturn IOPMAssertionCreateWithName(CFStringRef type, IOPMAssertionLevel level, CFStringRef name, IOPMAssertionID *result) {
    assert(CFEqual(type, kIOPMAssertionTypePreventUserIdleDisplaySleep) && level == kIOPMAssertionLevelOn && name);
    assert(*result == kIOPMNullAssertionID && protections == unprotections);
    if (failProtection) return kIOReturnError;
    *result = 20; protections++; return kIOReturnSuccess;
}
IOReturn IOPMAssertionRelease(IOPMAssertionID value) {
    if (value == 19) releases++;
    else { assert(value == 20 && protections == unprotections + 1); unprotections++; }
    return kIOReturnSuccess;
}

static void step(PLANKMacDesktopDisplay *display, unsigned index) {
    assert(protections == unprotections);
    unsigned priorWake = wakes, priorRelease = releases;
    BOOL (^valid)(void) = ^BOOL { return authorized; };
    void (^next)(void) = ^{ dispatch_async(dispatch_get_main_queue(), ^{ step(display, index + 1); }); };
    switch (index) {
    case 0: {
        [display recoverWithValidity:valid completion:^(BOOL ok) { assert(ok && !creations && !wakes); next(); }]; break;
    }
    case 1: {
        [display prepareWidth:3840 height:2160 valid:valid completion:^(BOOL ok) {
            assert(ok && creations == 1 && display.displayID == 42); next();
        }]; break;
    }
    case 2: {
        [display recoverWithValidity:valid completion:^(BOOL ok) { assert(ok && wakes == priorWake && !selections); next(); }]; break;
    }
    case 3: {
        active = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ active = YES; });
        [display recoverWithValidity:valid completion:^(BOOL ok) {
            assert(ok && wakes == priorWake + 1 && releases == priorRelease + 1 && applications == 1 && pixelWidth == 3840); next();
        }]; break;
    }
    case 4: {
        [display prepareWidth:5120 height:2160 valid:valid completion:^(BOOL ok) { assert(ok); next(); }]; break;
    }
    case 5: {
        active = online = NO; pixelWidth = 3840;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ online = active = YES; });
        [display recoverWithValidity:valid completion:^(BOOL ok) {
            assert(ok && pixelWidth == 5120 && creations == 1 && applications == 1 && wakes == priorWake + 1 && releases == priorRelease + 1); next();
        }]; break;
    }
    case 6: {
        active = NO; authorized = NO;
        [display recoverWithValidity:valid completion:^(BOOL ok) { assert(!ok && wakes == priorWake); next(); }]; break;
    }
    case 7: {
        authorized = YES; revokeOnWake = YES;
        [display recoverWithValidity:valid completion:^(BOOL ok) {
            assert(!ok && !active && wakes == priorWake + 1 && releases == priorRelease + 1 && applications == 1); next();
        }]; break;
    }
    case 8: {
        authorized = YES; revokeOnWake = NO; refuseMode = YES;
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + .15;
        [display recoverWithValidity:^BOOL { return NSProcessInfo.processInfo.systemUptime < deadline; }
            completion:^(BOOL ok) { assert(!ok && !active && wakes == priorWake + 1 && releases == priorRelease + 1); next(); }];
        // Another request cannot race an in-progress recovery.
        [display recoverWithValidity:valid completion:^(BOOL ok) { assert(!ok && wakes == priorWake + 1); }]; break;
    }
    case 9: {
        refuseMode = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ active = YES; });
        [display recoverWithValidity:valid completion:^(BOOL ok) {
            assert(ok && creations == 1 && pixelWidth == 5120 && wakes == releases);
            next();
        }]; break;
    }
    case 10: {
        active = online = NO;
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + .15;
        unsigned priorSelections = selections;
        [display recoverWithValidity:^BOOL { return NSProcessInfo.processInfo.systemUptime < deadline; }
            completion:^(BOOL ok) {
                assert(!ok && applications == 1 && creations == 1 && selections == priorSelections);
                assert(wakes == releases);
                next();
            }]; break;
    }
    case 11: {
        bootstrapActive = NO;
        unsigned priorWake = wakes, priorRelease = releases, priorSelect = selections;
        PLANKMacDesktopDisplay *fresh = [PLANKMacDesktopDisplay new];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ bootstrapActive = YES; });
        [fresh recoverWithValidity:valid completion:^(BOOL ok) {
            assert(ok && !fresh.displayID && creations == 1 && applications == 1 && selections == priorSelect);
            assert(wakes == priorWake + 1 && releases == priorRelease + 1); next();
        }];
        [fresh recoverWithValidity:valid completion:^(BOOL ok) { assert(!ok && wakes == priorWake + 1); }];
        break;
    }
    case 12: {
        authorized = NO; bootstrapActive = NO;
        unsigned priorWake = wakes;
        [[PLANKMacDesktopDisplay new] recoverWithValidity:valid completion:^(BOOL ok) {
            assert(!ok && wakes == priorWake); next();
        }]; break;
    }
    case 13: {
        authorized = YES; revokeOnWake = YES;
        unsigned priorRelease = releases;
        [[PLANKMacDesktopDisplay new] recoverWithValidity:valid completion:^(BOOL ok) {
            assert(!ok && releases == priorRelease + 1 && creations == 1); next();
        }]; break;
    }
    case 14: {
        authorized = YES; revokeOnWake = NO;
        unsigned priorRelease = releases;
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + .15;
        [[PLANKMacDesktopDisplay new] recoverWithValidity:^BOOL { return NSProcessInfo.processInfo.systemUptime < deadline; }
            completion:^(BOOL ok) { assert(!ok && releases == priorRelease + 1); next(); }]; break;
    }
    case 15: {
        bootstrapID = 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            bootstrapID = 43; bootstrapActive = YES;
        });
        [[PLANKMacDesktopDisplay new] recoverWithValidity:valid completion:^(BOOL ok) {
            assert(ok && creations == 1 && applications == 1); next();
        }]; break;
    }
    case 16: {
        failWake = YES; bootstrapActive = NO;
        unsigned priorRelease = releases;
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + .15;
        [[PLANKMacDesktopDisplay new] recoverWithValidity:^BOOL { return NSProcessInfo.processInfo.systemUptime < deadline; }
            completion:^(BOOL ok) { assert(!ok && releases == priorRelease); next(); }]; break;
    }
    case 17: {
        failWake = NO; bootstrapID = 0;
        unsigned priorRelease = releases;
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        [[PLANKMacDesktopDisplay new] recoverWithValidity:valid completion:^(BOOL ok) {
            assert(!ok && NSProcessInfo.processInfo.systemUptime - started < 3);
            assert(releases == priorRelease + 1 && creations == 1 && applications == 1);
            next();
        }]; break;
    }
    case 18: {
        online = active = YES;
        [display prepareWidth:3024 height:1964 valid:valid completion:^(BOOL ok) {
            assert(ok && pixelWidth == 3024 && pixelHeight == 1964 && applications == 2); next();
        }]; break;
    }
    case 19: {
        online = active = NO;
        unsigned previous = applications;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            assert(applications == previous); online = active = YES;
        });
        [display prepareWidth:3456 height:2234 valid:valid completion:^(BOOL ok) {
            assert(ok && pixelWidth == 3456 && pixelHeight == 2234 && applications == previous + 1); next();
        }]; break;
    }
    case 20: {
        [display prepareWidth:3456 height:2234 valid:valid completion:^(BOOL ok) {
            assert(ok && applications == 3); next();
        }]; break;
    }
    case 21: {
        assert(!PLANKMacDesktopModeSupported(3023, 1964));
        assert(!PLANKMacDesktopModeSupported(3024, 1963));
        assert(!PLANKMacDesktopModeSupported(8194, 2160));
        assert(!PLANKMacDesktopModeSupported(3840, 8194));
        assert(!PLANKMacDesktopModeSupported(0, 0));
        assert(PLANKMacDesktopModeSupported(8192, 8192));
        [display prepareWidth:3023 height:1964 valid:valid completion:^(BOOL ok) {
            assert(!ok && applications == 3); next();
        }]; break;
    }
    case 22: {
        [[PLANKMacDesktopDisplay new] prepareWidth:2880 height:1864 valid:valid completion:^(BOOL ok) {
            assert(ok && pixelWidth == 2880 && pixelHeight == 1864 && applications == 4);
            next();
        }]; break;
    }
    case 23: {
        [display prepareWidth:3420 height:2214 scale:2 valid:valid completion:^(BOOL ok) {
            assert(ok && pixelWidth == 3420 && pixelHeight == 2214 && currentScale == 2);
            assert(CGDisplayBounds(42).size.height == 1107); next();
        }]; break;
    }
    case 24: {
        unsigned before = applications;
        active = online = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            assert(applications == before); online = active = YES;
        });
        [display recoverWithValidity:valid completion:^(BOOL ok) {
            assert(ok && currentScale == 2 && pixelWidth == 3420 && applications == before); next();
        }]; break;
    }
    case 25: {
        // Same pixel dimensions, different logical mode: must not accept 2x.
        [display prepareWidth:3420 height:2214 valid:valid completion:^(BOOL ok) {
            assert(ok && currentScale == 1 && CGDisplayBounds(42).size.height == 2214); next();
        }]; break;
    }
    case 26: {
        unsigned before = applications;
        [display prepareWidth:3420 height:2214 scale:3 valid:valid completion:^(BOOL ok) {
            assert(!ok && applications == before); next();
        }]; break;
    }
    case 27: {
        [display prepareWidth:5120 height:2160 scale:2 valid:valid completion:^(BOOL ok) {
            assert(ok && currentScale == 2 && pixelWidth == 5120 && CGDisplayBounds(42).size.width == 2560);
            next();
        }]; break;
    }
    case 28: {
        [display prepareWidth:1920 height:1080 valid:valid completion:^(BOOL ok) {
            assert(ok && currentScale == 1 && pixelWidth == 1920);
            next();
        }]; break;
    }
    case 29: {
        // Online/active is not proof of wake. Never mutate a sleeping output,
        // including a HiDPI/custom-mode reconfiguration.
        asleep = YES;
        unsigned before = applications, beforeSelect = selections;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            assert(applications == before && selections == beforeSelect); asleep = NO;
        });
        [display prepareWidth:3456 height:2160 scale:2 valid:valid completion:^(BOOL ok) {
            assert(ok && currentScale == 2 && pixelWidth == 3456 && applications == before + 1);
            next();
        }]; break;
    }
    case 30: {
        // Wake the local bootstrap display before creating a fresh virtual one.
        bootstrapID = 43; bootstrapActive = YES; bootstrapAsleep = YES;
        unsigned before = creations;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            assert(creations == before); bootstrapAsleep = NO;
        });
        [[PLANKMacDesktopDisplay new] prepareWidth:3840 height:2160 valid:valid completion:^(BOOL ok) {
            assert(ok && creations == before + 1); next();
        }]; break;
    }
    case 31: {
        // WindowServer may retire the old fixed identity only after wake.
        // Retry that identity, without creating extra displays or worker exits.
        rejectedCreations = 2;
        unsigned before = creations;
        [[PLANKMacDesktopDisplay new] prepareWidth:5120 height:2160 valid:valid completion:^(BOOL ok) {
            assert(ok && !rejectedCreations && creations == before + 1); next();
        }]; break;
    }
    case 32: {
        rejectedCreations = 100;
        unsigned before = creations;
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + .3;
        [[PLANKMacDesktopDisplay new] prepareWidth:5120 height:2160 valid:^BOOL {
            return NSProcessInfo.processInfo.systemUptime < deadline;
        } completion:^(BOOL ok) {
            assert(!ok && creations == before && rejectedCreations >= 98); next();
        }]; break;
    }
    case 33: {
        rejectedCreations = 0; failWake = YES;
        unsigned before = applications;
        [display prepareWidth:1920 height:1080 valid:valid completion:^(BOOL ok) {
            assert(!ok && applications == before && releases == priorRelease); next();
        }]; break;
    }
    case 34: {
        failWake = NO; failProtection = YES;
        unsigned before = applications;
        [display prepareWidth:1920 height:1080 valid:valid completion:^(BOOL ok) {
            assert(!ok && applications == before && wakes == priorWake); next();
        }]; break;
    }
    case 35: {
        failProtection = NO; asleep = YES;
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + .2;
        unsigned before = applications;
        [display prepareWidth:1920 height:1080 valid:^BOOL {
            return NSProcessInfo.processInfo.systemUptime < deadline;
        } completion:^(BOOL ok) {
            assert(!ok && applications == before && wakes == releases + failedWakes && protections == unprotections);
            puts("macos_display_recovery=pass checks=36 synthetic_only=1 wake_before_modes=1 sleep_cleanup=1"); exit(0);
        }]; break;
    }
    default: abort();
    }
}
int main(void) {
    alarm(20);
    @autoreleasepool {
        PLANKMacDesktopDisplay *display = [[PLANKMacDesktopDisplay alloc] initForSignIn];
        dispatch_async(dispatch_get_main_queue(), ^{ step(display, 0); });
        [[NSRunLoop mainRunLoop] run];
    }
    return 1;
}
