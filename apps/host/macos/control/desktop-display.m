// SPDX-License-Identifier: GPL-3.0-or-later
#import "desktop-display.h"
#import "display-layout.h"
#import "display-power.h"
#import <objc/runtime.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>

// Undocumented surface isolated here, with exact SDK-27 runtime signature
// checks. No older-OS paths and no permission or capture bypass.
@interface PLANKMacDisplayDescriptor : NSObject
@property(copy) NSString *name;
@property unsigned maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
@property(strong) dispatch_queue_t queue;
@end
@interface PLANKMacDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height refreshRate:(double)rate;
@end
@interface PLANKMacDisplaySettings : NSObject
@property unsigned hiDPI;
@property(strong) NSArray *modes;
@end
@interface PLANKMacVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(readonly) unsigned displayID;
@end

static const unsigned modes[][2] = {
    {1024,2160}, {1280,2160}, {1920,1080}, {1920,1200}, {2560,1440},
    {2560,1600}, {2560,2160}, {3440,1440}, {3840,1600}, {3840,2160},
    {4096,2160}, {5120,2160}
};
BOOL PLANKMacDesktopModeSupported(unsigned width, unsigned height) {
    return width >= 2 && height >= 2 && width <= 8192 && height <= 8192 &&
        !(width & 1) && !(height & 1);
}
static BOOL presetMode(unsigned width, unsigned height) {
    for (size_t i = 0; i < sizeof(modes)/sizeof(modes[0]); ++i)
        if (modes[i][0] == width && modes[i][1] == height) return YES;
    return NO;
}
static BOOL displayAwake(CGDirectDisplayID display) {
    return display && CGDisplayIsActive(display) && !CGDisplayIsAsleep(display);
}
static IOPMAssertionID wakeDisplay(void) {
    IOPMAssertionID activity = kIOPMNullAssertionID;
    // A remote operator is using the console, not merely a network service.
    // Match real remote input's console wake, without posting any input event.
    IOReturn result = IOPMAssertionDeclareUserActivity(CFSTR("PLANK authenticated display preparation"),
        kIOPMUserActiveLocal, &activity);
    if (result != kIOReturnSuccess) NSLog(@"PLANK display wake request failed: %d", result);
    return activity;
}
typedef NS_ENUM(unsigned, PLANKDisplayCreation) {
    PLANKDisplayCreated, PLANKDisplayCreationPending, PLANKDisplayCreationFailed
};
static BOOL currentModeMatches(CGDirectDisplayID display, unsigned width, unsigned height, unsigned scale) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) return NO;
    BOOL matches = CGDisplayModeGetPixelWidth(mode) == width && CGDisplayModeGetPixelHeight(mode) == height &&
        CGDisplayModeGetWidth(mode) == width / scale && CGDisplayModeGetHeight(mode) == height / scale &&
        CGDisplayBounds(display).size.width == width / scale && CGDisplayBounds(display).size.height == height / scale;
    CGDisplayModeRelease(mode);
    return matches;
}
static BOOL signature(NSString *name, NSString *selector, const char *encoding) {
    Method method = class_getInstanceMethod(NSClassFromString(name), NSSelectorFromString(selector));
    return method && !strcmp(method_getTypeEncoding(method), encoding);
}
static BOOL supportedAPI(void) {
    for (NSString *s in @[@"setName:", @"setQueue:"])
        if (!signature(@"CGVirtualDisplayDescriptor", s, "v24@0:8@16")) return NO;
    for (NSString *s in @[@"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setVendorID:", @"setProductID:", @"setSerialNum:"])
        if (!signature(@"CGVirtualDisplayDescriptor", s, "v20@0:8I16")) return NO;
    return signature(@"CGVirtualDisplayDescriptor", @"setSizeInMillimeters:", "v32@0:8{CGSize=dd}16") &&
        signature(@"CGVirtualDisplayMode", @"initWithWidth:height:refreshRate:", "@32@0:8I16I20d24") &&
        signature(@"CGVirtualDisplaySettings", @"setHiDPI:", "v20@0:8I16") &&
        signature(@"CGVirtualDisplaySettings", @"setModes:", "v24@0:8@16") &&
        signature(@"CGVirtualDisplay", @"initWithDescriptor:", "@24@0:8@16") &&
        signature(@"CGVirtualDisplay", @"applySettings:", "B24@0:8@16") &&
        signature(@"CGVirtualDisplay", @"displayID", "I16@0:8");
}

@implementation PLANKMacDesktopDisplay {
    PLANKMacVirtualDisplay *_display;
    PLANKMacDisplayLayout *_layout;
    BOOL _layoutNeedsRetirement;
    atomic_uint _displayID;
    BOOL _busy;
    BOOL _signIn;
    unsigned _readyWidth, _readyHeight;
    unsigned _dynamicWidth, _dynamicHeight;
    unsigned _configuredScale, _readyScale;
}
- (instancetype)initForSignIn {
    self = [super init];
    if (self) _signIn = YES;
    return self;
}
- (CGDirectDisplayID)displayID { return atomic_load(&_displayID); }
- (BOOL)restoreLayout {
    BOOL restored = !_layout || [_layout restore];
    return restored && !_layoutNeedsRetirement;
}
- (PLANKDisplayCreation)createWidth:(unsigned)width height:(unsigned)height scale:(unsigned)scale {
    if (!supportedAPI()) { NSLog(@"PLANK virtual display API signature unavailable"); return PLANKDisplayCreationFailed; }
    PLANKMacDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.name = _signIn ? @"PLANK Sign In" : @"PLANK Desktop";
    descriptor.maxPixelsWide = 8192;
    descriptor.maxPixelsHigh = 8192;
    descriptor.sizeInMillimeters = CGSizeMake(600, 340);
    descriptor.vendorID = 0xF0F0; descriptor.productID = 2; descriptor.serialNum = _signIn ? 2 : 1;
    descriptor.queue = dispatch_get_main_queue();
    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    // Wake can retire an old registration asynchronously. Retry the same
    // identity within preparation's deadline; never add a replacement monitor
    // with a different serial or disturb another display owner.
    if (!_display) return PLANKDisplayCreationPending;
    if (![self applyModesWidth:width height:height scale:scale]) { _display = nil; return PLANKDisplayCreationFailed; }
    atomic_store(&_displayID, _display.displayID);
    return self.displayID != kCGNullDirectDisplay ? PLANKDisplayCreated : PLANKDisplayCreationFailed;
}
- (BOOL)applyModesWidth:(unsigned)width height:(unsigned)height scale:(unsigned)scale {
    NSMutableArray *available = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(modes)/sizeof(modes[0]); ++i) {
        id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
            initWithWidth:modes[i][0] / scale height:modes[i][1] / scale refreshRate:60];
        if (!mode) return NO;
        [available addObject:mode];
    }
    if (!presetMode(width, height)) {
        id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
            initWithWidth:width / scale height:height / scale refreshRate:60];
        if (!mode) return NO;
        [available addObject:mode];
    }
    PLANKMacDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = scale == 2; settings.modes = available;
    if (![_display applySettings:settings]) { NSLog(@"PLANK virtual display modes rejected"); return NO; }
    // Keep only the current custom mode, not an ever-growing session history.
    _dynamicWidth = width; _dynamicHeight = height;
    _configuredScale = scale;
    return YES;
}
- (void)recoverWithValidity:(BOOL (^)(void))valid completion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"Display recovery belongs to the graphical main queue");
    if (!completion) return;
    if (_busy || !valid || !valid() || (_display && !self.displayID)) {
        completion(NO); return;
    }
    // A cancelled first preparation may own a display without a verified mode.
    // Wake the desktop so topology can be read and preparation retried; do not
    // invent a last-known mode or permanently block subsequent connections.
    BOOL localDesktop = !_display || !_readyWidth || !_readyHeight ||
        (self.mirrorHostDisplays && !_layout.pending);
    CGDirectDisplayID target = localDesktop ? CGMainDisplayID() : self.displayID;
    if (displayAwake(target)) { completion(YES); return; }
    NSLog(@"PLANK authenticated display recovery starting: owned=%d", _display != nil);
    if (!localDesktop) {
        [self prepareWidth:_readyWidth height:_readyHeight scale:_readyScale valid:valid completion:^(BOOL ready) {
            NSLog(@"PLANK owned display recovery %@", ready ? @"ready" : @"not ready");
            completion(ready);
        }];
        return;
    }
    IOPMAssertionID activity = wakeDisplay();
    // Never reapply CGVirtualDisplay settings to an existing offline output.
    // SDK/OS 27 can abort WindowServer in GenerateModeListForDisplay on that
    // path. Wake asynchronously, then wait for the same output to return; the
    // bounded prepare loop only selects modes once it is online and awake. Do not create
    // a duplicate output or claim recovery of a permanently removed display.
    if (!valid()) {
        if (activity != kIOPMNullAssertionID) IOPMAssertionRelease(activity);
        completion(NO); return;
    }
    // Before the first bookmark preparation there is no owned virtual
    // output. Topology must first describe the existing desktop so the
    // Client can request preparation. Wake only; never change a physical
    // mode or invent a bootstrap resolution to break that dependency.
    _busy = YES;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2.5;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC, 5*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        BOOL allowed = valid();
        CGDirectDisplayID current = CGMainDisplayID();
        BOOL ready = allowed && displayAwake(current);
        if (ready || !allowed || NSProcessInfo.processInfo.systemUptime >= deadline) {
            dispatch_source_cancel(timer);
            dispatch_source_set_event_handler(timer, nil);
            self->_busy = NO;
            if (activity != kIOPMNullAssertionID) IOPMAssertionRelease(activity);
            NSLog(@"PLANK bootstrap display recovery %@", ready ? @"ready" : @"not ready");
            completion(ready);
        }
    });
    dispatch_resume(timer);
    return;
}
- (BOOL)selectWidth:(unsigned)width height:(unsigned)height scale:(unsigned)scale {
    CGDirectDisplayID display = self.displayID;
    if (!CGDisplayIsOnline(display) || !displayAwake(display) || CGDisplayIsInMirrorSet(display)) return NO;
    if (_configuredScale != scale ||
        (!presetMode(width, height) && (_dynamicWidth != width || _dynamicHeight != height))) {
        if (![self applyModesWidth:width height:height scale:scale]) return NO;
        // Settings can temporarily take the output offline. Wait for the next
        // bounded poll; never apply settings while it is offline.
        return NO;
    }
    // Mode objects can appear after the bootstrap canvas becomes active.
    // Already-correct geometry needs no mode switch in either graphical role.
    if (CGDisplayIsActive(display) && currentModeMatches(display, width, height, scale)) return YES;
    CFArrayRef available = CGDisplayCopyAllDisplayModes(display,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    BOOL selected = NO;
    if (available && CFArrayGetCount(available) < 128) {
        for (CFIndex i = 0; i < CFArrayGetCount(available); ++i) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(available, i);
            if (CGDisplayModeGetPixelWidth(mode) == width && CGDisplayModeGetPixelHeight(mode) == height &&
                CGDisplayModeGetWidth(mode) == width / scale && CGDisplayModeGetHeight(mode) == height / scale &&
                fabs(CGDisplayModeGetRefreshRate(mode) - 60) < .01) {
                selected = CGDisplaySetDisplayMode(display, mode, NULL) == kCGErrorSuccess;
                break;
            }
        }
    }
    if (available) CFRelease(available);
    return selected;
}
- (void)prepareWidth:(unsigned)width height:(unsigned)height
              valid:(BOOL (^)(void))valid completion:(void (^)(BOOL))completion {
    [self prepareWidth:width height:height scale:1 valid:valid completion:completion];
}
- (void)prepareWidth:(unsigned)width height:(unsigned)height scale:(unsigned)scale
              valid:(BOOL (^)(void))valid completion:(void (^)(BOOL))completion {
    NSAssert(NSThread.isMainThread, @"Display mutation belongs to the graphical main queue");
    if (_busy || !valid || !completion || !valid() || (scale != 1 && scale != 2) || !PLANKMacDesktopModeSupported(width, height)) {
        if (completion) completion(NO); return;
    }
    _busy = YES;
    // Wake first, even when Quartz still calls a sleeping/stale output online.
    // Hold idle-sleep protection for the whole bounded preparation. Streaming
    // takes its own assertion; no idle Host or unauthenticated probe owns one.
    IOPMAssertionID protection = PLANKMacPreventIdleDisplaySleep(CFSTR("PLANK display preparation"));
    IOPMAssertionID activity = protection != kIOPMNullAssertionID ? wakeDisplay() : kIOPMNullAssertionID;
    if (protection == kIOPMNullAssertionID || activity == kIOPMNullAssertionID || !valid()) {
        PLANKMacReleaseDisplayAssertion(&activity);
        PLANKMacReleaseDisplayAssertion(&protection);
        _busy = NO; completion(NO); return;
    }
    NSLog(@"PLANK desktop mode preparing: %ux%u scale=%u display=%u", width, height, scale, self.displayID);
    __block BOOL initialized = NO, selected = NO, consolidated = NO, attempted = NO, adopted = NO;
    __block unsigned creationAttempts = 0;
    __block NSTimeInterval nextCreation = 0;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 6;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC), 50*NSEC_PER_MSEC, 5*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        BOOL allowed = valid();
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (allowed && !initialized) {
            BOOL localDesktop = !self->_display || (self.mirrorHostDisplays && !self->_layout.pending);
            CGDirectDisplayID target = localDesktop ? CGMainDisplayID() : self.displayID;
            // A genuinely headless first launch has no output to wait for.
            // Existing outputs must wake before layout snapshots or changes.
            if (!target || displayAwake(target)) {
                initialized = YES;
                if (self.mirrorHostDisplays && !self->_signIn) {
                    if (!self->_layout) self->_layout = [PLANKMacDisplayLayout new];
                    if (![self->_layout beginExcludingDisplay:self.displayID]) {
                        self->_layoutNeedsRetirement = YES; allowed = NO;
                    }
                }
                adopted = !self->_layout;
            }
        }
        if (allowed && initialized && !self->_display && now >= nextCreation) {
            creationAttempts++;
            PLANKDisplayCreation result = [self createWidth:width height:height scale:scale];
            if (result == PLANKDisplayCreationFailed) allowed = NO;
            nextCreation = now + .25;
        }
        CGDirectDisplayID display = self.displayID;
        // Creation returns an ID before WindowServer necessarily exposes its
        // UUID. Wait inside the existing bounded preparation loop; never change
        // modes or consolidate physical screens before ownership is identified.
        if (allowed && initialized && display && !adopted && CGDisplayIsOnline(display))
            adopted = [_layout adoptDisplay:display];
        if (allowed && initialized && display && adopted && !selected) selected = [self selectWidth:width height:height scale:scale];
        if (allowed && selected && _layout.pending && !attempted) {
            attempted = YES; consolidated = [_layout activateDisplay:display];
        }
        if (attempted && !consolidated) allowed = NO;
        BOOL ready = allowed && selected && (!_layout.pending || (consolidated && [_layout matchesDisplay:display])) &&
            displayAwake(display) && currentModeMatches(display, width, height, scale);
        if (ready || !allowed || now >= deadline) {
            dispatch_source_cancel(timer);
            dispatch_source_set_event_handler(timer, nil);
            self->_busy = NO;
            if (ready) {
                self->_readyWidth = width; self->_readyHeight = height;
                self->_readyScale = scale;
                NSLog(@"PLANK desktop mode ready: %ux%u scale=%u", width, height, scale);
            }
            else {
                // Without a verified UUID the output cannot safely be parked
                // during restoration. Retiring its owner releases it instead.
                if (self->_layout && initialized && !adopted) self->_layoutNeedsRetirement = YES;
                if (![self restoreLayout]) NSLog(@"PLANK display mirroring restoration requires worker retirement");
                NSLog(@"PLANK desktop mode not ready: initialized=%d identified=%d selected=%d authorized=%d creation-attempts=%u awake=%d",
                    initialized, adopted, selected, allowed, creationAttempts, displayAwake(display));
            }
            IOPMAssertionID wakeAssertion = activity, sleepAssertion = protection;
            PLANKMacReleaseDisplayAssertion(&wakeAssertion);
            PLANKMacReleaseDisplayAssertion(&sleepAssertion);
            completion(ready);
        }
    });
    dispatch_resume(timer);
}
@end
