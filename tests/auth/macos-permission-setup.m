// SPDX-License-Identifier: GPL-3.0-or-later
// Real AppKit view/callback tests; OS consent, device lookup and extension
// requests are replaced at their boundaries. Never requests real permissions.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "../../apps/host/macos/session/audio-consent.h"
#import "../../apps/host/macos/audio-device/microphone-selection.h"
#import "../../apps/host/macos/camera-device/camera-activation.h"
#include <assert.h>
#include <math.h>

static BOOL screen, accessibility, events, devices;
static unsigned permissionRequests, audioStarts, cameraActivations;
static void (^cameraReply)(PLANKCameraStatus);
static void (^audioReply)(BOOL);
static BOOL checkScreen(void) { return screen; }
static BOOL checkAccessibility(void) { return accessibility; }
static BOOL checkEvents(void) { return events; }
static BOOL requestScreen(void) { ++permissionRequests; return screen; }
static BOOL requestAccessibility(CFDictionaryRef options) { assert(options); ++permissionRequests; return accessibility; }
static BOOL requestEvents(void) { ++permissionRequests; return events; }
static AudioObjectID deviceForUID(NSString *uid) { assert(uid.length); return devices ? 42 : 0; }
static void checkCamera(void (^completion)(PLANKCameraStatus)) { cameraReply = completion; }
static void activateCamera(BOOL enabled, void (^completion)(BOOL)) {
    assert(enabled); ++cameraActivations; completion(YES);
}
@interface TestAudioConsent : NSObject
- (void)startWithCompletion:(void (^)(BOOL))completion;
- (void)stopWithCompletion:(void (^)(void))completion;
@end
@implementation TestAudioConsent
- (void)startWithCompletion:(void (^)(BOOL))completion { ++audioStarts; audioReply = completion; }
- (void)stopWithCompletion:(void (^)(void))completion { completion(); }
@end

#define CGPreflightScreenCaptureAccess checkScreen
#define AXIsProcessTrusted checkAccessibility
#define CGPreflightPostEventAccess checkEvents
#define CGRequestScreenCaptureAccess requestScreen
#define AXIsProcessTrustedWithOptions requestAccessibility
#define CGRequestPostEventAccess requestEvents
#define PLANKMicDeviceForUID deviceForUID
#define PLANKMacCheckCameraExtension checkCamera
#define PLANKMacRequestCameraExtension activateCamera
#define PLANKMacAudioConsent TestAudioConsent
#include "../../apps/host/macos/session/permission-setup.m"

// Replace only the screen inventory; do not resize the test Mac's displays.
@interface TestSetupGeometry : PLANKPermissionSetup
@property NSRect visibleFrame;
@property BOOL syntheticGeometry;
@property unsigned geometryReads;
@end
@implementation TestSetupGeometry
- (NSRect)setupVisibleFrame {
    if (!_syntheticGeometry) return [super setupVisibleFrame];
    ++_geometryReads;
    return _visibleFrame;
}
@end

static void drainPositionUpdate(TestSetupGeometry *view) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (view.positionUpdatePending && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];
    assert(!view.positionUpdatePending);
}
static void assertCentered(TestSetupGeometry *view) {
    NSPoint expected = centeredSetupOrigin(view.window.frame.size, view.visibleFrame);
    assert(fabs(view.window.frame.origin.x - expected.x) < 1);
    assert(fabs(view.window.frame.origin.y - expected.y) < 1);
}
static void testDisplayChanges(void) {
    TestSetupGeometry *view = [[TestSetupGeometry alloc] initWithVersion:@"geometry-test"];
    view.syntheticGeometry = YES;
    view.visibleFrame = NSMakeRect(0, 40, 1920, 1016);
    [view centerInCurrentScreen]; assertCentered(view);
    assert(!view.userPositioned); // Our programmatic moves are not user drags.
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    NSPoint before = view.window.frame.origin;
    unsigned reads = view.geometryReads;
    // Initial inventory is replaced asynchronously as the worker restores its
    // virtual display. Read the latest geometry, not the first notification's.
    view.visibleFrame = NSMakeRect(0, 40, 3840, 2096);
    [notifications postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
    view.visibleFrame = NSMakeRect(0, 40, 5120, 2096);
    [notifications postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
    assert(view.positionUpdatePending && view.geometryReads == reads);
    assert(NSEqualPoints(view.window.frame.origin, before));
    drainPositionUpdate(view); assertCentered(view);
    assert(view.geometryReads == reads + 1 && !view.userPositioned);
    // HiDPI uses logical points; a secondary screen may have a negative origin.
    view.visibleFrame = NSMakeRect(-1512, 80, 1512, 877);
    [notifications postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
    drainPositionUpdate(view); assertCentered(view);
    before = view.window.frame.origin;
    view.visibleFrame = NSZeroRect;
    [notifications postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
    drainPositionUpdate(view);
    assert(NSEqualPoints(view.window.frame.origin, before));
    // Validate deliberate movement independently of real physical mouse state.
    assert(setupMoveIsUserDrag(view.window, view.window, NSEventTypeLeftMouseDragged, 1));
    assert(setupMoveIsUserDrag(view.window, view.window, NSEventTypeLeftMouseDown, 1));
    assert(!setupMoveIsUserDrag(view.window, view.window, NSEventTypeLeftMouseDragged, 0)); // Stale event.
    assert(!setupMoveIsUserDrag(view.window, view.window, NSEventTypeMouseMoved, 1));
    assert(!setupMoveIsUserDrag(view.window, nil, NSEventTypeLeftMouseDragged, 1));
    NSWindow *other = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    assert(!setupMoveIsUserDrag(view.window, other, NSEventTypeLeftMouseDragged, 1));
    view.visibleFrame = NSMakeRect(0, 40, 1920, 1016);
    [notifications postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
    view.userPositioned = YES; // User starts dragging before the queued update.
    drainPositionUpdate(view);
    [notifications postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
    assert(!view.positionUpdatePending && NSEqualPoints(view.window.frame.origin, before));
    view.userPositioned = NO;
    [notifications postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
    view.closing = YES; // Late updates cannot move or reopen a dismissed window.
    drainPositionUpdate(view);
    [notifications postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
    assert(!view.positionUpdatePending && NSEqualPoints(view.window.frame.origin, before));
    assert(!view.window.visible);
}

static BOOL rowContains(PLANKPermissionSetup *view, NSString *key, NSString *text) {
    return [view.rows[key].status.stringValue containsString:text];
}
int main(void) {
    @autoreleasepool {
        [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyProhibited];
        testDisplayChanges();
        PLANKPermissionSetup *view = [[PLANKPermissionSetup alloc] initWithVersion:@"1.2.3-test"];
        assert(!view.shouldCascadeWindows);
        // AppKit coordinates are logical points; secondary screens can have
        // nonzero/negative origins. No physical-pixel or resolution assumptions.
        assert(NSEqualPoints(centeredSetupOrigin(NSMakeSize(650, 600), NSMakeRect(0, 40, 1920, 1016)),
                             NSMakePoint(635, 248)));
        assert(NSEqualPoints(centeredSetupOrigin(NSMakeSize(650, 600), NSMakeRect(-1920, -300, 1920, 1080)),
                             NSMakePoint(-1285, -60)));
        assert(NSEqualPoints(centeredSetupOrigin(NSMakeSize(650, 600), NSMakeRect(1920, 80, 1512, 877)),
                             NSMakePoint(2351, 218.5)));
        NSScreen *setupScreen = NSScreen.mainScreen ?: view.window.screen;
        if (setupScreen) {
            NSRect frame = view.window.frame, visible = setupScreen.visibleFrame;
            assert(fabs(NSMidX(frame) - NSMidX(visible)) < 1);
            assert(fabs(NSMidY(frame) - NSMidY(visible)) < 1);
        }
        NSPoint initialOrigin = view.window.frame.origin;
        assert(view.rows.count == 6 && !view.rows[@"audio"]);
        [view refresh];
        assert(rowContains(view, @"screen", @"! Required"));
        assert(rowContains(view, @"output", @"— Not loaded"));
        assert(audioStarts == 0);
        [view requestPermissions]; assert(permissionRequests == 3);
        cameraReply(PLANKCameraDisabled);
        assert(view.rows[@"camera"].action.enabled && cameraActivations == 0);
        screen = accessibility = events = devices = YES;
        [view refresh];
        assert(rowContains(view, @"screen", @"✓ Allowed"));
        assert(rowContains(view, @"microphone", @"✓ Loaded"));
        assert(audioStarts == 1);
        audioReply(YES);
        assert([view.audioHelp.stringValue containsString:@"when macOS asks"]);
        audioReply(NO);
        assert([view.audioHelp.stringValue containsString:@"could not start"]);
        cameraReply(PLANKCameraEnabled);
        assert(cameraActivations == 1);
        cameraReply(PLANKCameraEnabled); // Re-query after upgrade, not another activation.
        assert(cameraActivations == 1 && rowContains(view, @"camera", @"✓ Enabled"));
        assert(view.rows[@"camera"].action.enabled && [view.rows[@"camera"].action.title isEqualToString:@"Open Settings"]);
        [view refresh]; cameraReply(PLANKCameraAwaitingApproval);
        assert(rowContains(view, @"camera", @"— Approval needed"));
        [view refresh]; cameraReply(PLANKCameraRemoving);
        assert(rowContains(view, @"camera", @"Removal pending"));
        [view refresh]; cameraReply(PLANKCameraUnknown);
        assert(rowContains(view, @"camera", @"Could not check") && view.rows[@"camera"].action.enabled);
        [view refresh]; cameraReply(PLANKCameraEnabled);
        assert(audioStarts == 1);
        [view requestPermissions]; assert(permissionRequests == 3);
        [view.window.contentView layoutSubtreeIfNeeded];
        assert(NSEqualPoints(view.window.frame.origin, initialOrigin));
        NSStackView *stack = (NSStackView *)view.window.contentView.subviews.firstObject;
        NSView *footer = stack.arrangedSubviews.lastObject;
        NSStackView *buttons = (NSStackView *)footer.subviews.firstObject;
        assert(buttons.arrangedSubviews.count == 2);
        assert(fabs(NSMaxX(buttons.frame) - NSWidth(footer.bounds)) < 1);
        assert(NSMinX(buttons.frame) > NSMidX(footer.bounds));
        for (PLANKSetupRow *row in view.rows.allValues) {
            assert(row.status.frame.size.width >= row.status.fittingSize.width);
            assert(row.status.frame.size.height >= row.status.fittingSize.height);
            assert(row.status.frame.size.height > 0);
        }
        const char *preview = getenv("PLANK_PERMISSION_PREVIEW");
        if (preview) {
            NSView *content = view.window.contentView;
            view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            [view.window.appearance performAsCurrentDrawingAppearance:^{
                NSImage *page = [[NSImage alloc] initWithData:[content dataWithPDFInsideRect:content.bounds]];
                NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                    pixelsWide:(NSInteger)content.bounds.size.width pixelsHigh:(NSInteger)content.bounds.size.height
                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                [NSGraphicsContext saveGraphicsState];
                NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
                [NSColor.windowBackgroundColor setFill]; NSRectFill(content.bounds);
                [page drawInRect:content.bounds];
                [NSGraphicsContext restoreGraphicsState];
                NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                assert([png writeToFile:[NSString stringWithUTF8String:preview] atomically:YES]);
            }];
        }
        // A dismissed window cannot be updated/reopened by a late OS callback.
        [view refresh]; view.closing = YES;
        NSString *previous = view.rows[@"camera"].status.stringValue;
        cameraReply(PLANKCameraDisabled); audioReply(NO); [view refresh];
        assert([previous isEqualToString:view.rows[@"camera"].status.stringValue]);
        puts("Host permission view: display-change centering, drag policy, required/optional states, consent uncertainty, refresh, upgrade and stale callbacks passed");
    }
    return 0;
}
