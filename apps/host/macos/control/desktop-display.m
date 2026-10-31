// SPDX-License-Identifier: GPL-3.0-or-later
#import "desktop-display.h"
#import "display-layout.h"
#import <objc/runtime.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
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
- (BOOL)createWidth:(unsigned)width height:(unsigned)height scale:(unsigned)scale {
    if (!supportedAPI()) { NSLog(@"PLANK virtual display API signature unavailable"); return NO; }
    PLANKMacDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.name = _signIn ? @"PLANK Sign In" : @"PLANK Desktop";
    descriptor.maxPixelsWide = 8192;
    descriptor.maxPixelsHigh = 8192;
    descriptor.sizeInMillimeters = CGSizeMake(600, 340);
    descriptor.vendorID = 0xF0F0; descriptor.productID = 2; descriptor.serialNum = _signIn ? 2 : 1;
    descriptor.queue = dispatch_get_main_queue();
    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!_display) { NSLog(@"PLANK virtual display descriptor rejected"); return NO; }
    if (![self applyModesWidth:width height:height scale:scale]) { _display = nil; return NO; }
    atomic_store(&_displayID, _display.displayID);
    return self.displayID != kCGNullDirectDisplay;
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
    if (_busy || !valid || !valid() ||
            (_display && (!self.displayID || !_readyWidth || !_readyHeight))) {
        completion(NO); return;
    }
    BOOL localDesktop = !_display || (self.mirrorHostDisplays && !_layout.pending);
    CGDirectDisplayID target = localDesktop ? CGMainDisplayID() : self.displayID;
    if (target && CGDisplayIsActive(target)) { completion(YES); return; }
    NSLog(@"PLANK authenticated display recovery starting: owned=%d", _display != nil);
    // Report an authenticated remote user, not a synthetic keyboard/mouse event.
    // No global power preference or permanent sleep assertion is installed.
    IOPMAssertionID activity = kIOPMNullAssertionID;
    IOReturn wake = IOPMAssertionDeclareUserActivity(CFSTR("PLANK authenticated display recovery"),
                                                   kIOPMUserActiveRemote, &activity);
    if (wake != kIOReturnSuccess) NSLog(@"PLANK display wake request failed: %d", wake);
    // Never reapply CGVirtualDisplay settings to an existing offline output.
    // SDK/OS 27 can abort WindowServer in GenerateModeListForDisplay on that
    // path. Wake asynchronously, then wait for the same output to return; the
    // bounded prepare loop only selects modes once it is online. Do not create
    // a duplicate output or claim recovery of a permanently removed display.
    if (!valid()) {
        if (activity != kIOPMNullAssertionID) IOPMAssertionRelease(activity);
        completion(NO); return;
    }
    if (localDesktop) {
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
            BOOL ready = allowed && current && CGDisplayIsActive(current);
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
    [self prepareWidth:_readyWidth height:_readyHeight scale:_readyScale valid:valid completion:^(BOOL ready) {
        if (activity != kIOPMNullAssertionID) IOPMAssertionRelease(activity);
        NSLog(@"PLANK owned display recovery %@", ready ? @"ready" : @"not ready");
        completion(ready);
    }];
}
- (BOOL)selectWidth:(unsigned)width height:(unsigned)height scale:(unsigned)scale {
    CGDirectDisplayID display = self.displayID;
    if (!CGDisplayIsOnline(display) || CGDisplayIsInMirrorSet(display)) return NO;
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
    if (self.mirrorHostDisplays && !_signIn) {
        if (!_layout) _layout = [PLANKMacDisplayLayout new];
        if (![_layout beginExcludingDisplay:self.displayID]) { _layoutNeedsRetirement = YES; completion(NO); return; }
    }
    if (!_display && ![self createWidth:width height:height scale:scale]) {
        if (_layout) _layoutNeedsRetirement = YES;
        [self restoreLayout]; completion(NO); return;
    }
    _busy = YES;
    NSLog(@"PLANK desktop mode preparing: %ux%u scale=%u display=%u", width, height, scale, self.displayID);
    __block BOOL selected = NO, consolidated = NO, attempted = NO, adopted = !_layout;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 6;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC, 5*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        BOOL allowed = valid();
        CGDirectDisplayID display = self.displayID;
        // Creation returns an ID before WindowServer necessarily exposes its
        // UUID. Wait inside the existing bounded preparation loop; never change
        // modes or consolidate physical screens before ownership is identified.
        if (allowed && !adopted && CGDisplayIsOnline(display))
            adopted = [_layout adoptDisplay:display];
        if (allowed && adopted && !selected) selected = [self selectWidth:width height:height scale:scale];
        if (allowed && selected && _layout.pending && !attempted) {
            attempted = YES; consolidated = [_layout activateDisplay:display];
        }
        if (attempted && !consolidated) allowed = NO;
        BOOL ready = allowed && selected && (!_layout.pending || (consolidated && [_layout matchesDisplay:display])) &&
            CGDisplayIsActive(display) && currentModeMatches(display, width, height, scale);
        if (ready || !allowed || NSProcessInfo.processInfo.systemUptime >= deadline) {
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
                if (!adopted) self->_layoutNeedsRetirement = YES;
                if (![self restoreLayout]) NSLog(@"PLANK display mirroring restoration requires worker retirement");
                NSLog(@"PLANK desktop mode not ready: identified=%d selected=%d authorized=%d", adopted, selected, allowed);
            }
            completion(ready);
        }
    });
    dispatch_resume(timer);
}
@end
