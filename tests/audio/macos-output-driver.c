// SPDX-License-Identifier: GPL-3.0-or-later
// The real HAL implementation, hosted in-process without installation or IO.
#include "../../apps/host/macos/audio-device/output-driver.c"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

static unsigned notifications;
static OSStatus changed(AudioServerPlugInHostRef owner, AudioObjectID object, UInt32 count,
                        const AudioObjectPropertyAddress *addresses) {
    (void)owner;
    assert((object == OutputDevice || object == OutputVolume || object == OutputMute) && count && addresses);
    notifications++; return noErr;
}
static const AudioServerPlugInHostInterface fakeHost = {.PropertiesChanged = changed};
static AudioObjectPropertyAddress property(UInt32 selector, UInt32 scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}
static void fetch(AudioObjectID object, UInt32 selector, UInt32 scope, UInt32 size, void *value) {
    AudioObjectPropertyAddress address = property(selector, scope); UInt32 actual = 0;
    assert(!get(DRIVER, object, getpid(), &address, 0, NULL, size, &actual, value));
    assert(actual == size);
}
static UInt32 scalar(AudioObjectID object, UInt32 selector, UInt32 scope) {
    UInt32 value; fetch(object, selector, scope, sizeof(value), &value); return value;
}
int main(void) {
    assert(PLANKOutputFactory(NULL, kAudioServerPlugInTypeUUID) == DRIVER);
    assert(!PLANKOutputFactory(NULL, NULL));
    assert(!initialize(DRIVER, &fakeHost));
    assert(!initialize(DRIVER, &fakeHost));
    assert(scalar(OutputStream, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 0);
    assert(scalar(OutputStream, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal) == kAudioStreamTerminalTypeSpeaker);
    assert(scalar(OutputDevice, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 1);
    assert(scalar(OutputDevice, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput) == 1);
    assert(scalar(OutputDevice, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 0);
    AudioObjectPropertyAddress address = property(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    UInt32 size = 100;
    assert(!sizeOf(DRIVER, OutputDevice, 0, &address, 0, NULL, &size) && size == 0);
    AudioObjectID objects[3];
    fetch(OutputDevice, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, sizeof(objects), objects);
    assert(objects[0] == OutputStream && objects[1] == OutputVolume && objects[2] == OutputMute);
    fetch(OutputDevice, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal, 8, objects);
    assert(objects[0] == OutputVolume && objects[1] == OutputMute);
    assert(scalar(OutputVolume, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioVolumeControlClassID);
    assert(scalar(OutputMute, kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal) == kAudioObjectPropertyScopeOutput);
    assert(scalar(OutputMute, kAudioControlPropertyElement, kAudioObjectPropertyScopeGlobal) == 0);
    AudioStreamBasicDescription format;
    fetch(OutputStream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, sizeof(format), &format);
    assert(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2 && format.mBytesPerFrame == 8);
    address = property(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
    assert(!set(DRIVER, OutputStream, 0, &address, 0, NULL, sizeof(format), &format));
    format.mSampleRate = 44100;
    assert(set(DRIVER, OutputStream, 0, &address, 0, NULL, sizeof(format), &format));
    address = property(kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
    Float32 gain = 0.25f;
    assert(!set(DRIVER, OutputVolume, 0, &address, 0, NULL, sizeof(gain), &gain));
    assert(notifications == 2);
    fetch(OutputDevice, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, sizeof(gain), &gain);
    assert(gain == 0.25f);
    for (unsigned i = 0; i < 3; ++i) {
        Float32 invalid[] = {NAN, -1, 2};
        assert(set(DRIVER, OutputVolume, 0, &address, 0, NULL, sizeof(gain), &invalid[i]));
    }
    assert(atomic_load(&outputGain) == 0.25f);
    address.mSelector = kAudioLevelControlPropertyDecibelValue;
    gain = -6;
    assert(!set(DRIVER, OutputVolume, 0, &address, 0, NULL, sizeof(gain), &gain));
    assert(fabsf(atomic_load(&outputGain) - 0.501187f) < 0.00001f);
    fetch(OutputVolume, kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, sizeof(gain), &gain);
    assert(fabsf(gain + 6) < 0.001f);
    address = property(kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
    UInt32 muted = 1;
    assert(!set(DRIVER, OutputMute, 0, &address, 0, NULL, sizeof(muted), &muted));
    assert(scalar(OutputDevice, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput) == 1);
    muted = 2; assert(set(DRIVER, OutputMute, 0, &address, 0, NULL, sizeof(muted), &muted));
    AudioServerPlugInClientInfo client = {.mClientID = 10, .mProcessID = getpid()};
    assert(!addClient(DRIVER, OutputDevice, &client));
    assert(startIO(DRIVER, OutputDevice, 99));
    assert(!startIO(DRIVER, OutputDevice, 10));
    assert(!startIO(DRIVER, OutputDevice, 10) && atomic_load(&running) == 1);
    Float64 sample; UInt64 time, seed;
    assert(!timestamp(DRIVER, OutputDevice, 10, &sample, &time, &seed));
    assert(time && seed && sample >= 0);
    Boolean will, inPlace;
    assert(!willIO(DRIVER, OutputDevice, 10, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace) && will && inPlace);
    assert(!willIO(DRIVER, OutputDevice, 10, kAudioServerPlugInIOOperationReadInput, &will, &inPlace) && !will);
    float samples[960]; for (unsigned i = 0; i < 960; ++i) samples[i] = (float)i / 960;
    float before[960]; memcpy(before, samples, sizeof(samples));
    AudioServerPlugInIOCycleInfo cycle = {0};
    assert(!performIO(DRIVER, OutputDevice, OutputStream, 10, kAudioServerPlugInIOOperationWriteMix, 480, &cycle, samples, NULL));
    assert(!memcmp(samples, before, sizeof(samples))); // sink never transforms or retains PCM
    assert(performIO(DRIVER, OutputDevice, OutputStream, 10, kAudioServerPlugInIOOperationReadInput, 480, &cycle, samples, NULL));
    assert(performIO(DRIVER, OutputDevice, OutputStream, 10, kAudioServerPlugInIOOperationWriteMix, PLANKOutputMaxIO + 1, &cycle, samples, NULL));
    assert(!stopIO(DRIVER, OutputDevice, 10)); assert(!removeClient(DRIVER, OutputDevice, &client));
    assert(!atomic_load(&running));
    puts("output_driver_format_controls_clock_sink_bounds=pass");
}
