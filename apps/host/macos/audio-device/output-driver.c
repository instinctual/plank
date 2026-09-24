// SPDX-License-Identifier: GPL-3.0-or-later
// Output-only silent Core Audio endpoint. The session's process-scoped tap
// captures PCM before this sink. No audio is retained, copied to another user,
// encoded or sent from the HAL. Volume is applied once by the existing tap.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <limits.h>
#include "output-format.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>

enum { OutputDevice = 2, OutputStream = 3, OutputVolume = 4, OutputMute = 5, OutputPeriod = 480, OutputMaxClients = 64 };
static const AudioStreamBasicDescription outputFormat = {
    .mSampleRate = PLANKOutputRate, .mFormatID = kAudioFormatLinearPCM,
    .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
    .mBytesPerPacket = PLANKOutputChannels * sizeof(float), .mFramesPerPacket = 1,
    .mBytesPerFrame = PLANKOutputChannels * sizeof(float), .mChannelsPerFrame = PLANKOutputChannels,
    .mBitsPerChannel = 32,
};
static _Atomic float outputGain = 1.0f;
static _Atomic UInt32 outputMute;
static pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef host;
static struct { UInt32 id; bool used, running; } clients[OutputMaxClients];
static _Atomic UInt32 running;
static _Atomic UInt64 anchor;
static _Atomic UInt64 clockSeed;
static double ticksPerFrame;
static _Atomic ULONG references = 1;
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePointer = &interface;
#define DRIVER (&interfacePointer)
static bool objectExists(AudioObjectID object) {
    return object == kAudioObjectPlugInObject || object == OutputDevice || object == OutputStream || object == OutputVolume || object == OutputMute;
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
void *PLANKOutputFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    (void)allocator;
    return type && CFEqual(type, kAudioServerPlugInTypeUUID) ? DRIVER : NULL;
}
static OSStatus initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef owner) {
    if (driver != DRIVER || !owner) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&stateLock);
    if (!host) {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        ticksPerFrame = (1e9 / PLANKOutputRate) * timebase.denom / timebase.numer;
        atomic_store(&anchor, mach_absolute_time());
        atomic_store(&clockSeed, 1);
        host = owner;
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
    if (driver != DRIVER || device != OutputDevice || !info)
        return kAudioHardwareBadObjectError;
    OSStatus status = kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&stateLock);
    for (unsigned i = 0; i < OutputMaxClients; i++) {
        if (clients[i].used && clients[i].id == info->mClientID) { status = noErr; break; }
    }
    if (status) for (unsigned i = 0; i < OutputMaxClients; i++) {
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
    if (driver != DRIVER || device != OutputDevice || !info) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&stateLock);
    for (unsigned i = 0; i < OutputMaxClients; i++) {
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
    return driver == DRIVER && device == OutputDevice ?
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
            *size = object == OutputDevice ? 3 * sizeof(AudioObjectID) :
                object == kAudioObjectPlugInObject ? sizeof(AudioObjectID) : 0; return noErr;
    }
    if (object == kAudioObjectPlugInObject && global) switch (selector) {
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice: *size = sizeof(AudioObjectID); return noErr;
        case kAudioPlugInPropertyResourceBundle: *size = sizeof(CFStringRef); return noErr;
    }
    if (object == OutputDevice) {
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
            case kAudioObjectPropertyControlList: *size = 2 * sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertyRelatedDevices: *size = sizeof(AudioObjectID); return noErr;
        }
        if (input || output) switch (selector) {
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
                *size = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                if (output) { *size = sizeof(UInt32) * 2; return noErr; } break;
            case kAudioDevicePropertyStreams: case kAudioObjectPropertyOwnedObjects:
                *size = output ? sizeof(AudioObjectID) : 0; return noErr;
        }
        if (global && selector == kAudioDevicePropertyStreams) {
            *size = sizeof(AudioObjectID); return noErr;
        }
    }
    if (object == OutputDevice && output) switch (selector) {
        case kAudioDevicePropertyVolumeScalar: *size = sizeof(Float32); return noErr;
        case kAudioDevicePropertyMute: *size = sizeof(UInt32); return noErr;
    }
    if ((object == OutputVolume || object == OutputMute) && global) switch (selector) {
        case kAudioControlPropertyScope: case kAudioControlPropertyElement:
            *size = sizeof(UInt32); return noErr;
        case kAudioBooleanControlPropertyValue:
            if (object == OutputMute) { *size = sizeof(UInt32); return noErr; } break;
        case kAudioLevelControlPropertyScalarValue: case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels: case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if (object == OutputVolume) { *size = sizeof(Float32); return noErr; } break;
        case kAudioLevelControlPropertyDecibelRange:
            if (object == OutputVolume) { *size = sizeof(AudioValueRange); return noErr; } break;
    }
    if (object == OutputStream && global) switch (selector) {
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
    // Fixed formats support idempotent setters used by ordinary output apps.
    *result = (object == OutputDevice && (address->mSelector == kAudioDevicePropertyNominalSampleRate ||
                 address->mSelector == kAudioDevicePropertyVolumeScalar || address->mSelector == kAudioDevicePropertyMute)) ||
        (object == OutputVolume && (address->mSelector == kAudioLevelControlPropertyScalarValue ||
                                   address->mSelector == kAudioLevelControlPropertyDecibelValue)) ||
        (object == OutputMute && address->mSelector == kAudioBooleanControlPropertyValue) ||
        (object == OutputStream && (address->mSelector == kAudioStreamPropertyVirtualFormat ||
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
        case kAudioObjectPropertyBaseClass: value = object == OutputVolume ? kAudioLevelControlClassID :
            object == OutputMute ? kAudioBooleanControlClassID : kAudioObjectClassID; break;
        case kAudioObjectPropertyClass: value = object == OutputDevice ? kAudioDeviceClassID :
            object == OutputStream ? kAudioStreamClassID : object == OutputVolume ? kAudioVolumeControlClassID :
            object == OutputMute ? kAudioMuteControlClassID : kAudioPlugInClassID; break;
        case kAudioObjectPropertyOwner: value = object == OutputDevice ? kAudioObjectPlugInObject :
            object != kAudioObjectPlugInObject ? OutputDevice : kAudioObjectUnknown; break;
        case kAudioObjectPropertyName: string = CFSTR(PLANK_OUTPUT_DEVICE_NAME); break;
        case kAudioObjectPropertyManufacturer: string = CFSTR("PLANK"); break;
        case kAudioObjectPropertyControlList: {
            AudioObjectID controls[] = {OutputVolume, OutputMute}; memcpy(data, controls, sizeof(controls)); return noErr;
        }
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID objects[] = {OutputStream, OutputVolume, OutputMute};
            if (object == OutputDevice) { memcpy(data, objects, needed); return noErr; }
            value = OutputDevice; break;
        }
        case kAudioControlPropertyScope: value = kAudioObjectPropertyScopeOutput; break;
        case kAudioControlPropertyElement: value = kAudioObjectPropertyElementMain; break;
        case kAudioBooleanControlPropertyValue: case kAudioDevicePropertyMute: value = atomic_load(&outputMute); break;
        case kAudioLevelControlPropertyScalarValue: case kAudioDevicePropertyVolumeScalar: {
            Float32 gain = atomic_load(&outputGain); memcpy(data, &gain, sizeof(gain)); return noErr;
        }
        case kAudioLevelControlPropertyDecibelValue: {
            Float32 db = fmaxf(-96, 20 * log10f(fmaxf(0.000015848932f, atomic_load(&outputGain)))); memcpy(data, &db, sizeof(db)); return noErr;
        }
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange range = {-96, 0}; memcpy(data, &range, sizeof(range)); return noErr;
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            Float32 input; memcpy(&input, data, sizeof(input));
            if (!isfinite(input)) return kAudioHardwareIllegalOperationError;
            Float32 converted = address->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ?
                20 * log10f(fmaxf(0.000015848932f, fminf(1, input))) : powf(10, fminf(0, fmaxf(-96, input)) / 20);
            memcpy(data, &converted, sizeof(converted)); return noErr;
        }
        case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyRelatedDevices: value = OutputDevice; break;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid; memcpy(&uid, qualifier, sizeof(uid));
            value = uid && CFGetTypeID(uid) == CFStringGetTypeID() &&
                CFEqual(uid, CFSTR(PLANK_OUTPUT_DEVICE_UID)) ? OutputDevice : kAudioObjectUnknown;
            break;
        }
        case kAudioPlugInPropertyResourceBundle: string = CFSTR(""); break;
        case kAudioDevicePropertyDeviceUID: string = CFSTR(PLANK_OUTPUT_DEVICE_UID); break;
        case kAudioDevicePropertyModelUID: string = CFSTR(PLANK_OUTPUT_MODEL_UID); break;
        case kAudioDevicePropertyTransportType: value = kAudioDeviceTransportTypeVirtual; break;
        case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset: break;
        case kAudioDevicePropertyDeviceIsAlive: case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyStartingChannel: value = 1; break;
        case kAudioStreamPropertyDirection: break;
        case kAudioDevicePropertyDeviceIsRunning: value = atomic_load(&running) != 0; break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            value = address->mScope == kAudioObjectPropertyScopeOutput; break;
        case kAudioDevicePropertyZeroTimeStampPeriod: value = OutputPeriod; break;
        case kAudioDevicePropertyNominalSampleRate: {
            Float64 rate = PLANKOutputRate; memcpy(data, &rate, sizeof(rate)); return noErr;
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = {PLANKOutputRate, PLANKOutputRate}; memcpy(data, &range, sizeof(range)); return noErr;
        }
        case kAudioDevicePropertyStreams: value = OutputStream; break;
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 channels[] = {1, 2}; memcpy(data, channels, sizeof(channels)); return noErr;
        }
        case kAudioStreamPropertyTerminalType: value = kAudioStreamTerminalTypeSpeaker; break;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            memcpy(data, &outputFormat, sizeof(outputFormat)); return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription description = {outputFormat, {PLANKOutputRate, PLANKOutputRate}};
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
    bool gain = address->mSelector == kAudioDevicePropertyVolumeScalar ||
        address->mSelector == kAudioLevelControlPropertyScalarValue ||
        address->mSelector == kAudioLevelControlPropertyDecibelValue;
    bool mute = address->mSelector == kAudioDevicePropertyMute ||
        address->mSelector == kAudioBooleanControlPropertyValue;
    if (gain || mute) {
        if (gain) {
            Float32 value; memcpy(&value, data, sizeof(value));
            if (!isfinite(value)) return kAudioHardwareIllegalOperationError;
            if (address->mSelector == kAudioLevelControlPropertyDecibelValue) {
                if (value < -96 || value > 0) return kAudioHardwareIllegalOperationError;
                value = powf(10, value / 20);
            }
            if (value < 0 || value > 1) return kAudioHardwareIllegalOperationError;
            atomic_store(&outputGain, value);
        } else {
            UInt32 value; memcpy(&value, data, sizeof(value));
            if (value > 1) return kAudioHardwareIllegalOperationError;
            atomic_store(&outputMute, value);
        }
        AudioObjectPropertyAddress changes[] = {
            {gain ? kAudioLevelControlPropertyScalarValue : kAudioBooleanControlPropertyValue,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}};
        if (host) {
            (*host).PropertiesChanged(host, gain ? OutputVolume : OutputMute, gain ? 2 : 1, changes);
            changes[0] = (AudioObjectPropertyAddress){gain ? kAudioDevicePropertyVolumeScalar : kAudioDevicePropertyMute,
                kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
            (*host).PropertiesChanged(host, OutputDevice, 1, changes);
        }
        return noErr;
    }
    if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        Float64 rate; memcpy(&rate, data, sizeof(rate));
        return rate == PLANKOutputRate ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    if (address->mSelector == kAudioStreamPropertyIsActive) {
        UInt32 active; memcpy(&active, data, sizeof(active));
        return active == 1 ? noErr : kAudioHardwareUnsupportedOperationError;
    }
    AudioStreamBasicDescription format; memcpy(&format, data, sizeof(format));
    return format.mSampleRate == outputFormat.mSampleRate && format.mFormatID == outputFormat.mFormatID &&
        format.mFormatFlags == outputFormat.mFormatFlags && format.mBytesPerPacket == outputFormat.mBytesPerPacket &&
        format.mFramesPerPacket == 1 && format.mBytesPerFrame == PLANKOutputChannels * sizeof(float) &&
        format.mChannelsPerFrame == PLANKOutputChannels && format.mBitsPerChannel == 32 ? noErr : kAudioDeviceUnsupportedFormatError;
}
static OSStatus changeIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, bool start) {
    if (driver != DRIVER || device != OutputDevice || !host) return kAudioHardwareBadObjectError;
    OSStatus result = kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&stateLock);
    for (unsigned i = 0; i < OutputMaxClients; i++) if (clients[i].used && clients[i].id == client) {
        result = noErr;
        if (clients[i].running != start) {
            clients[i].running = start;
            if (start) {
                if (!atomic_load(&running)) {
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
    if (driver != DRIVER || device != OutputDevice || !sample || !time || !seed || !host)
        return kAudioHardwareIllegalOperationError;
    UInt64 base = atomic_load(&anchor), now = mach_absolute_time();
    double periods = floor((double)(now - base) / (ticksPerFrame * OutputPeriod));
    *sample = periods * OutputPeriod;
    *time = base + (UInt64)(*sample * ticksPerFrame);
    *seed = atomic_load(&clockSeed);
    return noErr;
}
static OSStatus willIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                       UInt32 operation, Boolean *will, Boolean *inPlace) {
    (void)client;
    if (driver != DRIVER || device != OutputDevice || !will || !inPlace) return kAudioHardwareBadObjectError;
    *will = operation == kAudioServerPlugInIOOperationWriteMix;
    *inPlace = true;
    return noErr;
}
static OSStatus boundaryIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                           UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client; (void)operation; (void)cycle;
    return driver == DRIVER && device == OutputDevice && frames <= PLANKOutputMaxIO ?
        noErr : kAudioHardwareIllegalOperationError;
}
static OSStatus performIO(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream,
                          UInt32 client, UInt32 operation, UInt32 frames,
                          const AudioServerPlugInIOCycleInfo *cycle, void *main, void *secondary) {
    (void)client; (void)secondary;
    if (driver != DRIVER || device != OutputDevice || stream != OutputStream ||
        operation != kAudioServerPlugInIOOperationWriteMix || frames > PLANKOutputMaxIO || !main || !cycle)
        return kAudioHardwareIllegalOperationError;
    // The owned-process tap reads upstream PCM. This endpoint intentionally
    // discards the final mix: it never feeds a physical speaker or loopback input.
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
