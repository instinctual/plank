// SPDX-License-Identifier: GPL-3.0-or-later
#import "audio-tap.h"
#import "audio-tap-buffer.h"
#import "audio-tap-policy.h"
#import "audio-tap-system-alerts.h"
#import "audio-output-volume.h"
#import "../audio-device/output-format.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <libproc.h>
#include <unistd.h>

static AudioObjectPropertyAddress property(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}
// A consent request can remain inside HAL until the user responds. Bound the
// worker to one tap (including its deferred cleanup), even across reconnects.
static atomic_bool tapInUse = false;
enum { TapPreparing, TapActivating, TapCancelled };
typedef struct {
    PLANKTapBuffer buffer;
    __unsafe_unretained dispatch_source_t ready;
    BOOL planar;
} TapInput;

static OSStatus receive(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *time,
                         AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)output; (void)outputTime;
    TapInput *state = context;
    if (atomic_load_explicit(&state->buffer.stopped, memory_order_acquire)) return noErr;
    uint32_t bytes = state->planar ? 4 : 8;
    BOOL valid = input && input->mNumberBuffers == (state->planar ? 2u : 1u) &&
        time && (time->mFlags & kAudioTimeStampHostTimeValid);
    uint32_t frames = valid ? input->mBuffers[0].mDataByteSize / bytes : 0;
    for (uint32_t b = 0; valid && b < input->mNumberBuffers; b++)
        valid = input->mBuffers[b].mNumberChannels == (state->planar ? 1u : 2u) &&
            input->mBuffers[b].mData && input->mBuffers[b].mDataByteSize == frames * bytes;
    if (!valid) atomic_store(&state->buffer.failed, 1);
    else PLANKTapPush(&state->buffer, input->mBuffers[0].mData,
        state->planar ? input->mBuffers[1].mData : NULL, frames, time->mHostTime);
    dispatch_source_merge_data(state->ready, 1);
    return noErr;
}

@implementation PLANKMacAudioTap {
    dispatch_queue_t _owner, _control;
    dispatch_source_t _ready;
    TapInput *_input;
    BOOL (^_sample)(CMSampleBufferRef);
    void (^_failed)(void);
    BOOL _started, _stopped;
    BOOL _ownsSlot;
    BOOL _systemAlertsIncluded;
    atomic_int _activation;
    AudioObjectID _tap, _device;
    AudioDeviceIOProcID _io;
    BOOL _running, _listening, _formatListening;
    CATapDescription *_description;
    AudioObjectPropertyListenerBlock _processesChanged, _formatChanged;
    AudioStreamBasicDescription _inputFormat;
    CMAudioFormatDescriptionRef _format;
    AudioObjectID _outputDevice;
    AudioObjectPropertyListenerBlock _outputChanged;
    BOOL _outputListening, _deviceListening;
    float _leftGain, _rightGain; // owner queue only; HAL properties read on control
    uint64_t _overrunEvents;
    BOOL _failureReported;
}
- (instancetype)init { return nil; }
- (instancetype)initWithQueue:(dispatch_queue_t)queue sample:(BOOL (^)(CMSampleBufferRef))sample failed:(void (^)(void))failed {
    if (!queue || !sample || !failed || getuid() == 0 || geteuid() != getuid()) return nil;
    self = [super init];
    if (!self) return nil;
    _owner = queue; _sample = [sample copy]; _failed = [failed copy];
    _control = dispatch_queue_create("la.instinctual.PLANK.audio-tap", DISPATCH_QUEUE_SERIAL);
    _input = calloc(1, sizeof(*_input));
    if (!_input) return nil;
    PLANKTapBufferInit(&_input->buffer);
    atomic_init(&_activation, TapPreparing);
    _ready = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, _owner);
    _input->ready = _ready;
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_ready, ^{ [weakSelf drain]; });
    dispatch_resume(_ready);
    return self;
}
- (NSArray<NSNumber *> *)ownedAudioProcesses {
    AudioObjectPropertyAddress address = property(kAudioHardwarePropertyProcessObjectList);
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &bytes) ||
        bytes % sizeof(AudioObjectID) || bytes > 65536) return nil;
    if (!bytes) return @[];
    NSMutableData *storage = [NSMutableData dataWithLength:bytes];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &bytes, storage.mutableBytes)) return nil;
    NSMutableArray *owned = [NSMutableArray array];
    BOOL systemAlerts = NO;
    const AudioObjectID *objects = storage.bytes;
    for (UInt32 i = 0; i < bytes / sizeof(AudioObjectID); i++) {
        pid_t pid = 0; UInt32 size = sizeof(pid);
        AudioObjectPropertyAddress pidProperty = property(kAudioProcessPropertyPID);
        if (AudioObjectGetPropertyData(objects[i], &pidProperty, 0, NULL, &size, &pid) ||
            pid <= 0 || pid == getpid()) continue;
        struct proc_bsdinfo info = {0};
        BOOL userOwned = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
            PLANKTapProcessOwned(getuid(), getpid(), pid, info.pbi_uid, info.pbi_ruid);
        BOOL systemAlert = !userOwned && PLANKTapSystemAlertProcess(getuid(), pid);
        if (!userOwned && !systemAlert) continue;
        // Re-read the HAL object's PID after the kernel ownership check.
        pid_t confirmed = 0; size = sizeof(confirmed);
        if (!AudioObjectGetPropertyData(objects[i], &pidProperty, 0, NULL, &size, &confirmed) && confirmed == pid) {
            [owned addObject:@(objects[i])];
            systemAlerts |= systemAlert;
        }
    }
    if (systemAlerts != _systemAlertsIncluded)
        NSLog(@"PLANK desktop audio system alerts: %@", systemAlerts ? @"verified Apple service included" : @"not included");
    _systemAlertsIncluded = systemAlerts;
    return owned;
}
- (BOOL)updateProcesses {
    NSArray *processes = [self ownedAudioProcesses];
    if (!processes) return NO;
    if ([_description.processes isEqual:processes]) return YES;
    _description.processes = processes;
    AudioObjectPropertyAddress address = property(kAudioTapPropertyDescription);
    CFTypeRef description = (__bridge CFTypeRef)_description;
    OSStatus status = AudioObjectSetPropertyData(_tap, &address, 0, NULL, sizeof(description), &description);
    if (status) NSLog(@"PLANK audio tap process update failed: status=%d", (int)status);
    return status == noErr;
}
- (void)refreshOutputVolume {
    if (atomic_load(&_input->buffer.stopped)) return;
    // Capture and gain both belong to PLANK Output. A manual switch to physical
    // speakers must neither redirect this tap nor change remote gain.
    CFStringRef uid = CFSTR(PLANK_OUTPUT_DEVICE_UID);
    AudioObjectID output = kAudioObjectUnknown;
    AudioValueTranslation translation = {&uid, sizeof(uid), &output, sizeof(output)};
    UInt32 bytes = sizeof(translation);
    AudioObjectPropertyAddress address = property(kAudioHardwarePropertyDeviceForUID);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &bytes, &translation);
    if (status || bytes != sizeof(translation)) output = kAudioObjectUnknown;
    if (_running && output != _outputDevice) {
        atomic_store(&_input->buffer.failed, 5);
        dispatch_source_merge_data(_ready, 1);
    }
    AudioObjectPropertyAddress deviceProperty = {kAudioObjectPropertySelectorWildcard,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard};
    if (output != _outputDevice || (output && !_deviceListening)) {
        if (_deviceListening)
            AudioObjectRemovePropertyListenerBlock(_outputDevice, &deviceProperty, _control, _outputChanged);
        _outputDevice = output; _deviceListening = NO;
        if (output) {
            OSStatus added = AudioObjectAddPropertyListenerBlock(output, &deviceProperty, _control, _outputChanged);
            _deviceListening = added == noErr;
            if (added) NSLog(@"PLANK audio output-volume listener unavailable: status=%d", (int)added);
        }
    }
    float gains[2] = {0, 0};
    BOOL valid = _deviceListening && PLANKOutputGains(output, gains);
    float left = valid ? gains[0] : 0, right = valid ? gains[1] : 0;
    dispatch_async(_owner, ^{
        if (self->_stopped) return;
        self->_leftGain = left;
        self->_rightGain = right;
    });
}
- (BOOL)observeOutputVolume {
    __weak typeof(self) weakSelf = self;
    _outputChanged = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        (void)count; (void)addresses;
        [weakSelf refreshOutputVolume];
    };
    AudioObjectPropertyAddress address = property(kAudioHardwarePropertyDevices);
    OSStatus status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, _control, _outputChanged);
    if (status) { NSLog(@"PLANK audio device-list listener failed: status=%d", (int)status); return NO; }
    _outputListening = YES;
    [self refreshOutputVolume];
    return _outputDevice != kAudioObjectUnknown && _deviceListening;
}
- (BOOL)prepare {
    if (![self observeOutputVolume]) return NO;
    NSArray *processes = [self ownedAudioProcesses];
    if (!processes) return NO;
    _description = [[CATapDescription alloc] initWithProcesses:processes
        andDeviceUID:@PLANK_OUTPUT_DEVICE_UID withStream:0];
    _description.name = @"PLANK Session Audio";
    _description.privateTap = YES;
    _description.processRestoreEnabled = NO; // no bundle-ID cross-user matching
    _description.exclusive = NO; // include only the verified process allowlist
    _description.muteBehavior = CATapUnmuted; // PLANK Output itself is a null sink
    if (AudioHardwareCreateProcessTap(_description, &_tap)) return NO;
    if (atomic_load(&_input->buffer.stopped)) return NO;
    NSDictionary *specification = @{
        @kAudioAggregateDeviceNameKey: @"PLANK Private Session Audio",
        @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapAutoStartKey: @NO,
        @kAudioAggregateDeviceTapListKey: @[@{
            @kAudioSubTapUIDKey: _description.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey: @YES}]
    };
    if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)specification, &_device)) return NO;
    // This device contains only our private tap, never the physical output.
    // Request the existing Opus input rate without changing user device settings.
    AudioObjectPropertyAddress rateProperty = property(kAudioDevicePropertyNominalSampleRate);
    Float64 rate = 48000;
    if (AudioObjectSetPropertyData(_device, &rateProperty, 0, NULL, sizeof(rate), &rate)) return NO;
    AudioObjectPropertyAddress formatProperty = {kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription format = {0}; UInt32 size = sizeof(format);
    if (AudioObjectGetPropertyData(_device, &formatProperty, 0, NULL, &size, &format) ||
        format.mFormatID != kAudioFormatLinearPCM || format.mSampleRate != 48000 ||
        format.mChannelsPerFrame != 2 || format.mBitsPerChannel != 32 ||
        !(format.mFormatFlags & kAudioFormatFlagIsFloat) || (format.mFormatFlags & kAudioFormatFlagIsBigEndian)) return NO;
    _input->planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if (format.mBytesPerFrame != (_input->planar ? 4u : 8u)) return NO;
    _inputFormat = format;
    format.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerFrame = format.mBytesPerPacket = 8;
    if (CMAudioFormatDescriptionCreate(NULL, &format, 0, NULL, 0, NULL, NULL, &_format)) return NO;
    __weak typeof(self) weakSelf = self;
    _processesChanged = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        (void)count; (void)addresses;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || atomic_load(&strongSelf->_input->buffer.stopped)) return;
        if (![strongSelf updateProcesses]) {
            atomic_store(&strongSelf->_input->buffer.failed, 3);
            dispatch_source_merge_data(strongSelf->_ready, 1);
        }
    };
    AudioObjectPropertyAddress processProperty = property(kAudioHardwarePropertyProcessObjectList);
    if (AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &processProperty, _control, _processesChanged)) return NO;
    _listening = YES;
    _formatChanged = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        (void)count; (void)addresses;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || atomic_load(&strongSelf->_input->buffer.stopped)) return;
        AudioStreamBasicDescription current = {0}; UInt32 bytes = sizeof(current);
        AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(strongSelf->_device, &address, 0, NULL, &bytes, &current) ||
            memcmp(&current, &strongSelf->_inputFormat, sizeof(current))) {
            atomic_store(&strongSelf->_input->buffer.failed, 4);
            dispatch_source_merge_data(strongSelf->_ready, 1);
        }
    };
    if (AudioObjectAddPropertyListenerBlock(_device, &formatProperty, _control, _formatChanged)) return NO;
    _formatListening = YES;
    if (![self updateProcesses]) return NO; // close enumeration/listener setup race
    if (atomic_load(&_input->buffer.stopped)) return NO;
    return AudioDeviceCreateIOProcID(_device, receive, _input, &_io) == noErr;
}
- (BOOL)activate {
    // startWithCompletion won the activation/cancellation race. From here stop
    // must await HAL cleanup before reporting that capture has stopped.
    if (AudioDeviceStart(_device, _io)) return NO;
    _running = YES;
    return YES;
}
- (void)startWithCompletion:(void (^)(BOOL))completion {
    if (_started || _stopped || !completion) { if (completion) completion(NO); return; }
    _started = YES;
    if (atomic_exchange(&tapInUse, true)) {
        NSLog(@"PLANK desktop audio unavailable: previous tap cleanup is pending");
        completion(NO); return;
    }
    _ownsSlot = YES;
    dispatch_async(_control, ^{
        BOOL ready = !atomic_load(&self->_input->buffer.stopped) && [self prepare];
        int expected = TapPreparing;
        ready = ready && atomic_compare_exchange_strong(&self->_activation, &expected, TapActivating);
        if (ready) ready = [self activate];
        dispatch_async(self->_owner, ^{
            if (self->_stopped) return;
            NSLog(@"PLANK desktop audio tap: %@", ready ? @"active; capturing PLANK Output only; local playback unchanged" :
                @"unavailable; releasing any partial audio resources");
            completion(ready);
        });
    });
}
- (void)drain {
    if (_stopped || _failureReported) return;
    int failure = atomic_load(&_input->buffer.failed);
    if (failure) {
        _failureReported = YES;
        const char *reason = failure == 1 ? "invalid-callback" : failure == 3 ? "process-update" :
            failure == 4 ? "format-change" : failure == 5 ? "output-device-change" : "unknown";
        NSLog(@"PLANK audio tap failed: reason=%s code=%d", reason, failure);
        if (_failed) _failed(); return;
    }
    PLANKTapBlock *block;
    for (unsigned handled = 0; !_stopped && handled < PLANKTapSlots; ++handled) {
        uint32_t dropped = PLANKTapDiscardOverrun(&_input->buffer);
        if (dropped) {
            ++_overrunEvents;
            if ((_overrunEvents & (_overrunEvents - 1)) == 0)
                NSLog(@"PLANK audio tap overrun: events=%llu rejected-blocks=%u backlog-discarded=1 capture-continues=1",
                    (unsigned long long)_overrunEvents, dropped);
        }
        block = PLANKTapPeek(&_input->buffer);
        if (!block) break;
        @autoreleasepool {
            for (uint32_t i = 0; i < block->frames; ++i) {
                block->samples[i * 2] *= _leftGain;
                block->samples[i * 2 + 1] *= _rightGain;
            }
            CMBlockBufferRef data = NULL; CMSampleBufferRef sample = NULL;
            size_t bytes = block->frames * 2 * sizeof(float);
            OSStatus result = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, bytes, NULL, NULL, 0, bytes, 0, &data);
            if (!result) result = CMBlockBufferReplaceDataBytes(block->samples, data, 0, bytes);
            if (!result) result = CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, data, _format,
                block->frames, CMClockMakeHostTimeFromSystemUnits(block->hostTime), NULL, &sample);
            BOOL delivered = !result && _sample && _sample(sample);
            if (sample) CFRelease(sample);
            if (data) CFRelease(data);
            PLANKTapPop(&_input->buffer);
            if (!delivered) {
                _failureReported = YES;
                NSLog(@"PLANK audio tap failed: reason=%s status=%d", result ? "sample-creation" : "encoder-or-send", (int)result);
                if (_failed) _failed(); return;
            }
        }
    }
    // Give video/input/cancellation an owner turn even if HAL keeps producing.
    if (!_stopped && PLANKTapPeek(&_input->buffer)) dispatch_source_merge_data(_ready, 1);
}
- (void)stopWithCompletion:(void (^)(void))completion {
    if (_stopped) return; // one-shot owner calls exactly once
    _stopped = YES; _sample = nil; _failed = nil;
    atomic_store_explicit(&_input->buffer.stopped, true, memory_order_release);
    int expected = TapPreparing;
    BOOL cancelledBeforeActivation = atomic_compare_exchange_strong(&_activation, &expected, TapCancelled);
    // HAL has no public cancellation API for the consent wait. If activation
    // has not begun, permanently prevent it and detach the session now. The
    // retained control block cleans up any unstarted objects once HAL returns;
    // it cannot deliver samples, start IO or mute playback after completion.
    dispatch_async(_control, ^{
        [self destroy];
        if (self->_ownsSlot) { atomic_store(&tapInUse, false); self->_ownsSlot = NO; }
        dispatch_async(self->_owner, ^{
            dispatch_source_cancel(self->_ready);
            NSLog(@"PLANK desktop audio tap stopped; PLANK Output capture released");
            if (!cancelledBeforeActivation && completion) completion();
        });
    });
    if (cancelledBeforeActivation) {
        NSLog(@"PLANK desktop audio cancelled before activation; session teardown will not wait for consent");
        if (completion) completion();
    }
}
- (void)destroy {
    BOOL clean = YES;
    if (_outputListening) {
        AudioObjectPropertyAddress address = property(kAudioHardwarePropertyDevices);
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, _control, _outputChanged);
    }
    if (_deviceListening) {
        AudioObjectPropertyAddress address = {kAudioObjectPropertySelectorWildcard,
            kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard};
        // An unplugged output may already be gone. Callbacks are weak and gated
        // by stopped, so listener cleanup never needs to retire the worker.
        AudioObjectRemovePropertyListenerBlock(_outputDevice, &address, _control, _outputChanged);
    }
    _outputChanged = nil;
    if (_listening) {
        AudioObjectPropertyAddress address = property(kAudioHardwarePropertyProcessObjectList);
        clean &= AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, _control, _processesChanged) == noErr;
    }
    if (_formatListening) {
        AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
        clean &= AudioObjectRemovePropertyListenerBlock(_device, &address, _control, _formatChanged) == noErr;
    }
    if (_running) clean &= AudioDeviceStop(_device, _io) == noErr;
    if (_io) clean &= AudioDeviceDestroyIOProcID(_device, _io) == noErr;
    if (_device) clean &= AudioHardwareDestroyAggregateDevice(_device) == noErr;
    if (_tap) clean &= AudioHardwareDestroyProcessTap(_tap) == noErr;
    // Do not reuse a worker after uncertain HAL teardown: process exit is
    // the final cleanup boundary and the machine service replaces its agent.
    if (!clean) { NSLog(@"PLANK audio tap teardown failed; retiring worker"); _exit(70); }
    _processesChanged = nil; _formatChanged = nil; _description = nil;
}
- (void)dealloc {
    if (_format) CFRelease(_format);
    free(_input);
}
@end
