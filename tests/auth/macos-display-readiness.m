// SPDX-License-Identifier: GPL-3.0-or-later
// Production preparation + layout, with every Quartz/virtual-display call
// substituted. No real displays, capture, input or WindowServer mutation.
#import "desktop-display.h"
#import <ColorSync/ColorSync.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <stdlib.h>

static unsigned checks, creations, activations, selections, commits, virtualIdentityQueries, createdSerial;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL line=%d: %s\n",__LINE__,#x); exit(1); } } while (0)
static NSMutableDictionary *screens, *transaction;
static NSArray *available;
static BOOL online, identified, authorized;
static unsigned identity;
static CGDirectDisplayID mainID;

@interface TestMode : NSObject
@property unsigned width, height;
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height refreshRate:(double)rate;
@end
@implementation TestMode
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height refreshRate:(double)rate {
    self = [super init]; if (self) { CHECK(rate == 60); _width = width; _height = height; } return self;
}
@end
static TestMode *mode(unsigned w, unsigned h) { return [[TestMode alloc] initWithWidth:w height:h refreshRate:60]; }
static NSMutableDictionary *screen(unsigned w, unsigned h, int x) {
    return [@{@"mode":mode(w,h), @"x":@(x), @"y":@0, @"mirror":@0} mutableCopy];
}
@interface TestDescriptor : NSObject
@property(copy) NSString *name;
@property unsigned maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
@property(strong) dispatch_queue_t queue;
@end
@implementation TestDescriptor
@end
@interface TestSettings : NSObject
@property unsigned hiDPI;
@property(strong) NSArray *modes;
@end
@implementation TestSettings
@end
@interface TestDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(readonly) unsigned displayID;
@end
@implementation TestDisplay
- (instancetype)initWithDescriptor:(id)descriptor {
    self = [super init];
    if (self) { CHECK(descriptor != nil); creations++; createdSerial = [descriptor serialNum]; }
    return self;
}
- (BOOL)applySettings:(id)settings {
    CHECK([settings hiDPI] == 0); available = [settings modes];
    screens[@7] = screen(1920,1080,screens[@1] ? 4480 : 0);
    if (!mainID) mainID = 7;
    return YES;
}
- (unsigned)displayID { return 7; }
@end
Class PLANKTestClassFromString(NSString *name) {
    if ([name isEqual:@"CGVirtualDisplayDescriptor"]) return TestDescriptor.class;
    if ([name isEqual:@"CGVirtualDisplayMode"]) return TestMode.class;
    if ([name isEqual:@"CGVirtualDisplaySettings"]) return TestSettings.class;
    if ([name isEqual:@"CGVirtualDisplay"]) return TestDisplay.class;
    CHECK(NO); return Nil;
}
CGError CGGetOnlineDisplayList(uint32_t capacity, CGDirectDisplayID *list, uint32_t *count) {
    NSMutableArray *ids = [NSMutableArray new];
    for (NSNumber *d in [screens.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if (d.unsignedIntValue != 7 || online) [ids addObject:d];
    *count = (uint32_t)ids.count;
    if (list) { CHECK(capacity >= ids.count); for (unsigned i=0;i<ids.count;i++) list[i]=[ids[i] unsignedIntValue]; }
    return kCGErrorSuccess;
}
CFUUIDRef CGDisplayCreateUUIDFromDisplayID(uint32_t d) {
    CFUUIDRef result = NULL;
    if (d == 7) virtualIdentityQueries++;
    if (screens[@(d)] && (d != 7 || identified))
        result = CFUUIDCreateFromString(NULL, (__bridge CFStringRef)[NSString stringWithFormat:@"00000000-0000-0000-0000-%012u",d == 7 ? identity : d]);
    return result;
}
CGDirectDisplayID CGMainDisplayID(void) { return mainID; }
CGDirectDisplayID CGDisplayMirrorsDisplay(CGDirectDisplayID d) { return [screens[@(d)][@"mirror"] unsignedIntValue]; }
boolean_t CGDisplayIsAlwaysInMirrorSet(CGDirectDisplayID d) { (void)d; return false; }
boolean_t CGDisplayIsOnline(CGDirectDisplayID d) { return screens[@(d)] && (d != 7 || online); }
boolean_t CGDisplayIsActive(CGDirectDisplayID d) { return CGDisplayIsOnline(d); }
boolean_t CGDisplayIsInMirrorSet(CGDirectDisplayID d) {
    if (CGDisplayMirrorsDisplay(d)) return true;
    for (NSDictionary *s in screens.allValues) if ([s[@"mirror"] unsignedIntValue] == d) return true;
    return false;
}
CGRect CGDisplayBounds(CGDirectDisplayID d) {
    NSDictionary *s = screens[@(d)]; TestMode *m=s[@"mode"];
    return CGRectMake([s[@"x"] intValue],[s[@"y"] intValue],m.width,m.height);
}
CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID d) { return (CGDisplayModeRef)CFBridgingRetain(screens[@(d)][@"mode"]); }
void CGDisplayModeRelease(CGDisplayModeRef m) { if (m) CFRelease(m); }
size_t CGDisplayModeGetWidth(CGDisplayModeRef m) { return [(__bridge TestMode *)m width]; }
size_t CGDisplayModeGetHeight(CGDisplayModeRef m) { return [(__bridge TestMode *)m height]; }
size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef m) { return CGDisplayModeGetWidth(m); }
size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef m) { return CGDisplayModeGetHeight(m); }
double CGDisplayModeGetRefreshRate(CGDisplayModeRef m) { (void)m; return 60; }
int32_t CGDisplayModeGetIODisplayModeID(CGDisplayModeRef m) { return (int32_t)(CGDisplayModeGetWidth(m)*10000+CGDisplayModeGetHeight(m)); }
CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID d,CFDictionaryRef options) { CHECK(d==7 && options); return CFBridgingRetain(available); }
CGError CGDisplaySetDisplayMode(CGDirectDisplayID d,CGDisplayModeRef m,CFDictionaryRef options) {
    CHECK(d==7 && !options && online); selections++; screens[@7][@"mode"]=(__bridge id)m; return kCGErrorSuccess;
}
CGError CGBeginDisplayConfiguration(CGDisplayConfigRef *c) {
    CHECK(!transaction); transaction=[NSMutableDictionary new];
    for (NSNumber *d in screens) transaction[d]=[screens[d] mutableCopy];
    *c=(CGDisplayConfigRef)1; return kCGErrorSuccess;
}
CGError CGConfigureDisplayMirrorOfDisplay(CGDisplayConfigRef c,CGDirectDisplayID d,CGDirectDisplayID master) {
    CHECK(c && transaction[@(d)]); transaction[@(d)][@"mirror"]=@(master); return kCGErrorSuccess;
}
CGError CGConfigureDisplayOrigin(CGDisplayConfigRef c,CGDirectDisplayID d,int32_t x,int32_t y) {
    CHECK(c && transaction[@(d)]); transaction[@(d)][@"x"]=@(x);transaction[@(d)][@"y"]=@(y);return kCGErrorSuccess;
}
CGError CGConfigureDisplayWithDisplayMode(CGDisplayConfigRef c,CGDirectDisplayID d,CGDisplayModeRef m,CFDictionaryRef o) {
    CHECK(c && transaction[@(d)] && m && !o);transaction[@(d)][@"mode"]=(__bridge id)m;return kCGErrorSuccess;
}
CGError CGCancelDisplayConfiguration(CGDisplayConfigRef c) { CHECK(c && transaction);transaction=nil;return kCGErrorSuccess; }
CGError CGCompleteDisplayConfiguration(CGDisplayConfigRef c,CGConfigureOption o) {
    CHECK(c && transaction && o==kCGConfigureForAppOnly);
    if ([transaction[@1][@"mirror"] unsignedIntValue]==7) { CHECK(identified && online && authorized);activations++;mainID=7; }
    else if (transaction[@1]) mainID=1;
    else mainID=transaction[@7] ? 7 : 0;
    commits++;screens=transaction;transaction=nil;return kCGErrorSuccess;
}
IOReturn IOPMAssertionDeclareUserActivity(CFStringRef name,IOPMUserActiveType type,IOPMAssertionID *result) {
    (void)name;(void)type;(void)result;CHECK(NO);return kIOReturnError;
}
IOReturn IOPMAssertionRelease(IOPMAssertionID value) { (void)value;CHECK(NO);return kIOReturnError; }
static void reset(BOOL physical) {
    screens=physical ? [@{@1:screen(2560,1440,0),@2:screen(1920,1200,-1920)} mutableCopy] : [NSMutableDictionary new];
    transaction=nil;available=nil;online=identified=NO;authorized=YES;identity=7;
    creations=activations=selections=commits=virtualIdentityQueries=createdSerial=0;
    mainID=physical ? 1 : 0;
}
static void after(double seconds,dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),block);
}
static void step(unsigned index) {
    static const char *names[] = {
        "physical-readiness-reconnect-identity", "physical-cancel", "physical-timeout",
        "physical-default", "headless-default-reconnect", "headless-mirroring-reconnect",
        "headless-sign-in", "headless-timeout", "headless-cancel"
    };
    if (index == sizeof(names)/sizeof(names[0])) {
        printf("display_readiness=PASS checks=%u cases=%u synthetic_quartz=1 installed_acceptance=0\n",checks,index);
        exit(0);
    }
    reset(index < 4);
    PLANKMacDesktopDisplay *display=index==6 ? [[PLANKMacDesktopDisplay alloc] initForSignIn] : [PLANKMacDesktopDisplay new];
    // Deliberately enable the property for LoginWindow too: its role must keep
    // mirroring disabled even if a caller incorrectly supplies that preference.
    display.mirrorHostDisplays=index!=3 && index!=4;
    BOOL (^valid)(void)=^BOOL { return authorized; };
    void (^next)(void)=^{
        printf("display_readiness_case=%s PASS\n",names[index]);
        dispatch_async(dispatch_get_main_queue(),^{step(index+1);});
    };
    if (index==0) {
        // A display ID exists before WindowServer reports it online or gives it
        // a UUID. Never consolidate/select modes during either readiness gap.
        after(.10,^{CHECK(!activations && !selections);online=YES;});
        after(.20,^{CHECK(!activations && !selections);identified=YES;});
        [display prepareWidth:1920 height:1200 valid:valid completion:^(BOOL ok) {
            CHECK(ok && creations==1 && activations==1 && mainID==7);
            CHECK([display restoreLayout] && mainID==1 && CGDisplayMirrorsDisplay(7)==1);
            // Reconnect reuses the same owned output and original local layout.
            [display prepareWidth:2560 height:1440 valid:valid completion:^(BOOL again) {
                CHECK(again && creations==1 && activations==2);
                CHECK([display restoreLayout] && mainID==1);
                // A reused numeric ID with a different UUID remains rejected.
                identity=99;
                [display prepareWidth:1920 height:1200 valid:valid completion:^(BOOL reused) {
                    CHECK(!reused && activations==2 && ![display restoreLayout]);next();
                }];
            }];
        }];
    } else if (index==1) {
        online=YES;
        after(.10,^{authorized=NO;});
        [display prepareWidth:1920 height:1200 valid:valid completion:^(BOOL ok) {
            CHECK(!ok && !activations && !selections && ![display restoreLayout]);next();
        }];
    } else if (index==2) {
        online=YES; double start=NSProcessInfo.processInfo.systemUptime;
        [display prepareWidth:1920 height:1200 valid:valid completion:^(BOOL ok) {
            CHECK(!ok && !activations && !selections && ![display restoreLayout]);
            CHECK(NSProcessInfo.processInfo.systemUptime-start>=5.9);next();
        }];
    } else if (index==3) {
        // Default extended mode does not acquire mirroring identity policy.
        online=YES;
        [display prepareWidth:1920 height:1200 valid:valid completion:^(BOOL ok) {
            CHECK(ok && !identified && !virtualIdentityQueries && !commits && !activations && mainID==1);next();
        }];
    } else if (index==4) {
        // No monitor or dummy plug exists. Default desktop operation must not
        // require a UUID, create an extra output, or perform a mirror transaction.
        CHECK(!screens.count && !mainID);online=YES;
        [display prepareWidth:3840 height:2160 valid:valid completion:^(BOOL ok) {
            CHECK(ok && createdSerial==1 && creations==1 && screens.count==1 && mainID==7);
            CHECK(!virtualIdentityQueries && !commits && !activations && !CGDisplayMirrorsDisplay(7));
            CHECK([display restoreLayout] && screens.count==1);
            [display prepareWidth:5120 height:2160 valid:valid completion:^(BOOL again) {
                CHECK(again && creations==1 && screens.count==1 && mainID==7);
                CHECK(CGDisplayBounds(7).size.width==5120 && !virtualIdentityQueries && !commits);
                CHECK([display restoreLayout]);next();
            }];
        }];
    } else if (index==5) {
        // An enabled mirror policy must also tolerate an empty physical layout.
        // Once created, the only online output is PLANK's own virtual display.
        CHECK(!screens.count && !mainID);
        after(.10,^{CHECK(!commits && !selections);online=YES;});
        after(.20,^{CHECK(!commits && !selections);identified=YES;});
        [display prepareWidth:2560 height:1440 valid:valid completion:^(BOOL ok) {
            CHECK(ok && creations==1 && screens.count==1 && mainID==7 && commits==1);
            CHECK(!activations && !CGDisplayMirrorsDisplay(7));
            CHECK([display restoreLayout] && commits==2 && screens.count==1 && mainID==7);
            [display prepareWidth:5120 height:2160 valid:valid completion:^(BOOL again) {
                CHECK(again && creations==1 && screens.count==1 && mainID==7 && commits==3);
                CHECK(CGDisplayBounds(7).size.width==5120 && !CGDisplayMirrorsDisplay(7));
                CHECK([display restoreLayout] && commits==4 && screens.count==1);next();
            }];
        }];
    } else if (index==6) {
        // A headless LoginWindow must work before a UUID becomes available,
        // independently of the desktop's mirroring preference.
        CHECK(!screens.count && !mainID);online=YES;
        [display prepareWidth:1920 height:1080 valid:valid completion:^(BOOL ok) {
            CHECK(ok && createdSerial==2 && creations==1 && screens.count==1 && mainID==7);
            CHECK(!virtualIdentityQueries && !commits && !activations && [display restoreLayout]);
            [display prepareWidth:3840 height:2160 valid:valid completion:^(BOOL again) {
                CHECK(again && creations==1 && screens.count==1 && mainID==7);
                CHECK(!virtualIdentityQueries && !commits && [display restoreLayout]);next();
            }];
        }];
    } else if (index==7 || index==8) {
        // No physical display is available to park an unidentified output on.
        // Timeout/cancellation must still signal retirement to the worker owner.
        CHECK(!screens.count && !mainID);online=YES;
        double start=NSProcessInfo.processInfo.systemUptime;
        if (index==8) after(.10,^{authorized=NO;});
        [display prepareWidth:1920 height:1200 valid:valid completion:^(BOOL ok) {
            CHECK(!ok && !activations && !selections && ![display restoreLayout]);
            CHECK(creations==1 && screens.count==1 && mainID==7 && !CGDisplayMirrorsDisplay(7));
            if (index==7) CHECK(NSProcessInfo.processInfo.systemUptime-start>=5.9);
            next();
        }];
    }
}
int main(void) { @autoreleasepool {
    dispatch_async(dispatch_get_main_queue(),^{step(0);});
    // Two independent six-second timeout cases plus short readiness delays.
    after(25,^{fprintf(stderr,"FAIL watchdog\n");exit(1);});CFRunLoopRun();
} }
