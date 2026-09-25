// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only timing inventory. No IO, capture, routing or writes.
// Default: PLANK Output. --all: compare all installed device clocks.
#include <CoreAudio/CoreAudio.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include "../../apps/host/macos/audio-device/output-format.h"

static AudioObjectPropertyAddress property(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
}
static void inspect(AudioObjectID device) {
    AudioObjectPropertyAddress address = property(kAudioObjectPropertyName);
    CFStringRef name = NULL; UInt32 size = sizeof(name);
    OSStatus status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name);
    char label[512] = "unknown";
    if (!status && name) {
        CFStringGetCString(name, label, sizeof(label), kCFStringEncodingUTF8);
        CFRelease(name);
    }
    printf("device=%u name=%s\n", (unsigned)device, label);
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
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--all")) {
        AudioObjectID devices[256]; UInt32 bytes = sizeof(devices);
        AudioObjectPropertyAddress address = property(kAudioHardwarePropertyDevices);
        OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
            0, NULL, &bytes, devices);
        if (status || bytes > sizeof(devices) || bytes % sizeof(devices[0])) return 1;
        for (unsigned i = 0; i < bytes / sizeof(devices[0]); ++i) inspect(devices[i]);
        return 0;
    }
    if (argc != 1) { fprintf(stderr, "Usage: output-device-timing [--all]\n"); return 2; }
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
    inspect(device);
    return 0;
}
