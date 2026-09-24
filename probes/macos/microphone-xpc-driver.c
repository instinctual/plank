// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only real HAL/XPC injection path. No physical microphone or network.
// The distinct temporary root service is a synthetic producer, not a product
// authentication service. Production lease/worker admission remains a gate.
#define PLANKMicrophoneFactory PLANKMicrophoneBaseFactory
#include "../../apps/host/macos/audio-device/microphone-driver.c"
#undef PLANKMicrophoneFactory
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <sys/mman.h>
#include <unistd.h>
#include "microphone-xpc-shared.h"

static xpc_connection_t probeConnection;
static dispatch_queue_t probeQueue;
static PLANKMicProbeShared *shared;
static _Atomic bool feedEnabled;
static dispatch_source_t clockTimer;

static void clearFeed(void) {
    atomic_store(&feedEnabled, false);
}
static OSStatus probeInitialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef owner) {
    OSStatus status = initialize(driver, owner);
    if (status || probeConnection) return status;
    long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize <= 0) return kAudioHardwareUnspecifiedError;
    size_t page = (size_t)pageSize;
    size_t mappedBytes = (sizeof(*shared) + page - 1) / page * page;
    shared = mmap(NULL, mappedBytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0);
    if (shared == MAP_FAILED) { shared = NULL; return kAudioHardwareUnspecifiedError; }
    memset(shared, 0, mappedBytes);
    shared->version = 2; shared->ticksPerFrame = ticksPerFrame;
    PLANKMicBufferInit(&shared->buffer);
    probeQueue = dispatch_queue_create("la.instinctual.PLANK.Microphone.probe",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    probeConnection = xpc_connection_create_mach_service("la.instinctual.PLANK.Microphone.probe",
        probeQueue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!probeConnection) return kAudioHardwareUnspecifiedError;
    xpc_connection_set_event_handler(probeConnection, ^(xpc_object_t message) { (void)message; clearFeed(); });
    xpc_connection_activate(probeConnection);
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(hello, "version", 2);
    xpc_object_t memory = xpc_shmem_create(shared, mappedBytes);
    if (!memory) return kAudioHardwareUnspecifiedError;
    xpc_dictionary_set_value(hello, "memory", memory); xpc_release(memory);
    xpc_connection_send_message_with_reply(probeConnection, hello, probeQueue, ^(xpc_object_t reply) {
        atomic_store(&feedEnabled, xpc_connection_get_euid(probeConnection) == 0 &&
            xpc_get_type(reply) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(reply, "accepted"));
    });
    xpc_release(hello);
    clockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, probeQueue);
    dispatch_source_set_timer(clockTimer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(clockTimer, ^{
        pthread_mutex_lock(&stateLock);
        atomic_fetch_add(&shared->clockSequence, 1);
        atomic_store(&shared->anchor, atomic_load(&anchor));
        atomic_store(&shared->seed, atomic_load(&clockSeed));
        atomic_store(&shared->running, atomic_load(&running));
        atomic_fetch_add(&shared->clockSequence, 1);
        pthread_mutex_unlock(&stateLock);
    });
    dispatch_resume(clockTimer);
    return noErr;
}
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
    if (!status && shared && atomic_load(&feedEnabled) &&
        mach_absolute_time() < atomic_load(&shared->deadline) &&
        atomic_load(&shared->producerSeed) == atomic_load(&clockSeed) &&
        (cycle->mInputTime.mFlags & kAudioTimeStampSampleTimeValid) &&
        isfinite(cycle->mInputTime.mSampleTime) && cycle->mInputTime.mSampleTime >= 0 &&
        cycle->mInputTime.mSampleTime <= (double)(UINT64_MAX / 2))
    {
        uint64_t position = (uint64_t)cycle->mInputTime.mSampleTime;
        PLANKMicBufferRead(&shared->buffer, position, main, frames);
        unsigned missing = 0;
        for (UInt32 i = 0; i < frames; i++)
            if (atomic_load(&shared->buffer.samples[(position + i) % PLANKMicFrames].frame) != position + i + 1) missing++;
        atomic_fetch_add(&shared->readFrames, frames);
        atomic_fetch_add(&shared->missingFrames, missing);
        if (!missing) atomic_store(&shared->readySeed, atomic_load(&clockSeed));
        else if (atomic_load(&shared->readySeed) == atomic_load(&clockSeed))
            atomic_fetch_add(&shared->steadyMissing, missing);
    } else if (!status && shared) {
        atomic_fetch_add(&shared->disabledFrames, frames);
        if (atomic_load(&shared->readySeed) == atomic_load(&clockSeed))
            atomic_fetch_add(&shared->steadyDisabled, frames);
    }
    return status;
}
__attribute__((visibility("default")))
void *PLANKMicrophoneFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    void *driver = PLANKMicrophoneBaseFactory(allocator, type);
    if (driver) {
        interface.Initialize = probeInitialize; interface.GetPropertyData = probeGet;
        interface.DoIOOperation = probeIO;
    }
    return driver;
}
