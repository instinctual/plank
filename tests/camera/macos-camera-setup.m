// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the real setup/delegate flow without activating extensions or UI.
#import <AppKit/AppKit.h>
#import <SystemExtensions/SystemExtensions.h>
#include <assert.h>

static NSMutableArray<OSSystemExtensionRequest *> *requests;
@interface TestExtensionManager : NSObject
+ (instancetype)sharedManager;
- (void)submitRequest:(OSSystemExtensionRequest *)request;
@end
@implementation TestExtensionManager
+ (instancetype)sharedManager { static id instance; if (!instance) instance = [self new]; return instance; }
- (void)submitRequest:(OSSystemExtensionRequest *)request { [requests addObject:request]; }
@end

@interface TestAlert : NSObject
@property(copy) NSString *messageText, *informativeText;
@property(strong) NSMutableArray<NSString *> *buttons;
- (void)addButtonWithTitle:(NSString *)title;
- (NSModalResponse)runModal;
@end
static NSMutableArray<TestAlert *> *alerts;
static NSModalResponse response;
@implementation TestAlert
- (instancetype)init { if ((self = [super init])) _buttons = [NSMutableArray array]; return self; }
- (void)addButtonWithTitle:(NSString *)title { [_buttons addObject:title]; }
- (NSModalResponse)runModal { [alerts addObject:self]; return response; }
@end
@interface TestApplication : NSObject
+ (instancetype)sharedApplication;
- (void)activate;
@end
@implementation TestApplication
+ (instancetype)sharedApplication { static id instance; if (!instance) instance = [self new]; return instance; }
- (void)activate {}
@end

// Only the OS submission and modal UI boundaries are replaced. Request objects,
// production callbacks, status selection and activation/replacement logic run.
#define OSSystemExtensionManager TestExtensionManager
#define NSAlert TestAlert
#undef NSApp
#define NSApp TestApplication.sharedApplication
#include "../../apps/host/macos/camera-device/camera-activation.m"

@interface TestProperties : NSObject
@property(copy) NSString *bundleIdentifier;
@property BOOL isEnabled, isUninstalling, isAwaitingUserApproval;
@end
@implementation TestProperties
@end

static unsigned completions;
static PLANKCameraStatus cameraState;
static OSSystemExtensionRequest *begin(void) {
    assert(!pending && !pendingStatus);
    requests = [NSMutableArray array]; alerts = [NSMutableArray array];
    completions = 0; response = NSAlertFirstButtonReturn;
    PLANKMacCheckCameraExtension(^(PLANKCameraStatus state) { cameraState = state; ++completions; });
    assert(requests.count == 1 && alerts.count == 0 && completions == 0);
    return requests.firstObject;
}
static TestProperties *properties(BOOL enabled) {
    TestProperties *result = [TestProperties new];
    result.bundleIdentifier = @PLANK_CAMERA_EXTENSION_ID; result.isEnabled = enabled;
    return result;
}
static void found(OSSystemExtensionRequest *request, NSArray *values) {
    [request.delegate request:request foundProperties:values];
}
static void statusTest(NSArray *values, PLANKCameraStatus expected) {
    OSSystemExtensionRequest *request = begin();
    id<OSSystemExtensionRequestDelegate> delegate = request.delegate;
    found(request, values);
    assert(cameraState == expected && completions == 1 && requests.count == 1 && alerts.count == 0);
    [delegate request:request foundProperties:(id)@[properties(YES)]];
    assert(completions == 1 && cameraState == expected && !pendingStatus);
}
static void removalTests(void) {
    for (int scenario = 0; scenario < 5; ++scenario) {
        requests = [NSMutableArray array]; alerts = [NSMutableArray array]; completions = 0;
        __block PLANKCameraRemovalResult result = PLANKCameraRemovalFailed;
        PLANKMacRemoveCameraExtension(^(PLANKCameraRemovalResult value) { result = value; ++completions; });
        assert(requests.count == 1 && completions == 0);
        OSSystemExtensionRequest *request = requests.lastObject;
        PLANKCameraActivation *delegate = (id)request.delegate;
        assert([delegate request:request actionForReplacingExtension:(id)properties(YES)
            withExtension:(id)properties(YES)] == OSSystemExtensionReplacementActionCancel);
        __block unsigned refused = 0;
        PLANKMacRemoveCameraExtension(^(PLANKCameraRemovalResult value) {
            assert(value == PLANKCameraRemovalFailed); ++refused;
        });
        assert(refused == 1 && requests.count == 1);
        // Any OS approval prompt stays OS-owned. No PLANK modal can hide the
        // terminal status or prevent its deadline from expiring.
        [delegate requestNeedsUserApproval:request];
        assert(alerts.count == 0 && completions == 0);
        if (scenario < 2) {
            [delegate request:request didFinishWithResult:scenario == 0 ?
                OSSystemExtensionRequestCompleted : OSSystemExtensionRequestWillCompleteAfterReboot];
        } else if (scenario == 2) {
            [delegate request:request didFailWithError:[NSError errorWithDomain:OSSystemExtensionErrorDomain
                code:OSSystemExtensionErrorRequestCanceled userInfo:nil]];
        } else if (scenario == 3) {
            [delegate removalTimedOut];
        } else {
            [delegate request:request didFinishWithResult:(OSSystemExtensionRequestResult)99];
        }
        assert(result == (scenario == 0 ? PLANKCameraRemovalComplete :
            scenario == 1 ? PLANKCameraRemovalRestartRequired : PLANKCameraRemovalFailed));
        assert(completions == 1 && alerts.count == 0 && !pending);
        // A late completion/approval/deadline never changes the final result,
        // displays a setup dialog, or clears a subsequent request.
        PLANKMacRemoveCameraExtension(^(PLANKCameraRemovalResult value) { (void)value; });
        PLANKCameraActivation *next = pending;
        [delegate request:request didFinishWithResult:OSSystemExtensionRequestCompleted];
        [delegate requestNeedsUserApproval:request];
        [delegate removalTimedOut];
        assert(completions == 1 && alerts.count == 0 && pending == next);
        [next removalTimedOut];
        assert(!pending);
    }
}
static void tests(void) {
    removalTests();
    statusTest(@[], PLANKCameraDisabled);
    statusTest(@[properties(YES)], PLANKCameraEnabled);
    statusTest(@[properties(NO)], PLANKCameraDisabled);
    TestProperties *old = properties(YES); old.isUninstalling = YES;
    statusTest(@[old], PLANKCameraRemoving);
    statusTest(@[old, properties(YES)], PLANKCameraEnabled);
    TestProperties *awaiting = properties(YES); awaiting.isAwaitingUserApproval = YES;
    statusTest(@[awaiting], PLANKCameraAwaitingApproval);
    TestProperties *unrelated = properties(YES); unrelated.bundleIdentifier = @"org.example.OtherCamera";
    statusTest(@[unrelated], PLANKCameraDisabled);

    OSSystemExtensionRequest *request = begin();
    [request.delegate request:request didFailWithError:[NSError errorWithDomain:OSSystemExtensionErrorDomain
        code:OSSystemExtensionErrorMissingEntitlement userInfo:nil]];
    assert(completions == 1 && cameraState == PLANKCameraUnknown && alerts.count == 0);

    // Inspection never activates an extension. Explicit setup still supports
    // approved-version replacement and explains approval/reboot/failure.
    for (int scenario = 0; scenario < 3; ++scenario) {
        requests = [NSMutableArray array]; alerts = [NSMutableArray array]; completions = 0;
        PLANKMacRequestCameraExtension(YES, ^(BOOL success) {
            assert(success == (scenario == 0)); ++completions;
        });
        request = requests.lastObject;
        assert([request.delegate request:request actionForReplacingExtension:(id)properties(YES)
            withExtension:(id)properties(YES)] == OSSystemExtensionReplacementActionReplace);
        [request.delegate requestNeedsUserApproval:request];
        assert(alerts.count == 1 && [alerts.lastObject.informativeText containsString:@"\n"]);
        if (scenario < 2)
            [request.delegate request:request didFinishWithResult:scenario == 0 ?
                OSSystemExtensionRequestCompleted : OSSystemExtensionRequestWillCompleteAfterReboot];
        else [request.delegate request:request didFailWithError:[NSError errorWithDomain:OSSystemExtensionErrorDomain
            code:OSSystemExtensionErrorValidationFailed userInfo:nil]];
        assert(completions == 1 && !pending);
    }
    request = begin();
    id<OSSystemExtensionRequestDelegate> status = request.delegate;
    __block unsigned busy = 0;
    PLANKMacCheckCameraExtension(^(PLANKCameraStatus state) { assert(state == PLANKCameraUnknown); ++busy; });
    assert(busy == 1 && requests.count == 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        assert(completions == 1 && cameraState == PLANKCameraUnknown);
        [status request:request foundProperties:(id)@[properties(YES)]];
        assert(completions == 1 && requests.count == 1 && alerts.count == 0);
        puts("Camera status/activation/removal: verified states, upgrade, approval, cancellation, reboot, timeout and stale callbacks passed");
        exit(0);
    });
}
int main(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ tests(); });
        dispatch_main();
    }
}
