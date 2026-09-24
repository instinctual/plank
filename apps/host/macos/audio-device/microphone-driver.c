// SPDX-License-Identifier: GPL-3.0-or-later
// Input-only Core Audio HAL component. No networking, decoder, credentials,
// device-selection policy, file access or worker threads run in coreaudiod.
// Producer admission/injection is deliberately not exposed until qualified.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <limits.h>
#include "microphone-buffer.h"

enum { MicDevice = 2, MicStream = 3, MicPeriod = 480, MicMaxClients = 64 };
static const AudioStreamBasicDescription micFormat = {
    .mSampleRate = PLANKMicRate, .mFormatID = kAudioFormatLinearPCM,
    .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
    .mBytesPerPacket = PLANKMicChannels * sizeof(float), .mFramesPerPacket = 1,
    .mBytesPerFrame = PLANKMicChannels * sizeof(float), .mChannelsPerFrame = PLANKMicChannels,
    .mBitsPerChannel = 32,
};
static PLANKMicBuffer micBuffer;
static pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef host;
static struct { UInt32 id; bool used, running; } clients[MicMaxClients];
static _Atomic UInt32 running;
static _Atomic UInt64 anchor;
static _Atomic UInt64 clockSeed;
static double ticksPerFrame;
static _Atomic ULONG references = 1;
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePointer = &interface;
#define DRIVER (&interfacePointer)
#ifndef PLANK_MIC_DEVICE_NAME
#define PLANK_MIC_DEVICE_NAME "PLANK Microphone"
#define PLANK_MIC_DEVICE_UID "la.instinctual.PLANK.Microphone"
#define PLANK_MIC_MODEL_UID "la.instinctual.PLANK.Microphone.Model"
#endif

#ifdef PLANK_MICROPHONE_IPC
#include "microphone-driver-ipc.h"
#endif

static bool objectExists(AudioObjectID object) {
    return object == kAudioObjectPlugInObject || object == MicDevice || object == MicStream;
}
static HRESULT query(void *driver, REFIID uuidBytes, LPVOID *result) {
    if (!result) return E_POINTER;
    *result = NULL;
    if (driver != DRIVER) return E_NOINTERFACE;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, uuidBytes);
    bool supported = CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(uuid);
    if (!supported) return E_NOINTERFACE;
    atomic_fetch_add(&references, 1);
    *result = DRIVER;
    return S_OK;
}
static ULONG retain(void *driver) {
    return driver == DRIVER ? atomic_fetch_add(&references, 1) + 1 : 0;
}
static ULONG release(void *driver) {
    if (driver != DRIVER) return 0;
    ULONG value = atomic_load(&references);
    while (value && !atomic_compare_exchange_weak(&references, &value, value - 1)) {}
    return value ? value - 1 : 0;
}
__attribute__((visibility("default")))
void *PLANKMicrophoneFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    (void)allocator;
    return type && CFEqual(type, kAudioServerPlugInTypeUUID) ? DRIVER : NULL;
}
static OSStatus initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef owner) {
    if (driver != DRIVER || !owner) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&stateLock);
    if (!host) {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        ticksPerFrame = (1e9 / PLANKMicRate) * timebase.denom / timebase.numer;
        PLANKMicBufferInit(&micBuffer);
        atomic_store(&anchor, mach_absolute_time());
        atomic_store(&clockSeed, 1);
        host = owner;
#ifdef PLANK_MICROPHONE_IPC
        micIPCInitialize();
#endif
    }
    pthread_mutex_unlock(&stateLock);
    return noErr;
}
static OSStatus create(AudioServerPlugInDriverRef driver, CFDictionaryRef description,
                       const AudioServerPlugInClientInfo *client, AudioObjectID *result) {
    (void)driver; (void)description; (void)client;
    if (result) *result = kAudioObjectUnknown;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus destroy(AudioServerPlugInDriverRef driver, AudioObjectID device) {
    (void)driver; (void)device;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus addClient(AudioServerPlugInDriverRef driver, AudioObjectID device,
                          const AudioServerPlugInClientInfo *info) {
    if (driver != DRIVER || device != MicDevice || !info)
        return kAudioHardwareBadObjectError;
    OSStatus status = kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&stateLock);
    for (unsigned i = 0; i < MicMaxClients; i++) {
        if (clients[i].used && clients[i].id == info->mClientID) { status = noErr; break; }
    }
    if (status) for (unsigned i = 0; i < MicMaxClients; i++) {
        if (!clients[i].used) {
            clients[i].used = true; clients[i].id = info->mClientID;
            clients[i].running = false; status = noErr; break;
        }
    }
    pthread_mutex_unlock(&stateLock);
    return status;
}
static OSStatus removeClient(AudioServerPlugInDriverRef driver, AudioObjectID device,
                             const AudioServerPlugInClientInfo *info) {
    if (driver != DRIVER || device != MicDevice || !info) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&stateLock);
    for (unsigned i = 0; i < MicMaxClients; i++) {
        if (clients[i].used && clients[i].id == info->mClientID) {
            if (clients[i].running) atomic_fetch_sub(&running, 1);
            clients[i].used = clients[i].running = false; break;
        }
    }
    pthread_mutex_unlock(&stateLock);
    return noErr;
}
static OSStatus configuration(AudioServerPlugInDriverRef driver, AudioObjectID device,
                             UInt64 action, void *info) {
    (void)action; (void)info;
    return driver == DRIVER && device == MicDevice ?
        kAudioHardwareUnsupportedOperationError : kAudioHardwareBadObjectError;
}

// One source of truth for HasProperty, GetPropertyDataSize and GetPropertyData.
// Qualifiers are interpreted only by TranslateUIDToDevice below.
static OSStatus propertySize(AudioObjectID object, const AudioObjectPropertyAddress *address,
                             UInt32 *size) {
    if (!address || !size || !objectExists(object)) return kAudioHardwareBadObjectError;
    if (address->mElement != kAudioObjectPropertyElementMain)
        return kAudioHardwareUnknownPropertyError;
    bool global = address->mScope == kAudioObjectPropertyScopeGlobal;
    bool input = address->mScope == kAudioObjectPropertyScopeInput;
    bool output = address->mScope == kAudioObjectPropertyScopeOutput;
    if (!global && !input && !output) return kAudioHardwareUnknownPropertyError;
    AudioObjectPropertySelector selector = address->mSelector;
    if (global) switch (selector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner: *size = sizeof(UInt32); return noErr;
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer:
            *size = sizeof(CFStringRef); return noErr;
        case kAudioObjectPropertyOwnedObjects:
            *size = object == MicStream ? 0 : sizeof(AudioObjectID); return noErr;
    }
    if (object == kAudioObjectPlugInObject && global) switch (selector) {
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice: *size = sizeof(AudioObjectID); return noErr;
        case kAudioPlugInPropertyResourceBundle: *size = sizeof(CFStringRef); return noErr;
    }
    if (object == MicDevice) {
        if (global) switch (selector) {
            case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID:
                *size = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType: case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
                *size = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyNominalSampleRate: *size = sizeof(Float64); return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *size = sizeof(AudioValueRange); return noErr;
            case kAudioObjectPropertyControlList: *size = 0; return noErr;
            case kAudioDevicePropertyRelatedDevices: *size = sizeof(AudioObjectID); return noErr;
        }
        if (input || output) switch (selector) {
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
                *size = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                if (input) { *size = sizeof(UInt32) * 2; return noErr; } break;
            case kAudioDevicePropertyStreams: case kAudioObjectPropertyOwnedObjects:
                *size = input ? sizeof(AudioObjectID) : 0; return noErr;
        }
        if (global && selector == kAudioDevicePropertyStreams) {
            *size = sizeof(AudioObjectID); return noErr;
        }
    }
    if (object == MicStream && global) switch (selector) {
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency: *size = sizeof(UInt32); return noErr;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            *size = sizeof(AudioStreamBasicDescription); return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *size = sizeof(AudioStreamRangedDescription); return noErr;
    }
    return kAudioHardwareUnknownPropertyError;
}
static Boolean has(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                   const AudioObjectPropertyAddress *address) {
    (void)pid; UInt32 size;
    return driver == DRIVER && propertySize(object, address, &size) == noErr;
}
static OSStatus settable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                         const AudioObjectPropertyAddress *address, Boolean *result) {
    if (!result) return kAudioHardwareIllegalOperationError;
    *result = false;
    if (!has(driver, object, pid, address)) return kAudioHardwareUnknownPropertyError;
    // Fixed formats support idempotent setters used by ordinary input apps.
    *result = (object == MicDevice && address->mSelector == kAudioDevicePropertyNominalSampleRate) ||
        (object == MicStream && (address->mSelector == kAudioStreamPropertyVirtualFormat ||
                               address->mSelector == kAudioStreamPropertyPhysicalFormat ||
                               address->mSelector == kAudioStreamPropertyIsActive));
    return noErr;
}
static OSStatus sizeOf(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                       const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                       const void *qualifier, UInt32 *result) {
    (void)pid; (void)qualifierSize; (void)qualifier;
    return driver == DRIVER ? propertySize(object, address, result) : kAudioHardwareBadObjectError;
}
static OSStatus get(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                    const void *qualifier, UInt32 capacity, UInt32 *actual, void *data) {
    (void)pid;
    if (!actual) return kAudioHardwareIllegalOperationError;
    *actual = 0;
    UInt32 needed;
    OSStatus status = sizeOf(driver, object, pid, address, qualifierSize, qualifier, &needed);
    if (status) return status;
    if (capacity < needed || (needed && !data)) return kAudioHardwareBadPropertySizeError;
    if (!needed) return noErr;
    *actual = needed;
    UInt32 value = 0;
    CFStringRef string = NULL;
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: value = kAudioObjectClassID; break;
        case kAudioObjectPropertyClass: value = object == MicDevice ? kAudioDeviceClassID :
            object == MicStream ? kAudioStreamClassID : kAudioPlugInClassID; break;
        case kAudioObjectPropertyOwner: value = object == MicDevice ? kAudioObjectPlugInObject :
            object == MicStream ? MicDevice : kAudioObjectUnknown; break;
        case kAudioObjectPropertyName: string = CFSTR(PLANK_MIC_DEVICE_NAME); break;
        case kAudioObjectPropertyManufacturer: string = CFSTR("PLANK"); break;
        case kAudioObjectPropertyOwnedObjects: value = object == MicDevice ? MicStream : MicDevice; break;
        case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyRelatedDevices: value = MicDevice; break;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid; memcpy(&uid, qualifier, sizeof(uid));
            value = uid && CFGetTypeID(uid) == CFStringGetTypeID() &&
                CFEqual(uid, CFSTR(PLANK_MIC_DEVICE_UID)) ? MicDevice : kAudioObjectUnknown;
            break;
        }
        case kAudioPlugInPropertyResourceBundle: string = CFSTR(""); break;
        case kAudioDevicePropertyDeviceUID: string = CFSTR(PLANK_MIC_DEVICE_UID); break;
        case kAudioDevicePropertyModelUID: string = CFSTR(PLANK_MIC_MODEL_UID); break;
        case kAudioDevicePropertyTransportType: value = kAudioDeviceTransportTypeVirtual; break;
        case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: break;
        case kAudioDevicePropertyDeviceIsAlive: case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection: case kAudioStreamPropertyStartingChannel: value = 1; break;
        case kAudioDevicePropertyDeviceIsRunning: value = atomic_load(&running) != 0; break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: value = address->mScope == kAudioObjectPropertyScopeInput; break;
        case kAudioDevicePropertyZeroTimeStampPeriod: value = MicPeriod; break;
        case kAudioDevicePropertyNominalSampleRate: {
            Float64 rate = PLANKMicRate; memcpy(data, &rate, sizeof(rate)); return noErr;
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = {PLANKMicRate, PLANKMicRate}; memcpy(data, &range, sizeof(range)); return noErr;
        }
        case kAudioDevicePropertyStreams: value = MicStream; break;
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 channels[] = {1, 2}; memcpy(data, channels, sizeof(channels)); return noErr;
        }
        case kAudioStreamPropertyTerminalType: value = kAudioStreamTerminalTypeMicrophone; break;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            memcpy(data, &micFormat, sizeof(micFormat)); return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription description = {micFormat, {PLANKMicRate, PLANKMicRate}};
            memcpy(data, &description, sizeof(description)); return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
    if (string) { CFRetain(string); memcpy(data, &string, sizeof(string)); }
    else memcpy(data, &value, sizeof(value));
    return noErr;
}
static OSStatus set(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                    const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                    const void *qualifier, UInt32 size, const void *data) {
    (void)qualifierSize; (void)qualifier;
    Boolean writable;
    OSStatus status = settable(driver, object, pid, address, &writable);
    if (status) return status;
    if (!writable) return kAudioHardwareUnsupportedOperationError;
    UInt32 needed;
    propertySize(object, address, &needed);
    if (size != needed || !data) return kAudioHardwareBadPropertySizeError;
    if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        Float64 rate; memcpy(&rate, data, sizeof(rate));
        return rate == PLANKMicRate ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    if (address->mSelector == kAudioStreamPropertyIsActive) {
        UInt32 active; memcpy(&active, data, sizeof(active));
        return active == 1 ? noErr : kAudioHardwareUnsupportedOperationError;
    }
    AudioStreamBasicDescription format; memcpy(&format, data, sizeof(format));
    return format.mSampleRate == micFormat.mSampleRate && format.mFormatID == micFormat.mFormatID &&
        format.mFormatFlags == micFormat.mFormatFlags && format.mBytesPerPacket == micFormat.mBytesPerPacket &&
        format.mFramesPerPacket == 1 && format.mBytesPerFrame == PLANKMicChannels * sizeof(float) &&
        format.mChannelsPerFrame == PLANKMicChannels && format.mBitsPerChannel == 32 ? noErr : kAudioDeviceUnsupportedFormatError;
}
static OSStatus changeIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, bool start) {
    if (driver != DRIVER || device != MicDevice || !host) return kAudioHardwareBadObjectError;
    OSStatus result = kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&stateLock);
    for (unsigned i = 0; i < MicMaxClients; i++) if (clients[i].used && clients[i].id == client) {
        result = noErr;
        if (clients[i].running != start) {
            clients[i].running = start;
            if (start) {
                if (!atomic_load(&running)) {
                    PLANKMicBufferReset(&micBuffer, 0);
                    atomic_store(&anchor, mach_absolute_time());
                    atomic_fetch_add(&clockSeed, 1);
                }
                atomic_fetch_add(&running, 1);
            } else atomic_fetch_sub(&running, 1);
        }
        break;
    }
    pthread_mutex_unlock(&stateLock);
    // Core Audio initiates these IO changes and owns their notifications.
    // Do not call back into HAL synchronously from its own StartIO/StopIO.
    return result;
}
static OSStatus startIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    return changeIO(driver, device, client, true);
}
static OSStatus stopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    return changeIO(driver, device, client, false);
}
static OSStatus timestamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                          Float64 *sample, UInt64 *time, UInt64 *seed) {
    (void)client;
    if (driver != DRIVER || device != MicDevice || !sample || !time || !seed || !host)
        return kAudioHardwareIllegalOperationError;
    UInt64 base = atomic_load(&anchor), now = mach_absolute_time();
    double periods = floor((double)(now - base) / (ticksPerFrame * MicPeriod));
    *sample = periods * MicPeriod;
    *time = base + (UInt64)(*sample * ticksPerFrame);
    *seed = atomic_load(&clockSeed);
    return noErr;
}
static OSStatus willIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                       UInt32 operation, Boolean *will, Boolean *inPlace) {
    (void)client;
    if (driver != DRIVER || device != MicDevice || !will || !inPlace) return kAudioHardwareBadObjectError;
    *will = operation == kAudioServerPlugInIOOperationReadInput;
    *inPlace = true;
    return noErr;
}
static OSStatus boundaryIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                           UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client; (void)operation; (void)cycle;
    return driver == DRIVER && device == MicDevice && frames <= PLANKMicMaxIO ?
        noErr : kAudioHardwareIllegalOperationError;
}
static OSStatus performIO(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream,
                          UInt32 client, UInt32 operation, UInt32 frames,
                          const AudioServerPlugInIOCycleInfo *cycle, void *main, void *secondary) {
    (void)client; (void)secondary;
    if (driver != DRIVER || device != MicDevice || stream != MicStream ||
        operation != kAudioServerPlugInIOOperationReadInput || frames > PLANKMicMaxIO || !main || !cycle)
        return kAudioHardwareIllegalOperationError;
    memset(main, 0, frames * PLANKMicChannels * sizeof(float));
    double position = cycle->mInputTime.mSampleTime;
    if (!(cycle->mInputTime.mFlags & kAudioTimeStampSampleTimeValid) || !isfinite(position) ||
        position < 0 || position > (double)(UINT64_MAX / 2) || !atomic_load(&running)) return noErr;
#ifdef PLANK_MICROPHONE_IPC
    micIPCRead((uint64_t)position, main, frames);
#else
    PLANKMicBufferRead(&micBuffer, (uint64_t)position, main, frames);
#endif
    return noErr;
}
static AudioServerPlugInDriverInterface interface = {
    ._reserved = NULL, .QueryInterface = query, .AddRef = retain, .Release = release,
    .Initialize = initialize, .CreateDevice = create, .DestroyDevice = destroy,
    .AddDeviceClient = addClient, .RemoveDeviceClient = removeClient,
    .PerformDeviceConfigurationChange = configuration, .AbortDeviceConfigurationChange = configuration,
    .HasProperty = has, .IsPropertySettable = settable, .GetPropertyDataSize = sizeOf,
    .GetPropertyData = get, .SetPropertyData = set, .StartIO = startIO, .StopIO = stopIO,
    .GetZeroTimeStamp = timestamp, .WillDoIOOperation = willIO,
    .BeginIOOperation = boundaryIO, .DoIOOperation = performIO, .EndIOOperation = boundaryIO,
};
