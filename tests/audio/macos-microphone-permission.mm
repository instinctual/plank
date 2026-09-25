// SPDX-License-Identifier: GPL-3.0-or-later
// Actual permission helper with an AVFoundation fake: no TCC or microphone.
#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#include <cassert>
#include <initializer_list>
static AVAuthorizationStatus status;
static unsigned requests;
static void (^decision)(BOOL);
@interface ConsentFixture : NSObject
+ (AVAuthorizationStatus)authorizationStatusForMediaType:(AVMediaType)type;
+ (void)requestAccessForMediaType:(AVMediaType)type completionHandler:(void (^)(BOOL))completion;
@end
@implementation ConsentFixture
+ (AVAuthorizationStatus)authorizationStatusForMediaType:(AVMediaType)type {
    assert([type isEqual:AVMediaTypeAudio]); return status;
}
+ (void)requestAccessForMediaType:(AVMediaType)type completionHandler:(void (^)(BOOL))completion {
    assert([type isEqual:AVMediaTypeAudio] && NSThread.isMainThread);
    requests++; decision = completion;
}
@end
#define AVCaptureDevice ConsentFixture
#include "../../apps/client/app/streaming/audio/macmicrophonepermission.mm"
int main() { @autoreleasepool {
    for (auto existing : {AVAuthorizationStatusAuthorized, AVAuthorizationStatusDenied, AVAuthorizationStatusRestricted}) {
        status = existing;
        unsigned completed = 0;
        plankMacRequestMicrophonePermission([&] { completed++; });
        assert(completed == 1 && requests == 0);
        assert(plankMacMicrophonePermission() == (existing == AVAuthorizationStatusAuthorized ? 1 : -1));
    }
    for (bool allowed : {false, true}) {
        status = AVAuthorizationStatusNotDetermined; requests = 0;
        unsigned completed = 0;
        assert(plankMacMicrophonePermission() == 0 && requests == 0);
        plankMacRequestMicrophonePermission([&] { assert(NSThread.isMainThread); completed++; });
        assert(completed == 0 && requests == 1 && decision);
        status = allowed ? AVAuthorizationStatusAuthorized : AVAuthorizationStatusDenied;
        decision(allowed); decision = nil;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (!completed && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        assert(completed == 1 && requests == 1);
        assert(plankMacMicrophonePermission() == (allowed ? 1 : -1));
    }
    puts("macos_microphone_launch_consent=pass real_permission=not-tested");
    return 0;
} }
