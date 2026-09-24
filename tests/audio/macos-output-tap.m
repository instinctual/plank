// SPDX-License-Identifier: GPL-3.0-or-later
// Production tap preparation with read-only HAL fixtures. Stop before audio IO:
// no real tap, audio IO, permission prompt or output change occurs.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import "../../apps/host/macos/audio-device/output-format.h"
#include <assert.h>

static BOOL outputPresent = YES, muted;
static Float32 outputGain = 0.25f;
static CATapDescription *created;
static NSDictionary *aggregate;
static BOOL expectedClock = YES;
static unsigned clockReads, rateRequests, destroyedTaps, destroyedAggregates;
static unsigned globalListeners, outputListeners;
static OSStatus fakeGet(AudioObjectID object, const AudioObjectPropertyAddress *address,
                        UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    assert(!qualifierSize && !qualifier);
    if (object == 142) {
        assert(address->mSelector == kAudioAggregateDevicePropertyMainSubDevice && *size == sizeof(CFStringRef));
        CFStringRef uid = expectedClock ? CFSTR(PLANK_OUTPUT_DEVICE_UID) : CFSTR("unexpected-clock");
        CFRetain(uid); *(CFStringRef *)data = uid; ++clockReads;
        return noErr;
    }
    if (object == kAudioObjectSystemObject) {
        // A default-device read would make the physical speaker's gain affect
        // PLANK Output. Resolve only the stable virtual-output UID.
        assert(address->mSelector == kAudioHardwarePropertyDeviceForUID && *size == sizeof(AudioValueTranslation));
        AudioValueTranslation *translation = data;
        assert(CFEqual(*(CFStringRef *)translation->mInputData, CFSTR(PLANK_OUTPUT_DEVICE_UID)));
        *(AudioObjectID *)translation->mOutputData = outputPresent ? 42 : 0;
        return noErr;
    }
    assert(object == 42 && address->mScope == kAudioObjectPropertyScopeOutput);
    if (address->mSelector == kAudioDevicePropertyVolumeScalar) {
        assert(*size == sizeof(Float32)); *(Float32 *)data = outputGain;
    } else {
        assert(address->mSelector == kAudioDevicePropertyMute && *size == sizeof(UInt32));
        *(UInt32 *)data = muted;
    }
    return noErr;
}
static Boolean fakeHas(AudioObjectID object, const AudioObjectPropertyAddress *address) {
    assert(object == 42 && address->mScope == kAudioObjectPropertyScopeOutput);
    return address->mElement == kAudioObjectPropertyElementMain &&
        (address->mSelector == kAudioDevicePropertyVolumeScalar || address->mSelector == kAudioDevicePropertyMute);
}
static OSStatus fakeAdd(AudioObjectID object, const AudioObjectPropertyAddress *address,
                        dispatch_queue_t queue, AudioObjectPropertyListenerBlock block) {
    assert(queue && block);
    if (object == kAudioObjectSystemObject) {
        assert(address->mSelector == kAudioHardwarePropertyDevices); ++globalListeners;
    } else {
        assert(object == 42 && address->mScope == kAudioObjectPropertyScopeOutput); ++outputListeners;
    }
    return noErr;
}
static OSStatus fakeRemove(AudioObjectID object, const AudioObjectPropertyAddress *address,
                           dispatch_queue_t queue, AudioObjectPropertyListenerBlock block) {
    assert(queue && block);
    if (object == kAudioObjectSystemObject) {
        assert(address->mSelector == kAudioHardwarePropertyDevices && globalListeners); --globalListeners;
    } else {
        assert(object == 42 && outputListeners); --outputListeners;
    }
    return noErr;
}
static OSStatus fakeCreate(CATapDescription *description, AudioObjectID *tap) {
    assert(tap && !*tap); created = description; *tap = 141;
    return noErr;
}
static OSStatus fakeAggregate(CFDictionaryRef description, AudioObjectID *device) {
    assert(device && !*device); aggregate = [(__bridge NSDictionary *)description copy]; *device = 142;
    return noErr;
}
static OSStatus fakeSet(AudioObjectID object, const AudioObjectPropertyAddress *address,
                        UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    assert(object == 142 && address->mSelector == kAudioDevicePropertyNominalSampleRate &&
        !qualifierSize && !qualifier && size == sizeof(Float64) && *(const Float64 *)data == 48000);
    ++rateRequests;
    return kAudioHardwareUnspecifiedError; // end preparation before IO/format setup
}
static OSStatus fakeDestroyTap(AudioObjectID object) {
    assert(object == 141); ++destroyedTaps; return noErr;
}
static OSStatus fakeDestroyAggregate(AudioObjectID object) {
    assert(object == 142); ++destroyedAggregates; return noErr;
}
#define AudioObjectGetPropertyData fakeGet
#define AudioObjectSetPropertyData fakeSet
#define AudioObjectHasProperty fakeHas
#define AudioObjectAddPropertyListenerBlock fakeAdd
#define AudioObjectRemovePropertyListenerBlock fakeRemove
#define AudioHardwareCreateProcessTap fakeCreate
#define AudioHardwareCreateAggregateDevice fakeAggregate
#define AudioHardwareDestroyProcessTap fakeDestroyTap
#define AudioHardwareDestroyAggregateDevice fakeDestroyAggregate
#include "../../apps/host/macos/media/audio-tap.m"

@interface TestTap : PLANKMacAudioTap
@property(copy) NSArray<NSNumber *> *allowed;
@end
@implementation TestTap
- (NSArray<NSNumber *> *)ownedAudioProcesses { return _allowed; }
@end

static void exercise(NSArray<NSNumber *> *allowed, BOOL present, BOOL matchingClock) {
    outputPresent = present; muted = NO; created = nil; aggregate = nil; expectedClock = matchingClock;
    clockReads = rateRequests = destroyedTaps = destroyedAggregates = 0;
    dispatch_queue_t owner = dispatch_queue_create("plank.test.output-tap-owner", DISPATCH_QUEUE_SERIAL);
    TestTap *tap = [[TestTap alloc] initWithQueue:owner sample:^BOOL(CMSampleBufferRef sample) {
        (void)sample; assert(0); return NO;
    } failed:^{ assert(0); }];
    assert(tap); tap.allowed = allowed;
    dispatch_queue_t control = [tap valueForKey:@"control"];
    dispatch_sync(control, ^{ assert(![tap prepare]); });
    dispatch_sync(owner, ^{});
    if (present) {
        assert(created && [created.deviceUID isEqualToString:@PLANK_OUTPUT_DEVICE_UID]);
        assert([created.stream isEqual:@0] && !created.isMixdown && !created.isExclusive);
        assert(created.isPrivate && !created.isProcessRestoreEnabled && created.muteBehavior == CATapUnmuted);
        assert([created.processes isEqual:allowed]);
        assert([aggregate[@kAudioAggregateDeviceMainSubDeviceKey] isEqual:@PLANK_OUTPUT_DEVICE_UID]);
        assert([aggregate[@kAudioAggregateDeviceSubDeviceListKey] isEqual:@[@{
            @kAudioSubDeviceUIDKey: @PLANK_OUTPUT_DEVICE_UID}]]);
        assert(!aggregate[@kAudioAggregateDeviceClockDeviceKey]); // no separate clock overrides the output
        assert([aggregate[@kAudioAggregateDeviceIsPrivateKey] boolValue]);
        assert(![aggregate[@kAudioAggregateDeviceTapAutoStartKey] boolValue]);
        assert(([aggregate[@kAudioAggregateDeviceTapListKey] isEqual:@[@{
            @kAudioSubTapUIDKey: created.UUID.UUIDString, @kAudioSubTapDriftCompensationKey: @YES}]]));
        assert(clockReads == 1 && rateRequests == (matchingClock ? 1u : 0u));
        assert([[tap valueForKey:@"leftGain"] floatValue] == outputGain);
        assert([[tap valueForKey:@"rightGain"] floatValue] == outputGain);
        muted = YES;
        dispatch_sync(control, ^{ [tap refreshOutputVolume]; }); dispatch_sync(owner, ^{});
        assert([[tap valueForKey:@"leftGain"] floatValue] == 0);
        assert([[tap valueForKey:@"rightGain"] floatValue] == 0);
    } else {
        assert(!created && !aggregate && !clockReads && !rateRequests && !outputListeners);
        assert([[tap valueForKey:@"leftGain"] floatValue] == 0);
    }
    dispatch_sync(owner, ^{ [tap stopWithCompletion:^{}]; });
    dispatch_sync(control, ^{}); dispatch_sync(owner, ^{});
    assert(!globalListeners && !outputListeners);
    assert(destroyedTaps == (present ? 1u : 0u) && destroyedAggregates == (present ? 1u : 0u));
}
int main(void) { @autoreleasepool {
    exercise(@[@101, @102], YES, YES);
    exercise(@[], YES, YES); // Empty allowlist must remain inclusive, never a global tap.
    exercise(@[@101], YES, NO); // A different clock must fail and release partial resources.
    exercise(@[@101], NO, YES);
    // Even a stopped callback must silence the aggregate's virtual output.
    TapInput input; PLANKTapBufferInit(&input.buffer); atomic_store(&input.buffer.stopped, true);
    float samples[8]; for (unsigned i = 0; i < 8; ++i) samples[i] = 0.5f;
    AudioBufferList output = {1, {{2, sizeof(samples), samples}}};
    assert(receive(142, NULL, NULL, NULL, &output, NULL, &input) == noErr);
    for (unsigned i = 0; i < 8; ++i) assert(samples[i] == 0);
    puts("output_tap_device_scope_clock_unmuted_allowlist_fixed_gain_missing_device=pass real_hal=0");
} }
