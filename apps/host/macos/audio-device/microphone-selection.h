// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include "microphone-format.h"

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
// A matching UID alone is insufficient after a driver upgrade. A still-loaded
// mono driver cannot accept the stereo producer layout and is not advertised.
static inline BOOL PLANKMicDeviceHasCurrentFormat(AudioObjectID device) {
    if (!device) return NO;
    AudioStreamID stream = 0; UInt32 size = sizeof(stream);
    AudioObjectPropertyAddress property = {kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &stream) ||
        size != sizeof(stream) || !stream) return NO;
    AudioStreamBasicDescription format = {0}; size = sizeof(format);
    property = (AudioObjectPropertyAddress){kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return !AudioObjectGetPropertyData(stream, &property, 0, NULL, &size, &format) &&
        size == sizeof(format) && format.mSampleRate == PLANKMicRate &&
        format.mFormatID == kAudioFormatLinearPCM &&
        format.mFormatFlags == kAudioFormatFlagsNativeFloatPacked &&
        format.mChannelsPerFrame == PLANKMicChannels && format.mBitsPerChannel == 32 &&
        format.mFramesPerPacket == 1 && format.mBytesPerFrame == PLANKMicChannels * sizeof(float) &&
        format.mBytesPerPacket == format.mBytesPerFrame;
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
