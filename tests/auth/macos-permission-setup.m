// SPDX-License-Identifier: GPL-3.0-or-later
// Real AppKit view/callback tests; OS consent, device lookup and extension
// requests are replaced at their boundaries. Never requests real permissions.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "../../apps/host/macos/session/audio-consent.h"
#import "../../apps/host/macos/audio-device/microphone-selection.h"
#import "../../apps/host/macos/camera-device/camera-activation.h"
#include <assert.h>

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

static BOOL rowContains(PLANKPermissionSetup *view, NSString *key, NSString *text) {
    return [view.rows[key].status.stringValue containsString:text];
}
int main(void) {
    @autoreleasepool {
        [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyProhibited];
        PLANKPermissionSetup *view = [[PLANKPermissionSetup alloc] initWithVersion:@"1.2.3-test"];
        assert(view.rows.count == 7);
        [view refresh];
        assert(rowContains(view, @"screen", @"! Required"));
        assert(rowContains(view, @"audio", @"— Check in Settings"));
        assert(rowContains(view, @"output", @"— Not loaded"));
        assert(audioStarts == 0);
        [view requestPermissions]; assert(permissionRequests == 3);
        cameraReply(PLANKCameraDisabled);
        assert(view.rows[@"camera"].action.enabled && cameraActivations == 0);
        screen = accessibility = events = devices = YES;
        [view refresh];
        assert(rowContains(view, @"screen", @"✓ Allowed"));
        assert(rowContains(view, @"microphone", @"✓ Loaded"));
        assert(rowContains(view, @"audio", @"Requesting consent"));
        assert(audioStarts == 1);
        audioReply(YES);
        assert(rowContains(view, @"audio", @"— Check in Settings"));
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
        puts("Host permission view: required/optional states, consent uncertainty, refresh, upgrade and stale callbacks passed");
    }
    return 0;
}
