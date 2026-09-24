// SPDX-License-Identifier: GPL-3.0-or-later
// Real screen-capture audio lifecycle with fake tap/encoder boundaries. No
// ScreenCaptureKit, HAL, transport, permissions or hardware activity.
#import "screen-capture.h"
#import "audio-tap.h"
#import "../../apps/host/macos/audio-device/output-route.h"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

@interface PLANKMacScreenCapture (AudioTestBoundary)
- (void)createAudioEncoder;
- (void)createDesktopAudioTap;
- (void)startDesktopAudio;
- (void)disableDesktopAudio;
- (void)stopDesktopAudio;
@end
@interface FakeTap : NSObject
@property(copy) void (^stopped)(void);
@property BOOL ready;
- (void)startWithCompletion:(void (^)(BOOL))completion;
- (void)stopWithCompletion:(void (^)(void))completion;
@end
@implementation FakeTap
- (void)startWithCompletion:(void (^)(BOOL))completion { completion(_ready); }
- (void)stopWithCompletion:(void (^)(void))completion { assert(!_stopped); _stopped = [completion copy]; }
@end
@interface FakeRoute : PLANKMacOutputRoute
@property unsigned starts;
@property(copy) void (^restored)(void);
@end
@implementation FakeRoute
- (void)start { ++_starts; }
- (void)stopWithCompletion:(void (^)(void))completion { assert(!_restored); _restored = [completion copy]; }
@end
@interface FakeEncoder : NSObject
- (void)stop;
@end
@implementation FakeEncoder
- (void)stop {}
@end
@interface Capture : PLANKMacScreenCapture
@property unsigned taps;
@property BOOL deny;
@property(copy) void (^created)(void);
@end
@implementation Capture
- (void)createAudioEncoder { [self setValue:[FakeEncoder new] forKey:@"audioEncoder"]; }
- (void)createDesktopAudioTap {
    assert([[self valueForKey:@"audioStopped"] boolValue]);
    FakeTap *tap = [FakeTap new]; tap.ready = !_deny;
    [self setValue:tap forKey:@"audioTap"];
    [self setValue:@NO forKey:@"audioStopped"];
    [self setValue:@NO forKey:@"audioReady"];
    ++_taps;
    if (_created) _created();
}
@end
static void finishTap(FakeTap *tap) {
    assert(tap.stopped); void (^completion)(void) = tap.stopped;
    tap.stopped = nil; completion();
}
static Capture *makeCapture(dispatch_queue_t queue) {
    Capture *capture = [[Capture alloc] initWithDesktopAudioTap:YES];
    [capture setValue:queue forKey:@"queue"];
    [capture createAudioEncoder]; [capture createDesktopAudioTap];
    [capture startDesktopAudio]; return capture;
}
int main(void) {
    alarm(15);
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("plank.test.audio-recovery", DISPATCH_QUEUE_SERIAL);
        // Real capture lifecycle must wait for output restoration before
        // releasing tap suppression. Denied capture never selects an output.
        dispatch_sync(queue, ^{
            Capture *routed = [[Capture alloc] initWithDesktopAudioTap:YES];
            [routed setValue:queue forKey:@"queue"];
            [routed createAudioEncoder]; [routed createDesktopAudioTap];
            FakeRoute *route = [FakeRoute new];
            routed.outputRoute = ^PLANKMacOutputRoute *(dispatch_queue_t owner) { assert(owner == queue); return route; };
            [routed startDesktopAudio]; assert(route.starts == 1);
            FakeTap *tap = [routed valueForKey:@"audioTap"];
            [routed stopDesktopAudio]; assert(route.restored && !tap.stopped);
            route.restored(); route.restored = nil;
            assert(tap.stopped); finishTap(tap);
            assert([[routed valueForKey:@"audioStopped"] boolValue]);
            Capture *deniedRoute = [[Capture alloc] initWithDesktopAudioTap:YES]; deniedRoute.deny = YES;
            [deniedRoute setValue:queue forKey:@"queue"];
            [deniedRoute createAudioEncoder]; [deniedRoute createDesktopAudioTap];
            deniedRoute.outputRoute = ^PLANKMacOutputRoute *(dispatch_queue_t owner) { (void)owner; assert(0); return nil; };
            FakeTap *deniedTap = [deniedRoute valueForKey:@"audioTap"];
            [deniedRoute startDesktopAudio]; finishTap(deniedTap);
        });
        __block Capture *capture;
        dispatch_sync(queue, ^{ capture = makeCapture(queue); });
        for (unsigned attempt = 0; attempt < 3; ++attempt) {
            dispatch_semaphore_t created = dispatch_semaphore_create(0);
            __block FakeTap *old;
            dispatch_sync(queue, ^{
                capture.created = ^{ dispatch_semaphore_signal(created); };
                old = [capture valueForKey:@"audioTap"];
                [capture disableDesktopAudio];
                assert(![capture valueForKey:@"audioTap"]);
                assert(![[capture valueForKey:@"audioStopped"] boolValue]);
                [capture disableDesktopAudio]; // duplicate notification cannot restart twice
            });
            assert(dispatch_semaphore_wait(created, dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC)) != 0);
            dispatch_sync(queue, ^{ finishTap(old); });
            assert(!dispatch_semaphore_wait(created, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)));
            dispatch_sync(queue, ^{
                assert(capture.taps == attempt + 2);
                assert([[capture valueForKey:@"audioDiscontinuity"] boolValue]);
                assert([[capture valueForKey:@"audioReady"] boolValue]);
            });
        }
        dispatch_sync(queue, ^{
            FakeTap *tap = [capture valueForKey:@"audioTap"];
            [capture disableDesktopAudio]; finishTap(tap);
            assert(![[capture valueForKey:@"audioRestartPending"] boolValue]);
            capture.created = nil;
        });
        __block Capture *cancelled, *denied;
        dispatch_sync(queue, ^{
            cancelled = makeCapture(queue);
            FakeTap *tap = [cancelled valueForKey:@"audioTap"];
            [cancelled disableDesktopAudio]; finishTap(tap);
            [cancelled stopWithCompletion:^{}]; // cancels delayed restart
            denied = [[Capture alloc] initWithDesktopAudioTap:YES]; denied.deny = YES;
            [denied setValue:queue forKey:@"queue"];
            [denied createAudioEncoder]; [denied createDesktopAudioTap];
            FakeTap *deniedTap = [denied valueForKey:@"audioTap"];
            [denied startDesktopAudio]; finishTap(deniedTap);
            assert(![[denied valueForKey:@"audioRestartPending"] boolValue]);
        });
        dispatch_semaphore_t settled = dispatch_semaphore_create(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200*NSEC_PER_MSEC), queue, ^{
            assert(cancelled.taps == 1 && denied.taps == 1 && capture.taps == 4);
            dispatch_semaphore_signal(settled);
        });
        assert(!dispatch_semaphore_wait(settled, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)));
        puts("macos_audio_recovery=pass bounded=1 teardown_barrier=1 duplicate=1 denied=1 cancel=1 real_hal=0");
    }
}
