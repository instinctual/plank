// SPDX-License-Identifier: GPL-3.0-or-later
// Production tap preparation with read-only HAL fixtures. Stop at tap creation:
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
static unsigned globalListeners, outputListeners;
static OSStatus fakeGet(AudioObjectID object, const AudioObjectPropertyAddress *address,
                        UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    assert(!qualifierSize && !qualifier);
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
    assert(tap && !*tap); created = description;
    return kAudioHardwareUnspecifiedError; // end preparation before real HAL creation
}
#define AudioObjectGetPropertyData fakeGet
#define AudioObjectHasProperty fakeHas
#define AudioObjectAddPropertyListenerBlock fakeAdd
#define AudioObjectRemovePropertyListenerBlock fakeRemove
#define AudioHardwareCreateProcessTap fakeCreate
#include "../../apps/host/macos/media/audio-tap.m"

@interface TestTap : PLANKMacAudioTap
@property(copy) NSArray<NSNumber *> *allowed;
@end
@implementation TestTap
- (NSArray<NSNumber *> *)ownedAudioProcesses { return _allowed; }
@end

static void exercise(NSArray<NSNumber *> *allowed, BOOL present) {
    outputPresent = present; muted = NO; created = nil;
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
        assert([[tap valueForKey:@"leftGain"] floatValue] == outputGain);
        assert([[tap valueForKey:@"rightGain"] floatValue] == outputGain);
        muted = YES;
        dispatch_sync(control, ^{ [tap refreshOutputVolume]; }); dispatch_sync(owner, ^{});
        assert([[tap valueForKey:@"leftGain"] floatValue] == 0);
        assert([[tap valueForKey:@"rightGain"] floatValue] == 0);
    } else {
        assert(!created && !outputListeners); // missing PLANK Output cannot fall back to speakers
        assert([[tap valueForKey:@"leftGain"] floatValue] == 0);
    }
    dispatch_sync(owner, ^{ [tap stopWithCompletion:^{}]; });
    dispatch_sync(control, ^{}); dispatch_sync(owner, ^{});
    assert(!globalListeners && !outputListeners);
}
int main(void) { @autoreleasepool {
    exercise(@[@101, @102], YES);
    exercise(@[], YES); // Empty allowlist must remain inclusive, never a global tap.
    exercise(@[@101], NO);
    puts("output_tap_device_scope_unmuted_allowlist_fixed_gain_missing_device=pass real_hal=0");
} }
