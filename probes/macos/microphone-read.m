// SPDX-License-Identifier: GPL-3.0-or-later
// Read only the synthetic PLANK probe device. No physical-device fallback,
// file recordings or permission-database changes. The explicit restore helper
// changes the default only if the temporary probe is still selected.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>
#include "../../apps/host/macos/audio-device/microphone-format.h"

static _Atomic uint64_t frameCount;
static _Atomic uint64_t audibleCount;
static _Atomic uint64_t badCount;
static _Atomic uint64_t differentCount;
static _Atomic uint64_t channelEnergy[PLANKMicChannels];
static OSStatus readInput(AudioDeviceID device, const AudioTimeStamp *now,
                          const AudioBufferList *input, const AudioTimeStamp *inputTime,
                          AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)output; (void)outputTime; (void)context;
    if (!input || input->mNumberBuffers != 1 || input->mBuffers[0].mNumberChannels != PLANKMicChannels ||
        input->mBuffers[0].mDataByteSize % (PLANKMicChannels*sizeof(float)) || !input->mBuffers[0].mData) {
        atomic_fetch_add(&badCount, 1); return noErr;
    }
    UInt32 count = input->mBuffers[0].mDataByteSize / (PLANKMicChannels*sizeof(float));
    const float *samples = input->mBuffers[0].mData;
    uint64_t audible = 0, bad = 0, different = 0, energy[PLANKMicChannels] = {0};
    for (UInt32 i = 0; i < count; i++) {
        different += samples[2*i] != samples[2*i+1];
        for (unsigned channel = 0; channel < PLANKMicChannels; channel++) {
            float value = samples[i*PLANKMicChannels+channel];
            if (!isfinite(value) || fabsf(value) > .063f) { bad++; continue; }
            if (fabsf(value) > .01f) audible++;
            energy[channel] += (uint64_t)((double)value*value*1e12);
        }
    }
    atomic_fetch_add(&frameCount, count);
    atomic_fetch_add(&audibleCount, audible);
    atomic_fetch_add(&badCount, bad);
    atomic_fetch_add(&differentCount, different);
    for (unsigned channel = 0; channel < PLANKMicChannels; channel++)
        atomic_fetch_add(&channelEnergy[channel], energy[channel]);
    return noErr;
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc == 2 && !strcmp(argv[1], "--default-input-uid")) {
        AudioObjectPropertyAddress property = {kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioDeviceID device = 0; UInt32 size = sizeof(device);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &device)) return 1;
        if (device == kAudioObjectUnknown) { puts("none"); return 0; }
        property.mSelector = kAudioDevicePropertyDeviceUID;
        CFStringRef uid = NULL; size = sizeof(uid);
        if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &uid) || !uid) return 1;
        puts([(__bridge NSString *)uid UTF8String]); CFRelease(uid); return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "--restore-default-input-uid")) {
        AudioObjectPropertyAddress property = {kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioDeviceID current = 0; UInt32 size = sizeof(current);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &current)) return 1;
        property.mSelector = kAudioDevicePropertyDeviceUID;
        CFStringRef uid = NULL; size = sizeof(uid);
        if (AudioObjectGetPropertyData(current, &property, 0, NULL, &size, &uid) || !uid) return 1;
        BOOL ours = CFEqual(uid, CFSTR("la.instinctual.PLANK.Microphone.Probe")); CFRelease(uid);
        if (!ours) { puts("default_input_unchanged=1"); return 0; }
        // With no original input, removing the probe lets Core Audio choose
        // its normal fallback (possibly no input). Do not invent a device.
        if (!strcmp(argv[2], "none")) { puts("default_input_restore_on_probe_removal=1"); return 0; }
        NSString *previous = [NSString stringWithUTF8String:argv[2]];
        CFStringRef previousUID = (__bridge CFStringRef)previous;
        AudioDeviceID device = kAudioObjectUnknown;
        AudioValueTranslation translation = {(void *)&previousUID, sizeof(previousUID), &device, sizeof(device)};
        property.mSelector = kAudioHardwarePropertyDeviceForUID; size = sizeof(translation);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &translation) || !device) return 1;
        property.mSelector = kAudioHardwarePropertyDefaultInputDevice;
        OSStatus result = AudioObjectSetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, sizeof(device), &device);
        printf("default_input_restored=%d\n", result == noErr); return result ? 1 : 0;
    }
    BOOL capture = argc == 2 && !strcmp(argv[1], "--read-test-tone");
    if (argc > 1 && !capture) return 2;
    CFStringRef uid = CFSTR("la.instinctual.PLANK.Microphone.Probe");
    AudioDeviceID device = kAudioObjectUnknown;
    AudioValueTranslation translation = {(void *)&uid, sizeof(uid), &device, sizeof(device)};
    AudioObjectPropertyAddress property = {kAudioHardwarePropertyDeviceForUID,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(translation);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &translation);
    printf("microphone_probe_discovered=%d status=%d\n", status == noErr && device != kAudioObjectUnknown, (int)status);
    if (status || device == kAudioObjectUnknown) return 1;
    property.mSelector = kAudioDevicePropertyNominalSampleRate;
    Float64 rate = 0; size = sizeof(rate);
    status = AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &rate);
    printf("microphone_probe_rate=%.0f status=%d\n", rate, (int)status);
    if (status || rate != 48000) return 1;
    if (!capture) return 0;
    // A GUI bundle requests normal microphone consent. SSH processes must not
    // be given broad system access just to run a synthetic-device test.
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"la.instinctual.PLANK.Microphone.Probe.Reader"]) {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __block BOOL done = NO, granted = NO;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL allowed) {
            dispatch_async(dispatch_get_main_queue(), ^{ granted = allowed; done = YES; });
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
        while (!done && [deadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        printf("microphone_probe_permission=%s\n", granted ? "allowed" : "not-allowed"); fflush(stdout);
        if (!granted) return 1;
    }
    AudioDeviceIOProcID io = NULL;
    status = AudioDeviceCreateIOProcID(device, readInput, NULL, &io);
    if (!status) status = AudioDeviceStart(device, io);
    printf("microphone_probe_start_status=%d\n", (int)status); fflush(stdout);
    if (!status) {
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:3];
        while ([end timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        AudioDeviceStop(device, io);
    }
    if (io) AudioDeviceDestroyIOProcID(device, io);
    uint64_t frames = atomic_load(&frameCount), audible = atomic_load(&audibleCount), bad = atomic_load(&badCount);
    printf("microphone_probe_frames=%llu audible=%llu invalid=%llu\n",
           (unsigned long long)frames, (unsigned long long)audible, (unsigned long long)bad);
    double left = frames ? sqrt(atomic_load(&channelEnergy[0])/1e12/frames) : 0;
    double right = frames ? sqrt(atomic_load(&channelEnergy[1])/1e12/frames) : 0;
    printf("microphone_probe_channels=2 left_rms=%.6f right_rms=%.6f different_frames=%llu\n",
        left, right, (unsigned long long)atomic_load(&differentCount));
    BOOL pass = !status && frames >= 96000 && audible > frames / 2 && !bad &&
        left > .02 && right > .01 && left > right*1.5 && atomic_load(&differentCount) > frames/2;
    printf("microphone_live_tone=%s\n", pass ? "pass" : "fail");
    return pass ? 0 : 1;
} }
