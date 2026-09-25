// SPDX-License-Identifier: GPL-3.0-or-later
// Real consent lifecycle, fake HAL only. Never asks TCC or opens a device.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <unistd.h>
#include <assert.h>

static unsigned calls, failAt, taps, devices, callbacks, starts;
static uid_t fixtureUID = 501;
static AudioDeviceIOProc receive;
static uid_t testUID(void) { return fixtureUID; }
static OSStatus step(void) { return ++calls == failAt ? -1 : noErr; }
static OSStatus createTap(CATapDescription *description, AudioObjectID *tap) {
    assert(description.processes.count == 0 && !description.exclusive && description.privateTap);
    assert(!description.processRestoreEnabled && description.muteBehavior == CATapUnmuted);
    if (step()) return -1;
    taps++; *tap = 10; return noErr;
}
static OSStatus createDevice(CFDictionaryRef raw, AudioObjectID *device) {
    NSDictionary *spec = (__bridge NSDictionary *)raw;
    assert([spec[@kAudioAggregateDeviceIsPrivateKey] boolValue]);
    assert(![spec[@kAudioAggregateDeviceTapAutoStartKey] boolValue]);
    assert(!spec[@kAudioAggregateDeviceSubDeviceListKey] && !spec[@kAudioAggregateDeviceMainSubDeviceKey]);
    assert([spec[@kAudioAggregateDeviceTapListKey] count] == 1);
    if (step()) return -1;
    devices++; *device = 20; return noErr;
}
static OSStatus createIO(AudioDeviceID device, AudioDeviceIOProc proc, void *context, AudioDeviceIOProcID *io) {
    assert(device == 20 && !context); receive = proc;
    if (step()) return -1;
    callbacks++; *io = proc; return noErr;
}
static OSStatus startIO(AudioDeviceID device, AudioDeviceIOProcID io) {
    assert(device == 20 && io == receive);
    if (step()) return -1;
    starts++; return noErr;
}
static OSStatus stopIO(AudioDeviceID device, AudioDeviceIOProcID io) {
    assert(device == 20 && io == receive && starts == 1); starts--; return noErr;
}
static OSStatus destroyIO(AudioDeviceID device, AudioDeviceIOProcID io) {
    assert(device == 20 && io == receive && callbacks == 1 && !starts); callbacks--; return noErr;
}
static OSStatus destroyDevice(AudioDeviceID device) {
    assert(device == 20 && devices == 1 && !callbacks); devices--; return noErr;
}
static OSStatus destroyTap(AudioObjectID tap) {
    assert(tap == 10 && taps == 1 && !devices); taps--; return noErr;
}
#define geteuid testUID
#define AudioHardwareCreateProcessTap createTap
#define AudioHardwareCreateAggregateDevice createDevice
#define AudioDeviceCreateIOProcID createIO
#define AudioDeviceStart startIO
#define AudioDeviceStop stopIO
#define AudioDeviceDestroyIOProcID destroyIO
#define AudioHardwareDestroyAggregateDevice destroyDevice
#define AudioHardwareDestroyProcessTap destroyTap
#include "../../apps/host/macos/session/audio-consent.m"

static void waitUntil(BOOL (^complete)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!complete() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    assert(complete());
}
int main(void) { @autoreleasepool {
    for (unsigned failure = 0; failure <= 4; failure++) {
        failAt = failure; calls = 0;
        PLANKMacAudioConsent *consent = [PLANKMacAudioConsent new];
        __block BOOL done = NO;
        [consent startWithCompletion:^(BOOL started) {
            assert(NSThread.isMainThread && started == (failure == 0)); done = YES;
        }];
        waitUntil(^BOOL { return done; });
        assert(calls == (failure ?: 4));
        if (!failure) {
            // No input data may be read or retained, even with a deliberately
            // unreadable payload. This is consent setup, not a recorder.
            AudioBufferList input = {1, {{2, 16, (void *)1}}};
            float data[4] = {1, 1, 1, 1};
            AudioBufferList output = {1, {{2, sizeof(data), data}}};
            assert(receive(20, NULL, &input, NULL, &output, NULL, NULL) == noErr);
            for (unsigned i = 0; i < 4; i++) assert(data[i] == 0);
        }
        done = NO;
        [consent stopWithCompletion:^{ done = YES; }];
        waitUntil(^BOOL { return done; });
        assert(!taps && !devices && !callbacks && !starts);
        [consent startWithCompletion:^(BOOL started) { assert(!started); }];
        done = NO;
        [consent stopWithCompletion:^{ done = YES; }];
        waitUntil(^BOOL { return done; });
    }
    fixtureUID = 0; calls = 0;
    [[PLANKMacAudioConsent new] startWithCompletion:^(BOOL started) { assert(!started); }];
    assert(!calls);
    puts("macos_startup_audio_consent=pass real_audio_permission=not-tested");
    return 0;
} }
