// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

#ifndef PLANK_MIC_DEVICE_UID
#define PLANK_MIC_DEVICE_UID "la.instinctual.PLANK.Microphone"
#endif
static inline AudioObjectID PLANKMicDeviceForUID(NSString *uid) {
    if (!uid.length) return kAudioObjectUnknown;
    CFStringRef value = (__bridge CFStringRef)uid;
    AudioObjectID device = kAudioObjectUnknown;
    AudioValueTranslation translation = {&value, sizeof(value), &device, sizeof(device)};
    UInt32 size = sizeof(translation);
    AudioObjectPropertyAddress property = {kAudioHardwarePropertyDeviceForUID,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &translation)) return kAudioObjectUnknown;
    return device;
}
static inline AudioObjectID PLANKMicDefaultInput(void) {
    AudioObjectID device = kAudioObjectUnknown; UInt32 size = sizeof(device);
    AudioObjectPropertyAddress property = {kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &device)) return kAudioObjectUnknown;
    return device;
}
static inline NSString *PLANKMicDeviceUID(AudioObjectID device) {
    if (!device) return nil;
    CFStringRef uid = NULL; UInt32 size = sizeof(uid);
    AudioObjectPropertyAddress property = {kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &uid)) return nil;
    return CFBridgingRelease(uid);
}
static inline BOOL PLANKMicSetDefaultInput(AudioObjectID device) {
    AudioObjectPropertyAddress property = {kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, sizeof(device), &device) == noErr;
}

// One broker lease owns this object. Retain the UID, never an ephemeral device
// ID. A user-selected replacement wins. Silence/mute does not release ownership.
@interface PLANKMacMicrophoneSelection : NSObject
- (BOOL)select;
- (void)restore;
@end
