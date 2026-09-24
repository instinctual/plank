// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only timing inventory of PLANK Output. No IO, capture, routing or writes.
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include "../../apps/host/macos/audio-device/output-format.h"

static AudioObjectPropertyAddress property(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
}
int main(void) {
    CFStringRef uid = CFSTR(PLANK_OUTPUT_DEVICE_UID);
    AudioObjectID device = kAudioObjectUnknown;
    AudioValueTranslation translation = {&uid, sizeof(uid), &device, sizeof(device)};
    AudioObjectPropertyAddress address = property(kAudioHardwarePropertyDeviceForUID);
    UInt32 size = sizeof(translation);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
        0, NULL, &size, &translation);
    if (status || !device) {
        fprintf(stderr, "output_timing=unavailable status=%d\n", (int)status);
        return 1;
    }
    const struct { const char *name; AudioObjectPropertySelector selector; } integers[] = {
        {"buffer_frames", kAudioDevicePropertyBufferFrameSize},
        {"clock_domain", kAudioDevicePropertyClockDomain},
        {"timestamp_period", kAudioDevicePropertyZeroTimeStampPeriod},
        {"running", kAudioDevicePropertyDeviceIsRunning},
    };
    for (unsigned i = 0; i < sizeof(integers) / sizeof(integers[0]); ++i) {
        UInt32 value = 0; size = sizeof(value); address = property(integers[i].selector);
        status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value);
        printf("%s=%u status=%d\n", integers[i].name, (unsigned)value, (int)status);
    }
    const struct { const char *name; AudioObjectPropertySelector selector; } rates[] = {
        {"nominal_rate", kAudioDevicePropertyNominalSampleRate},
        {"actual_rate", kAudioDevicePropertyActualSampleRate},
    };
    for (unsigned i = 0; i < sizeof(rates) / sizeof(rates[0]); ++i) {
        Float64 value = 0; size = sizeof(value); address = property(rates[i].selector);
        status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value);
        printf("%s=%.6f status=%d\n", rates[i].name, value, (int)status);
    }
    AudioValueRange range = {0}; size = sizeof(range);
    address = property(kAudioDevicePropertyBufferFrameSizeRange);
    status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &range);
    printf("buffer_range=%.0f..%.0f status=%d\n", range.mMinimum, range.mMaximum, (int)status);
    return 0;
}
