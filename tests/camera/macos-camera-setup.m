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
static OSSystemExtensionRequest *begin(void) {
    assert(!pending && !pendingStatus);
    requests = [NSMutableArray array]; alerts = [NSMutableArray array];
    completions = 0; response = NSAlertFirstButtonReturn;
    PLANKMacShowCameraSetup(^{ ++completions; });
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
static void completeActivation(OSSystemExtensionRequestResult result) {
    assert(requests.count == 2);
    OSSystemExtensionRequest *request = requests.lastObject;
    [request.delegate request:request didFinishWithResult:result];
    assert(!pending && !pendingStatus && completions == 1);
}
static void enabledCamera(void) {
    OSSystemExtensionRequest *request = begin();
    id<OSSystemExtensionRequestDelegate> status = request.delegate;
    TestProperties *old = properties(YES); old.isUninstalling = YES;
    found(request, @[old, properties(YES)]);
    assert(requests.count == 2 && alerts.count == 0 && completions == 0);
    // A duplicate properties completion cannot finish setup while activation
    // is still resolving the bundled version.
    [status request:request didFinishWithResult:OSSystemExtensionRequestCompleted];
    assert(completions == 0 && alerts.count == 0);
    OSSystemExtensionRequest *activation = requests.lastObject;
    assert([activation.delegate request:activation actionForReplacingExtension:(id)properties(YES)
        withExtension:(id)properties(YES)] == OSSystemExtensionReplacementActionReplace);
    completeActivation(OSSystemExtensionRequestCompleted);
    assert(alerts.count == 1 && alerts.lastObject.buttons.count == 1);
    assert([alerts.lastObject.buttons.firstObject isEqualToString:@"Close"]);
    assert([alerts.lastObject.informativeText containsString:@"PLANK Camera is enabled."]);
}
static void optionalCamera(NSArray *values) {
    OSSystemExtensionRequest *request = begin(); found(request, values);
    assert(requests.count == 1 && completions == 1 && alerts.count == 1);
    assert([alerts.lastObject.buttons isEqualToArray:@[@"Close", @"Enable Camera"]]);
}
static void tests(void) {
    enabledCamera();
    optionalCamera(@[]); // First install: no automatic activation.
    optionalCamera(@[properties(NO)]); // User disabled it.
    TestProperties *old = properties(YES); old.isUninstalling = YES;
    optionalCamera(@[old, properties(NO)]); // Retired copy must not override disabled state.
    TestProperties *awaiting = properties(YES); awaiting.isAwaitingUserApproval = YES;
    optionalCamera(@[awaiting]);
    TestProperties *unrelated = properties(YES); unrelated.bundleIdentifier = @"org.example.OtherCamera";
    optionalCamera(@[unrelated]);

    OSSystemExtensionRequest *request = begin();
    [request.delegate request:request didFailWithError:[NSError errorWithDomain:OSSystemExtensionErrorDomain
        code:OSSystemExtensionErrorMissingEntitlement userInfo:nil]];
    assert(requests.count == 1 && completions == 1 && alerts.count == 1);
    assert([alerts.lastObject.informativeText containsString:@"could not be checked"]);
    assert([alerts.lastObject.buttons.lastObject isEqualToString:@"Set Up Camera"]);

    request = begin(); response = NSAlertSecondButtonReturn;
    found(request, @[]); // Only an explicit click enables a first-time camera.
    assert(requests.count == 2 && completions == 0);
    response = NSAlertFirstButtonReturn;
    OSSystemExtensionRequest *activation = requests.lastObject;
    [activation.delegate requestNeedsUserApproval:activation];
    assert(completions == 0 && [alerts.lastObject.informativeText containsString:@"Approve PLANK Camera"]);
    completeActivation(OSSystemExtensionRequestCompleted);

    request = begin(); found(request, @[properties(YES)]);
    completeActivation(OSSystemExtensionRequestWillCompleteAfterReboot);
    assert(alerts.count == 1 && [alerts.lastObject.informativeText containsString:@"Restart this Mac"]);
    assert(![alerts.lastObject.informativeText containsString:@"Camera is enabled"]);

    request = begin(); found(request, @[properties(YES)]);
    activation = requests.lastObject;
    [activation.delegate request:activation didFailWithError:[NSError errorWithDomain:OSSystemExtensionErrorDomain
        code:OSSystemExtensionErrorValidationFailed userInfo:nil]];
    assert(completions == 1 && alerts.count == 1);
    assert([alerts.lastObject.informativeText containsString:@"setup did not complete"]);

    request = begin();
    id<OSSystemExtensionRequestDelegate> status = request.delegate;
    // Let the real timeout run, then deliver a stale response. No auto-activation.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:7];
    while (!completions && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(completions == 1 && requests.count == 1);
    [status request:request foundProperties:(id)@[properties(YES)]];
    assert(completions == 1 && requests.count == 1 && alerts.count == 1);
    puts("Camera setup: enabled/upgrade, disabled, first use, errors, approval, reboot and timeout passed");
}
int main(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{ tests(); exit(0); });
        dispatch_main();
    }
}
