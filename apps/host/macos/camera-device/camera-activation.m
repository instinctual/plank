// SPDX-License-Identifier: GPL-3.0-or-later
#import "camera-activation.h"
#import <SystemExtensions/SystemExtensions.h>
#import <AppKit/AppKit.h>
#include "camera-link.h"
#include <stdio.h>
#include <unistd.h>

@interface PLANKCameraActivation : NSObject <OSSystemExtensionRequestDelegate>
@property(copy) void (^completion)(BOOL);
@property(copy) void (^removalCompletion)(PLANKCameraRemovalResult);
@end
static PLANKCameraActivation *pending;
@class PLANKCameraStatusRequest;
static PLANKCameraStatusRequest *pendingStatus;
@implementation PLANKCameraActivation
- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request
    actionForReplacingExtension:(OSSystemExtensionProperties *)existing
    withExtension:(OSSystemExtensionProperties *)replacement {
    (void)request; (void)existing;
    if (!_completion) return OSSystemExtensionReplacementActionCancel;
    return [replacement.bundleIdentifier isEqualToString:@PLANK_CAMERA_EXTENSION_ID] ?
        OSSystemExtensionReplacementActionReplace : OSSystemExtensionReplacementActionCancel;
}
- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request {
    (void)request;
    if (_removalCompletion) {
        fprintf(stderr, "PLANK: Approve camera removal in the macOS permission prompt.\n");
        [NSApp activate]; return;
    }
    if (!_completion) return;
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Enable PLANK Camera";
    alert.informativeText = @"Approve PLANK Camera in System Settings → General → Login Items & Extensions → Camera Extensions.\n\n"
        "The camera stays off until you enable forwarding from the Client toolbar.";
    [alert addButtonWithTitle:@"OK"]; [NSApp activate]; [alert runModal];
}
- (void)finish:(BOOL)success message:(NSString *)message {
    if (!_completion) return;
    if (message) {
        NSAlert *alert = [NSAlert new]; alert.messageText = @"PLANK Camera"; alert.informativeText = message;
        [alert addButtonWithTitle:@"OK"]; [NSApp activate]; [alert runModal];
    }
    void (^completion)(BOOL) = _completion; _completion = nil;
    pending = nil; if (completion) completion(success);
}
- (void)finishRemoval:(PLANKCameraRemovalResult)result {
    void (^completion)(PLANKCameraRemovalResult) = _removalCompletion;
    _removalCompletion = nil;
    if (pending == self) pending = nil;
    if (completion) completion(result);
}
- (void)removalTimedOut {
    if (!_removalCompletion) return;
    fprintf(stderr, "PLANK: Camera removal timed out waiting for macOS or approval. Host was not removed; retry uninstall.\n");
    [self finishRemoval:PLANKCameraRemovalFailed];
}
- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
    (void)request; (void)error;
    if (_removalCompletion) {
        fprintf(stderr, "PLANK: Camera removal failed or was cancelled (system error %ld). Host was not removed.\n", (long)error.code);
        [self finishRemoval:PLANKCameraRemovalFailed]; return;
    }
    [self finish:NO message:@"PLANK Camera setup did not complete.\n\nCheck Camera Extensions in System Settings and reopen PLANK Host to try again."];
}
- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    (void)request;
    if (_removalCompletion) {
        [self finishRemoval:result == OSSystemExtensionRequestCompleted ? PLANKCameraRemovalComplete :
            result == OSSystemExtensionRequestWillCompleteAfterReboot ? PLANKCameraRemovalRestartRequired : PLANKCameraRemovalFailed];
        return;
    }
    [self finish:result == OSSystemExtensionRequestCompleted message:
        result == OSSystemExtensionRequestWillCompleteAfterReboot ? @"Restart this Mac to finish the camera extension change." : nil];
}
@end

void PLANKMacRemoveCameraExtension(void (^completion)(PLANKCameraRemovalResult)) {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (pending || pendingStatus || !completion || geteuid() == 0) {
        if (completion) completion(PLANKCameraRemovalFailed);
        return;
    }
    PLANKCameraActivation *removal = [PLANKCameraActivation new];
    pending = removal; removal.removalCompletion = completion;
    OSSystemExtensionRequest *request = [OSSystemExtensionRequest
        deactivationRequestForExtension:@PLANK_CAMERA_EXTENSION_ID queue:dispatch_get_main_queue()];
    request.delegate = removal;
    [OSSystemExtensionManager.sharedManager submitRequest:request];
    // No PLANK modal alert can block the command's completion. macOS owns any
    // administrator approval dialog. The caller keeps the app on every failure.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [removal removalTimedOut];
    });
}
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
@property(copy) void (^completion)(PLANKCameraStatus);
@end
@implementation PLANKCameraStatusRequest
- (void)finish:(PLANKCameraStatus)state {
    void (^completion)(PLANKCameraStatus) = _completion; _completion = nil;
    if (pendingStatus == self) pendingStatus = nil;
    if (completion) completion(state);
}
- (void)request:(OSSystemExtensionRequest *)request foundProperties:(NSArray<OSSystemExtensionProperties *> *)properties {
    (void)request;
    PLANKCameraStatus state = PLANKCameraDisabled;
    for (OSSystemExtensionProperties *property in properties) {
        // An older copy can remain listed until reboot after an upgrade or
        // removal. Its presence alone must not re-enable a disabled camera.
        if (![property.bundleIdentifier isEqualToString:@PLANK_CAMERA_EXTENSION_ID]) continue;
        if (property.isUninstalling) {
            if (state == PLANKCameraDisabled) state = PLANKCameraRemoving;
        } else if (property.isAwaitingUserApproval) state = PLANKCameraAwaitingApproval;
        else if (property.isEnabled) { state = PLANKCameraEnabled; break; }
    }
    [self finish:state];
}
- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
    (void)request; (void)error; [self finish:PLANKCameraUnknown];
}
- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    // Properties requests complete through foundProperties, not this callback.
    (void)request; (void)result; [self finish:PLANKCameraUnknown];
}
- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request {
    (void)request; [self finish:PLANKCameraUnknown];
}
- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request
    actionForReplacingExtension:(OSSystemExtensionProperties *)existing
    withExtension:(OSSystemExtensionProperties *)replacement {
    (void)request; (void)existing; (void)replacement;
    return OSSystemExtensionReplacementActionCancel;
}
@end

void PLANKMacCheckCameraExtension(void (^completion)(PLANKCameraStatus)) {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (!completion) return;
    if (pendingStatus || pending || geteuid() == 0) { completion(PLANKCameraUnknown); return; }
    PLANKCameraStatusRequest *status = [PLANKCameraStatusRequest new];
    pendingStatus = status;
    status.completion = completion;
    OSSystemExtensionRequest *request = [OSSystemExtensionRequest
        propertiesRequestForExtension:@PLANK_CAMERA_EXTENSION_ID queue:dispatch_get_main_queue()];
    request.delegate = status;
    [OSSystemExtensionManager.sharedManager submitRequest:request];
    // Keep setup usable if the system service does not answer. Never infer an
    // enabled camera from an error, timeout or a cached preference.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [status finish:PLANKCameraUnknown];
    });
}
