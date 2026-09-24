// SPDX-License-Identifier: GPL-3.0-or-later
// In-process HAL host: no installed device, microphone access or audio restart.
// Including the implementation lets the fixture feed the private sample buffer
// without adding an injection backdoor or test switch to the product plug-in.
#include "../../apps/host/macos/audio-device/microphone-driver.c"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

static unsigned notifications;
static OSStatus changed(AudioServerPlugInHostRef owner, AudioObjectID object, UInt32 count,
                        const AudioObjectPropertyAddress *addresses) {
    (void)owner;
    assert(object == MicDevice && count == 1);
    assert(addresses[0].mSelector == kAudioDevicePropertyDeviceIsRunning);
    notifications++;
    return noErr;
}
static const AudioServerPlugInHostInterface fakeHost = { .PropertiesChanged = changed };
static AudioObjectPropertyAddress property(UInt32 selector, UInt32 scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}
static UInt32 scalar(AudioObjectID object, UInt32 selector, UInt32 scope) {
    AudioObjectPropertyAddress address = property(selector, scope);
    UInt32 value = UINT32_MAX, size = 0;
    assert(!get(DRIVER, object, getpid(), &address, 0, NULL, sizeof(value), &size, &value));
    assert(size == sizeof(value));
    return value;
}
int main(void) {
    assert(!PLANKMicrophoneFactory(NULL, NULL));
    assert(PLANKMicrophoneFactory(NULL, kAudioServerPlugInTypeUUID) == DRIVER);
    void *queried = NULL;
    assert(!query(DRIVER, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &queried));
    assert(queried == DRIVER); release(DRIVER);
    assert(!initialize(DRIVER, &fakeHost));
    assert(!initialize(DRIVER, &fakeHost));
    assert(scalar(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList,
                  kAudioObjectPropertyScopeGlobal) == MicDevice);
    assert(scalar(MicDevice, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput) == MicStream);
    assert(scalar(MicStream, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 1);
    assert(scalar(MicDevice, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1);
    assert(scalar(MicDevice, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0);
    AudioObjectPropertyAddress address = property(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    UInt32 size = 123;
    assert(!sizeOf(DRIVER, MicDevice, 0, &address, 0, NULL, &size) && size == 0);
    assert(!get(DRIVER, MicDevice, 0, &address, 0, NULL, 0, &size, NULL));
    address = property(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal);
    CFStringRef uid = NULL;
    assert(!get(DRIVER, MicDevice, 0, &address, 0, NULL, sizeof(uid), &size, &uid));
    assert(CFEqual(uid, CFSTR("la.instinctual.PLANK.Microphone")));
    address = property(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    UInt32 device = 0;
    assert(!get(DRIVER, kAudioObjectPlugInObject, 0, &address, sizeof(uid), &uid, sizeof(device), &size, &device));
    assert(device == MicDevice); CFRelease(uid);
    assert(get(DRIVER, kAudioObjectPlugInObject, 0, &address, 0, NULL, sizeof(device), &size, &device));
    address = property(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription format = {0};
    assert(!get(DRIVER, MicStream, 0, &address, 0, NULL, sizeof(format), &size, &format));
    assert(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32);
    assert(format.mBytesPerFrame == 2*sizeof(float) && format.mBytesPerPacket == 2*sizeof(float));
    assert(!set(DRIVER, MicStream, 0, &address, 0, NULL, sizeof(format), &format));
    format.mChannelsPerFrame = 1;
    assert(set(DRIVER, MicStream, 0, &address, 0, NULL, sizeof(format), &format) == kAudioDeviceUnsupportedFormatError);
    assert(get(DRIVER, MicStream, 0, &address, 0, NULL, 1, &size, &format) == kAudioHardwareBadPropertySizeError);
    assert(!has(DRIVER, 99, 0, &address));
    address.mElement = 100;
    assert(!has(DRIVER, MicStream, 0, &address));
    AudioServerPlugInClientInfo first = { .mClientID = 10, .mProcessID = getpid() };
    AudioServerPlugInClientInfo second = { .mClientID = 20, .mProcessID = getpid() };
    assert(!addClient(DRIVER, MicDevice, &first));
    assert(!addClient(DRIVER, MicDevice, &first)); // idempotent, no duplicate slot
    assert(!addClient(DRIVER, MicDevice, &second));
    assert(startIO(DRIVER, MicDevice, 30));
    assert(!startIO(DRIVER, MicDevice, first.mClientID));
    assert(!startIO(DRIVER, MicDevice, first.mClientID));
    assert(!startIO(DRIVER, MicDevice, second.mClientID));
    assert(atomic_load(&running) == 2 && notifications == 0);
    Boolean will = false, inPlace = false;
    assert(!willIO(DRIVER, MicDevice, 10, kAudioServerPlugInIOOperationReadInput, &will, &inPlace));
    assert(will && inPlace);
    assert(!willIO(DRIVER, MicDevice, 10, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace));
    assert(!will);
    double before, after; UInt64 time, seed, laterSeed;
    assert(!timestamp(DRIVER, MicDevice, 10, &before, &time, &seed));
    usleep(21000);
    assert(!timestamp(DRIVER, MicDevice, 10, &after, &time, &laterSeed));
    assert(after >= before + 2 * MicPeriod && laterSeed == seed && time <= mach_absolute_time());
    address = property(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeInput);
    UInt32 channels[2] = {0};
    assert(!get(DRIVER, MicDevice, 0, &address, 0, NULL, sizeof(channels), &size, channels));
    assert(channels[0] == 1 && channels[1] == 2);
    float tone[MicPeriod * PLANKMicChannels], received[MicPeriod * PLANKMicChannels], other[MicPeriod * PLANKMicChannels];
    for (unsigned i = 0; i < MicPeriod; i++) {
        tone[2*i] = .25f * sinf((float)i * 2 * (float)M_PI / 48);
        tone[2*i+1] = .125f * cosf((float)i * 2 * (float)M_PI / 32);
    }
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mInputTime.mFlags = kAudioTimeStampSampleTimeValid;
    for (unsigned block = 0; block < 1000; block++) {
        UInt64 frame = (UInt64)block * MicPeriod;
        cycle.mInputTime.mSampleTime = (double)frame;
        assert(PLANKMicBufferWrite(&micBuffer, frame, tone, MicPeriod));
        assert(!performIO(DRIVER, MicDevice, MicStream, 10, kAudioServerPlugInIOOperationReadInput,
                          MicPeriod, &cycle, received, NULL));
        assert(!performIO(DRIVER, MicDevice, MicStream, 20, kAudioServerPlugInIOOperationReadInput,
                          MicPeriod, &cycle, other, NULL));
        assert(!memcmp(tone, received, sizeof(tone)));
        assert(!memcmp(other, received, sizeof(tone)));
    }
    // Underflow and invalid timestamps return silence, never stale audio.
    cycle.mInputTime.mSampleTime += MicPeriod;
    assert(!performIO(DRIVER, MicDevice, MicStream, 10, kAudioServerPlugInIOOperationReadInput,
                      MicPeriod, &cycle, received, NULL));
    for (unsigned i = 0; i < MicPeriod * PLANKMicChannels; i++) assert(received[i] == 0);
    cycle.mInputTime.mSampleTime = NAN;
    assert(!performIO(DRIVER, MicDevice, MicStream, 10, kAudioServerPlugInIOOperationReadInput,
                      MicPeriod, &cycle, received, NULL));
    for (unsigned i = 0; i < MicPeriod * PLANKMicChannels; i++) assert(received[i] == 0);
    assert(performIO(DRIVER, MicDevice, MicStream, 10, kAudioServerPlugInIOOperationReadInput,
                     PLANKMicMaxIO + 1, &cycle, received, NULL));
    assert(!stopIO(DRIVER, MicDevice, 10) && atomic_load(&running) == 1);
    assert(!removeClient(DRIVER, MicDevice, &second) && !atomic_load(&running));
    assert(notifications == 0);
    assert(!startIO(DRIVER, MicDevice, 10));
    assert(!timestamp(DRIVER, MicDevice, 10, &after, &time, &laterSeed) && laterSeed != seed);
    cycle.mInputTime.mSampleTime = 0;
    assert(!performIO(DRIVER, MicDevice, MicStream, 10, kAudioServerPlugInIOOperationReadInput,
                      MicPeriod, &cycle, received, NULL));
    for (unsigned i = 0; i < MicPeriod * PLANKMicChannels; i++) assert(received[i] == 0);
    assert(!removeClient(DRIVER, MicDevice, &first) && !atomic_load(&running));
    puts("microphone_driver=pass blocks=1000 readers=2 properties=1 lifecycle=1 clock=1 silence=1");
}
