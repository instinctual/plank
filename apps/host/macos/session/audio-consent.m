// SPDX-License-Identifier: GPL-3.0-or-later
#import "audio-consent.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <string.h>
#include <unistd.h>

static OSStatus discardAudio(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime; (void)outputTime; (void)context;
    if (output) for (UInt32 i = 0; i < output->mNumberBuffers; i++)
        if (output->mBuffers[i].mData)
            memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    return noErr;
}

@implementation PLANKMacAudioConsent {
    dispatch_queue_t _queue;
    AudioObjectID _tap, _device;
    AudioDeviceIOProcID _io;
    BOOL _started, _used;
}
- (instancetype)init {
    self = [super init];
    if (self) _queue = dispatch_queue_create("la.instinctual.PLANK.audio-consent", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (void)cleanup {
    if (_started) AudioDeviceStop(_device, _io);
    if (_io) AudioDeviceDestroyIOProcID(_device, _io);
    if (_device) AudioHardwareDestroyAggregateDevice(_device);
    if (_tap) AudioHardwareDestroyProcessTap(_tap);
    _started = NO; _io = NULL; _device = _tap = kAudioObjectUnknown;
}
- (BOOL)prepare {
    // An inclusive empty allowlist intentionally captures no application's
    // output. Do not use the global/excluding-processes initializer here.
    CATapDescription *description = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[]];
    description.name = @"PLANK Audio Permission Setup";
    description.privateTap = YES;
    description.processRestoreEnabled = NO;
    description.exclusive = NO;
    description.muteBehavior = CATapUnmuted;
    if (AudioHardwareCreateProcessTap(description, &_tap)) return NO;
    NSDictionary *specification = @{
        @kAudioAggregateDeviceNameKey: @"PLANK Audio Permission Setup",
        @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapAutoStartKey: @NO,
        @kAudioAggregateDeviceTapListKey: @[@{
            @kAudioSubTapUIDKey: description.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey: @YES}]
    };
    if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)specification, &_device) ||
        AudioDeviceCreateIOProcID(_device, discardAudio, NULL, &_io) || AudioDeviceStart(_device, _io)) return NO;
    _started = YES;
    return YES;
}
- (void)startWithCompletion:(void (^)(BOOL))completion {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (_used || geteuid() == 0) { completion(NO); return; }
    _used = YES;
    // HAL may wait for consent. Keep the app's main event loop responsive,
    // and keep these objects alive until the setup window is closed.
    dispatch_async(_queue, ^{
        BOOL started = [self prepare];
        if (!started) [self cleanup];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(started); });
    });
}
- (void)stopWithCompletion:(void (^)(void))completion {
    dispatch_assert_queue(dispatch_get_main_queue());
    dispatch_async(_queue, ^{
        [self cleanup];
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}
@end
