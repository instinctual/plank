// SPDX-License-Identifier: GPL-3.0-or-later
#import "camera-activation.h"
#import <SystemExtensions/SystemExtensions.h>
#import <AppKit/AppKit.h>
#include "camera-link.h"
#include <unistd.h>

@interface PLANKCameraActivation : NSObject <OSSystemExtensionRequestDelegate>
@property(copy) void (^completion)(BOOL);
@end
static PLANKCameraActivation *pending;
@implementation PLANKCameraActivation
- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request
    actionForReplacingExtension:(OSSystemExtensionProperties *)existing
    withExtension:(OSSystemExtensionProperties *)replacement {
    (void)request; (void)existing;
    return [replacement.bundleIdentifier isEqualToString:@PLANK_CAMERA_EXTENSION_ID] ?
        OSSystemExtensionReplacementActionReplace : OSSystemExtensionReplacementActionCancel;
}
- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request {
    (void)request;
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Enable PLANK Camera";
    alert.informativeText = @"Approve PLANK Camera in System Settings → General → Login Items & Extensions → Camera Extensions. "
        "The camera stays off until you enable forwarding from the Client toolbar.";
    [alert addButtonWithTitle:@"OK"]; [NSApp activate]; [alert runModal];
}
- (void)finish:(BOOL)success message:(NSString *)message {
    if (message) {
        NSAlert *alert = [NSAlert new]; alert.messageText = @"PLANK Camera"; alert.informativeText = message;
        [alert addButtonWithTitle:@"OK"]; [NSApp activate]; [alert runModal];
    }
    void (^completion)(BOOL) = _completion; _completion = nil;
    pending = nil; if (completion) completion(success);
}
- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
    (void)request; (void)error;
    [self finish:NO message:@"PLANK Camera setup did not complete. Check Camera Extensions in System Settings and reopen PLANK Host to try again."];
}
- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    (void)request;
    [self finish:result == OSSystemExtensionRequestCompleted message:
        result == OSSystemExtensionRequestWillCompleteAfterReboot ? @"Restart this Mac to finish the camera extension change." : nil];
}
@end
void PLANKMacRequestCameraExtension(BOOL enable, void (^completion)(BOOL)) {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (pending || !completion || geteuid() == 0) { if (completion) completion(NO); return; }
    pending = [PLANKCameraActivation new]; pending.completion = completion;
    OSSystemExtensionRequest *request = enable ?
        [OSSystemExtensionRequest activationRequestForExtension:@PLANK_CAMERA_EXTENSION_ID queue:dispatch_get_main_queue()] :
        [OSSystemExtensionRequest deactivationRequestForExtension:@PLANK_CAMERA_EXTENSION_ID queue:dispatch_get_main_queue()];
    request.delegate = pending;
    [OSSystemExtensionManager.sharedManager submitRequest:request];
}

@interface PLANKCameraStatusRequest : NSObject <OSSystemExtensionRequestDelegate>
@property(copy) void (^completion)(BOOL known, BOOL enabled);
@end
static PLANKCameraStatusRequest *pendingStatus;
@implementation PLANKCameraStatusRequest
- (void)finish:(BOOL)known enabled:(BOOL)enabled {
    void (^completion)(BOOL, BOOL) = _completion; _completion = nil;
    if (pendingStatus == self) pendingStatus = nil;
    if (completion) completion(known, enabled);
}
- (void)request:(OSSystemExtensionRequest *)request foundProperties:(NSArray<OSSystemExtensionProperties *> *)properties {
    (void)request;
    BOOL enabled = NO;
    for (OSSystemExtensionProperties *property in properties) {
        // An older copy can remain listed until reboot after an upgrade or
        // removal. Its presence alone must not re-enable a disabled camera.
        if ([property.bundleIdentifier isEqualToString:@PLANK_CAMERA_EXTENSION_ID] &&
            property.isEnabled && !property.isUninstalling && !property.isAwaitingUserApproval)
            enabled = YES;
    }
    [self finish:YES enabled:enabled];
}
- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
    (void)request; (void)error; [self finish:NO enabled:NO];
}
- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    // Properties requests complete through foundProperties, not this callback.
    (void)request; (void)result; [self finish:NO enabled:NO];
}
- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request {
    (void)request; [self finish:NO enabled:NO];
}
- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request
    actionForReplacingExtension:(OSSystemExtensionProperties *)existing
    withExtension:(OSSystemExtensionProperties *)replacement {
    (void)request; (void)existing; (void)replacement;
    return OSSystemExtensionReplacementActionCancel;
}
@end

static void showReady(BOOL known, BOOL enabled, void (^completion)(void)) {
    NSAlert *ready = [NSAlert new]; ready.messageText = @"PLANK Host is ready";
    NSString *camera = enabled ? @"PLANK Camera is enabled." : known ?
        @"You can enable PLANK Camera for webcam forwarding." :
        @"Camera status could not be checked. You can retry camera setup.";
    ready.informativeText = [NSString stringWithFormat:
        @"Screen and input permissions are enabled. Complete the macOS system-audio permission prompt if shown. "
         "No audio is recorded or sent by setup. %@ Camera capture starts only from the Client toolbar.", camera];
    [ready addButtonWithTitle:@"Close"];
    if (!enabled) [ready addButtonWithTitle:known ? @"Enable Camera" : @"Set Up Camera"];
    [NSApp activate];
    if ([ready runModal] == NSAlertSecondButtonReturn && !enabled)
        PLANKMacRequestCameraExtension(YES, ^(BOOL success) { (void)success; completion(); });
    else completion();
}

void PLANKMacShowCameraSetup(void (^completion)(void)) {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (!completion) return;
    if (pendingStatus || pending || geteuid() == 0) { completion(); return; }
    PLANKCameraStatusRequest *status = [PLANKCameraStatusRequest new];
    pendingStatus = status;
    status.completion = ^(BOOL known, BOOL enabled) {
        if (enabled) {
            // Submitting activation for an enabled extension lets macOS retain
            // approval and replace an older version bundled with this Host.
            // Merely hiding the button would leave that older version installed.
            PLANKMacRequestCameraExtension(YES, ^(BOOL success) {
                if (success) showReady(YES, YES, completion);
                else completion(); // Activation already explained failure/reboot.
            });
        } else showReady(known, NO, completion);
    };
    OSSystemExtensionRequest *request = [OSSystemExtensionRequest
        propertiesRequestForExtension:@PLANK_CAMERA_EXTENSION_ID queue:dispatch_get_main_queue()];
    request.delegate = status;
    [OSSystemExtensionManager.sharedManager submitRequest:request];
    // Keep setup usable if the system service does not answer. Never infer an
    // enabled camera from an error, timeout or a cached preference.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [status finish:NO enabled:NO];
    });
}
