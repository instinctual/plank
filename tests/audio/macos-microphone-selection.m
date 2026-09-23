// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise production ownership with a fake HAL: no system defaults change.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed line %d\n", __LINE__); exit(1); } } while (0)
static AudioObjectID current = 10;
static BOOL previousPresent = YES, failSelect = NO;
static unsigned writes;
static CFStringRef deviceUID(AudioObjectID device) {
    switch (device) {
        case 10: return CFSTR("test.original");
        case 20: return CFSTR("la.instinctual.PLANK.Microphone");
        case 30: return CFSTR("test.user-chosen");
        default: return NULL;
    }
}
static OSStatus fakeGet(AudioObjectID object, const AudioObjectPropertyAddress *property,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    (void)qualifierSize; (void)qualifier; (void)size;
    switch (property->mSelector) {
        case kAudioHardwarePropertyDefaultInputDevice: *(AudioObjectID *)data = current; return noErr;
        case kAudioDevicePropertyDeviceUID: {
            CFStringRef uid = deviceUID(object); if (!uid) return -1;
            *(CFStringRef *)data = CFRetain(uid); return noErr;
        }
        case kAudioHardwarePropertyDeviceForUID: {
            AudioValueTranslation *translation = data;
            CFStringRef uid = *(CFStringRef *)translation->mInputData;
            AudioObjectID found = 0;
            for (AudioObjectID device = 10; device <= 30; device += 10)
                if ((device != 10 || previousPresent) && CFEqual(uid, deviceUID(device))) found = device;
            *(AudioObjectID *)translation->mOutputData = found; return noErr;
        }
        default: return -1;
    }
}
static OSStatus fakeSet(AudioObjectID object, const AudioObjectPropertyAddress *property,
    UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    (void)object; (void)qualifierSize; (void)qualifier;
    CHECK(property->mSelector == kAudioHardwarePropertyDefaultInputDevice && size == sizeof(AudioObjectID));
    if (failSelect) return -1;
    current = *(const AudioObjectID *)data; writes++; return noErr;
}
#define AudioObjectGetPropertyData fakeGet
#define AudioObjectSetPropertyData fakeSet
#include "../../apps/host/macos/audio-device/microphone-selection.m"
int main(void) { @autoreleasepool {
    PLANKMacMicrophoneSelection *owner = [PLANKMacMicrophoneSelection new];
    CHECK([owner select] && current == 20 && writes == 1);
    CHECK([owner select] && writes == 1);
    [owner restore]; CHECK(current == 10 && writes == 2);
    [owner restore]; CHECK(writes == 2);
    CHECK([owner select]); current = 30; [owner restore]; CHECK(current == 30 && writes == 3);
    current = 10; CHECK([owner select]); previousPresent = NO; [owner restore]; CHECK(current == 20 && writes == 4);
    previousPresent = YES; current = 10; failSelect = YES; CHECK(![owner select]); [owner restore]; CHECK(current == 10);
    failSelect = NO; current = 0; CHECK([owner select]); [owner restore]; CHECK(current == 20 && writes == 5);
    CHECK([owner select]); [owner restore]; CHECK(current == 20 && writes == 5);
    current = 10; CHECK([owner select]); owner = nil; CHECK(current == 10 && writes == 7);
    puts("microphone_selection_restore_override_unplug_no_input_failure=pass"); return 0;
} }
