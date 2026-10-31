// SPDX-License-Identifier: GPL-3.0-or-later
// All Quartz/ColorSync calls below are link-time substitutes. No WindowServer,
// display creation, input, account, network or physical mode mutation.
#import "display-layout.h"
#import <ColorSync/ColorSync.h>
#include <assert.h>

static NSMutableDictionary *screens, *pending;
static unsigned commits, cancels, calls, failAt, checks;
static BOOL failComplete, failInventory;
static CGDirectDisplayID mainID;
#define CHECK(x) do { checks++; assert(x); } while(0)
static NSMutableDictionary *screen(unsigned mode, int x, int y, unsigned mirror, unsigned identity) {
    return [@{@"mode":@(mode),@"x":@(x),@"y":@(y),@"mirror":@(mirror),@"identity":@(identity)} mutableCopy];
}
static void reset(void) {
    screens = [@{@1:screen(11,0,0,0,1), @2:screen(22,2560,0,0,2), @7:screen(77,4000,0,0,7)} mutableCopy];
    pending = nil; mainID = 1; commits = cancels = calls = failAt = 0; failComplete = failInventory = NO;
}
CGError CGGetOnlineDisplayList(uint32_t capacity, CGDirectDisplayID *list, uint32_t *count) {
    if (failInventory) return kCGErrorFailure;
    *count = (uint32_t)screens.count;
    if (capacity) { unsigned i = 0; for (NSNumber *key in [[screens allKeys] sortedArrayUsingSelector:@selector(compare:)]) list[i++] = key.unsignedIntValue; }
    return kCGErrorSuccess;
}
CFUUIDRef CGDisplayCreateUUIDFromDisplayID(uint32_t identifier) {
    unsigned identity = [screens[@(identifier)][@"identity"] unsignedIntValue];
    return identity ? CFUUIDCreateFromString(NULL, (__bridge CFStringRef)[NSString stringWithFormat:@"00000000-0000-0000-0000-%012u",identity]) : NULL;
}
CGDirectDisplayID CGMainDisplayID(void) { return mainID; }
CGDirectDisplayID CGDisplayMirrorsDisplay(CGDirectDisplayID d) { return [screens[@(d)][@"mirror"] unsignedIntValue]; }
boolean_t CGDisplayIsAlwaysInMirrorSet(CGDirectDisplayID d) { (void)d; return false; }
boolean_t CGDisplayIsOnline(CGDirectDisplayID d) { return screens[@(d)] != nil; }
CGRect CGDisplayBounds(CGDirectDisplayID d) { return CGRectMake([screens[@(d)][@"x"] intValue],[screens[@(d)][@"y"] intValue],1920,1200); }
CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID d) { return (CGDisplayModeRef)CFRetain((__bridge CFTypeRef)screens[@(d)][@"mode"]); }
int32_t CGDisplayModeGetIODisplayModeID(CGDisplayModeRef mode) { return [(__bridge NSNumber *)mode intValue]; }
void CGDisplayModeRelease(CGDisplayModeRef mode) { if (mode) CFRelease(mode); }
CGError CGBeginDisplayConfiguration(CGDisplayConfigRef *config) {
    CHECK(!pending); pending = [NSMutableDictionary new];
    for (NSNumber *key in screens) pending[key] = [screens[key] mutableCopy];
    *config = (CGDisplayConfigRef)1; return kCGErrorSuccess;
}
static BOOL fail(void) { return ++calls == failAt; }
CGError CGConfigureDisplayMirrorOfDisplay(CGDisplayConfigRef config,CGDirectDisplayID d,CGDirectDisplayID master) {
    CHECK(config && pending[@(d)]); if (fail()) return kCGErrorFailure;
    pending[@(d)][@"mirror"] = @(master); return kCGErrorSuccess;
}
CGError CGConfigureDisplayOrigin(CGDisplayConfigRef config, CGDirectDisplayID d,int32_t x,int32_t y) {
    CHECK(config && pending[@(d)]); if (fail()) return kCGErrorFailure;
    pending[@(d)][@"x"] = @(x); pending[@(d)][@"y"] = @(y); return kCGErrorSuccess;
}
CGError CGConfigureDisplayWithDisplayMode(CGDisplayConfigRef config,CGDirectDisplayID d,CGDisplayModeRef mode,CFDictionaryRef options) {
    CHECK(config && pending[@(d)] && !options); if (fail()) return kCGErrorFailure;
    pending[@(d)][@"mode"] = (__bridge id)mode; return kCGErrorSuccess;
}
CGError CGCancelDisplayConfiguration(CGDisplayConfigRef config) { CHECK(config && pending); pending = nil; cancels++; return kCGErrorSuccess; }
CGError CGCompleteDisplayConfiguration(CGDisplayConfigRef config,CGConfigureOption option) {
    CHECK(config && pending && option == kCGConfigureForAppOnly);
    if (failComplete) { pending = nil; return kCGErrorFailure; }
    screens = pending; pending = nil; commits++;
    for (NSNumber *key in screens) if (![screens[key][@"mirror"] unsignedIntValue] && ![screens[key][@"x"] intValue] && ![screens[key][@"y"] intValue]) mainID = key.unsignedIntValue;
    return kCGErrorSuccess;
}
int main(void) { @autoreleasepool {
    reset(); PLANKMacDisplayLayout *layout = [PLANKMacDisplayLayout new];
    CHECK([layout restore] && commits == 0);
    CHECK([layout beginExcludingDisplay:7]); CHECK(![layout beginExcludingDisplay:7]);
    CHECK([layout activateDisplay:7]); CHECK([layout matchesDisplay:7]);
    CHECK(CGDisplayMirrorsDisplay(1) == 7 && CGDisplayMirrorsDisplay(2) == 7);
    CHECK([layout restore] && !layout.pending);
    CHECK(CGMainDisplayID() == 1 && CGDisplayMirrorsDisplay(1) == 0 && CGDisplayMirrorsDisplay(2) == 0);
    CHECK([screens[@2][@"x"] intValue] == 2560 && [screens[@1][@"mode"] intValue] == 11);
    CHECK(CGDisplayMirrorsDisplay(7) == 1); // No stranded idle workspace.
    CHECK([layout beginExcludingDisplay:7] && CGDisplayMirrorsDisplay(7) == 0);
    CHECK([layout activateDisplay:7] && [layout restore]); // Reconnect keeps original layout.
    for (unsigned failure = 1; failure <= 4; failure++) {
        reset(); layout = [PLANKMacDisplayLayout new]; CHECK([layout beginExcludingDisplay:7]);
        failAt = failure; CHECK(![layout activateDisplay:7]); CHECK(cancels == 1);
        CHECK(CGDisplayMirrorsDisplay(1) == 0); failAt = 0; CHECK([layout restore]);
    }
    reset(); layout = [PLANKMacDisplayLayout new]; CHECK([layout beginExcludingDisplay:7]);
    failComplete = YES; CHECK(![layout activateDisplay:7]); CHECK(layout.pending);
    failComplete = NO; CHECK([layout restore]);
    reset(); screens[@2][@"mirror"] = @1;
    layout = [PLANKMacDisplayLayout new]; CHECK([layout beginExcludingDisplay:7]);
    CHECK([layout activateDisplay:7] && [layout restore]); CHECK(CGDisplayMirrorsDisplay(2) == 1);
    reset(); layout = [PLANKMacDisplayLayout new]; CHECK([layout beginExcludingDisplay:7]);
    screens[@9] = screen(99,6000,0,0,9); CHECK(![layout activateDisplay:7] && commits == 0);
    CHECK([layout restore]); CHECK([screens[@9][@"x"] intValue] == 6000 && CGDisplayMirrorsDisplay(9) == 0);
    reset(); layout = [PLANKMacDisplayLayout new]; CHECK([layout beginExcludingDisplay:7]); CHECK([layout activateDisplay:7]);
    screens[@2] = screen(999,9000,0,0,999); // Same ID, different physical identity.
    CHECK(![layout matchesDisplay:7]); CHECK([layout restore]); CHECK([screens[@2][@"mode"] intValue] == 999);
    reset(); layout = [PLANKMacDisplayLayout new]; CHECK([layout beginExcludingDisplay:7]); CHECK([layout activateDisplay:7]);
    [screens removeObjectForKey:@2]; CHECK(![layout matchesDisplay:7]); CHECK([layout restore]);
    CHECK(CGMainDisplayID() == 1 && CGDisplayMirrorsDisplay(7) == 1);
    reset(); layout = [PLANKMacDisplayLayout new]; CHECK([layout beginExcludingDisplay:7]); CHECK([layout activateDisplay:7]);
    failAt = calls + 1; CHECK(![layout restore] && layout.pending); failAt = 0; CHECK([layout restore]);
    reset(); layout = [PLANKMacDisplayLayout new]; CHECK([layout beginExcludingDisplay:7]); CHECK([layout activateDisplay:7]);
    screens[@7] = screen(999,9000,0,0,999);
    CHECK(![layout matchesDisplay:7]);
    CHECK([layout restore]); CHECK([screens[@7][@"x"] intValue] == 9000 && CGDisplayMirrorsDisplay(7) == 0);
    CHECK(![layout beginExcludingDisplay:7]); // Never reuse a stale owned output ID.
    reset(); layout = [PLANKMacDisplayLayout new]; failInventory = YES;
    CHECK(![layout beginExcludingDisplay:7] && !layout.pending && commits == 0);
    printf("display_layout=PASS checks=%u synthetic_quartz=1 physical_acceptance=0\n", checks);
} }
