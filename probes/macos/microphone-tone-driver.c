// SPDX-License-Identifier: GPL-3.0-or-later
// Developer-only HAL load/clock probe. Never link this into the product.
// It publishes a distinctly named test input and generates a -24 dBFS tone.
// It does not access any physical microphone, files or network endpoints.
#define PLANKMicrophoneFactory PLANKMicrophoneBaseFactory
#include "../../apps/host/macos/audio-device/microphone-driver.c"
#undef PLANKMicrophoneFactory

static OSStatus probeGet(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                         const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                         const void *qualifier, UInt32 capacity, UInt32 *actual, void *data) {
    if (!address || !actual) return kAudioHardwareIllegalOperationError;
    CFStringRef value = NULL;
    if (address->mSelector == kAudioObjectPropertyName) value = CFSTR("PLANK Microphone Probe");
    if (object == MicDevice && address->mSelector == kAudioDevicePropertyDeviceUID)
        value = CFSTR("la.instinctual.PLANK.Microphone.Probe");
    if (object == MicDevice && address->mSelector == kAudioDevicePropertyModelUID)
        value = CFSTR("la.instinctual.PLANK.Microphone.Probe.Model");
    if (value) {
        if (capacity < sizeof(value) || !data) return kAudioHardwareBadPropertySizeError;
        CFRetain(value); memcpy(data, &value, sizeof(value)); *actual = sizeof(value); return noErr;
    }
    if (object == kAudioObjectPlugInObject && address->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
        if (qualifierSize != sizeof(CFStringRef) || !qualifier || !data || capacity < sizeof(UInt32))
            return kAudioHardwareBadPropertySizeError;
        CFStringRef uid; memcpy(&uid, qualifier, sizeof(uid));
        UInt32 device = uid && CFEqual(uid, CFSTR("la.instinctual.PLANK.Microphone.Probe")) ? MicDevice : kAudioObjectUnknown;
        memcpy(data, &device, sizeof(device)); *actual = sizeof(device); return noErr;
    }
    return get(driver, object, pid, address, qualifierSize, qualifier, capacity, actual, data);
}
static OSStatus probeIO(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream,
                        UInt32 client, UInt32 operation, UInt32 frames,
                        const AudioServerPlugInIOCycleInfo *cycle, void *main, void *secondary) {
    OSStatus status = performIO(driver, device, stream, client, operation, frames, cycle, main, secondary);
    if (status || !atomic_load(&running) || !(cycle->mInputTime.mFlags & kAudioTimeStampSampleTimeValid) ||
        !isfinite(cycle->mInputTime.mSampleTime) || cycle->mInputTime.mSampleTime < 0) return status;
    float *samples = main;
    for (UInt32 i = 0; i < frames; i++) {
        samples[2*i] = .0625f * (float)sin(fmod(cycle->mInputTime.mSampleTime + i, 48) * 2 * M_PI / 48);
        samples[2*i+1] = .03125f * (float)sin(fmod(cycle->mInputTime.mSampleTime + i, 32) * 2 * M_PI / 32);
    }
    return noErr;
}
__attribute__((visibility("default")))
void *PLANKMicrophoneFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    void *driver = PLANKMicrophoneBaseFactory(allocator, type);
    if (driver) { interface.GetPropertyData = probeGet; interface.DoIOOperation = probeIO; }
    return driver;
}
