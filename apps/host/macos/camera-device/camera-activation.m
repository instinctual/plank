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
