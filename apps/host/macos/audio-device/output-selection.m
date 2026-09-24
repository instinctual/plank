// SPDX-License-Identifier: GPL-3.0-or-later
#import "output-selection.h"
#import "../media/audio-output-volume.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static const AudioObjectPropertySelector defaults[] = {
    kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice};
static NSString *const keys[] = {@"output", @"alerts"};

@implementation PLANKMacOutputSelection {
    NSString *_directory;
    NSMutableDictionary *_previous;
}
- (instancetype)initWithDirectory:(NSString *)directory {
    self = [super init];
    if (self) _directory = [directory copy];
    return self;
}
- (AudioObjectID)deviceForUID:(NSString *)uid {
    if (!uid.length) return kAudioObjectUnknown;
    CFStringRef value = (__bridge CFStringRef)uid;
    AudioObjectID result = kAudioObjectUnknown;
    AudioValueTranslation translation = {&value, sizeof(value), &result, sizeof(result)};
    UInt32 size = sizeof(translation);
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDeviceForUID,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &translation) ? 0 : result;
}
- (NSString *)uidForDevice:(AudioObjectID)device {
    if (!device) return nil;
    CFStringRef uid = NULL; UInt32 size = sizeof(uid);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &uid)) return nil;
    return CFBridgingRelease(uid);
}
- (AudioObjectID)current:(unsigned)index {
    AudioObjectID device = 0; UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {defaults[index], kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) ? 0 : device;
}
- (BOOL)setCurrent:(AudioObjectID)device index:(unsigned)index {
    AudioObjectPropertyAddress address = {defaults[index], kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return !AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(device), &device);
}
- (BOOL)usable:(AudioObjectID)device {
    if (!device) return NO;
    UInt32 alive = 0, size = sizeof(alive);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &alive) || !alive) return NO;
    address = (AudioObjectPropertyAddress){kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    return !AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) && size >= sizeof(AudioStreamID);
}
- (BOOL)compatible:(AudioObjectID)device {
    if (![self usable:device]) return NO;
    AudioStreamID stream = 0; UInt32 size = sizeof(stream);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &stream) || size != sizeof(stream)) return NO;
    AudioStreamBasicDescription format = {0}; size = sizeof(format);
    address = (AudioObjectPropertyAddress){kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(stream, &address, 0, NULL, &size, &format)) return NO;
    return size == sizeof(format) && format.mSampleRate == PLANKOutputRate &&
        format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags == kAudioFormatFlagsNativeFloatPacked &&
        format.mChannelsPerFrame == PLANKOutputChannels && format.mBitsPerChannel == 32 &&
        format.mBytesPerFrame == 8 && format.mBytesPerPacket == 8 && format.mFramesPerPacket == 1;
}
- (BOOL)inheritVolumeFrom:(AudioObjectID)previous to:(AudioObjectID)device {
    // Begin at the physical output's existing level, including mute. Subsequent
    // remote adjustments affect only PLANK Output, leaving physical controls alone.
    Float32 gain = 1; UInt32 muted = 0; BOOL master = NO, present = NO;
    if (!PLANKOutputValue(previous, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain,
            &gain, sizeof(gain), &master) || !isfinite(gain) || gain < 0 || gain > 1 ||
        !PLANKOutputValue(previous, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain,
            &muted, sizeof(muted), &present)) return NO;
    if (!master) {
        float gains[2];
        if (!PLANKOutputGains(previous, gains)) return NO;
        gain = fminf(gains[0], gains[1]);
    }
    AudioObjectPropertyAddress address = {kAudioDevicePropertyVolumeScalar,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(gain), &gain)) return NO;
    address.mSelector = kAudioDevicePropertyMute; muted = !!muted;
    return !AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(muted), &muted);
}
- (AudioObjectID)builtInFallback {
    // Only used if an owned route's original device disappeared. Never pick an
    // arbitrary USB/Bluetooth device that may belong to a different workflow.
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID devices[128]; UInt32 size = sizeof(devices);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) ||
        size > sizeof(devices) || size % sizeof(AudioObjectID)) return 0;
    for (unsigned i = 0; i < size / sizeof(AudioObjectID); ++i) {
        UInt32 transport = 0, bytes = sizeof(transport);
        address.mSelector = kAudioDevicePropertyTransportType;
        if (!AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &bytes, &transport) &&
            transport == kAudioDeviceTransportTypeBuiltIn && [self usable:devices[i]]) return devices[i];
    }
    return 0;
}
- (int)openDirectory {
    int fd = open(_directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd >= 0 && (fstat(fd, &st) || st.st_uid != geteuid() || (st.st_mode & 0777) != 0700)) {
        close(fd); fd = -1;
    }
    return fd;
}
- (BOOL)save {
    int directory = [self openDirectory];
    if (directory < 0) return NO;
    BOOL ok = NO;
    if (!_previous.count) {
        ok = !unlinkat(directory, "output-route.plist", 0) || errno == ENOENT;
    } else {
        NSData *bytes = [NSPropertyListSerialization dataWithPropertyList:_previous
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        NSString *temporary = [@".output-route-" stringByAppendingString:NSUUID.UUID.UUIDString];
        int fd = openat(directory, temporary.UTF8String, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) {
            ok = bytes.length && bytes.length <= 4096 && write(fd, bytes.bytes, bytes.length) == (ssize_t)bytes.length && !fsync(fd);
            close(fd);
            if (ok) ok = !renameat(directory, temporary.UTF8String, directory, "output-route.plist");
            if (!ok) unlinkat(directory, temporary.UTF8String, 0);
        }
    }
    if (ok) ok = !fsync(directory);
    close(directory); return ok;
}
- (BOOL)recover {
    if (_previous.count) return [self restore];
    int directory = [self openDirectory];
    if (directory < 0) return NO;
    int fd = openat(directory, "output-route.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    int failure = errno; close(directory);
    if (fd < 0) return failure == ENOENT;
    struct stat st;
    BOOL valid = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == geteuid() &&
        (st.st_mode & 0777) == 0600 && st.st_nlink == 1 && st.st_size > 0 && st.st_size <= 4096;
    NSMutableData *bytes = valid ? [NSMutableData dataWithLength:(NSUInteger)st.st_size] : nil;
    valid = valid && read(fd, bytes.mutableBytes, bytes.length) == (ssize_t)bytes.length;
    close(fd);
    id value = valid ? [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    if (![value isKindOfClass:NSDictionary.class] || ![value count] || [value count] > 2) return NO;
    for (id key in value) {
        id uid = value[key];
        if (!([key isEqual:keys[0]] || [key isEqual:keys[1]]) || ![uid isKindOfClass:NSString.class] ||
            ![uid length] || [uid length] > 1024 || [uid isEqual:@PLANK_OUTPUT_DEVICE_UID]) return NO;
    }
    _previous = [value mutableCopy];
    return [self restore];
}
- (BOOL)select {
    if (![self recover]) return NO;
    AudioObjectID device = [self deviceForUID:@PLANK_OUTPUT_DEVICE_UID];
    if (![self compatible:device]) return NO;
    _previous = [NSMutableDictionary dictionary];
    for (unsigned i = 0; i < 2; ++i) {
        NSString *uid = [self uidForDevice:[self current:i]];
        // Already selected by the user: do not claim or later undo that choice.
        if ([uid isEqual:@PLANK_OUTPUT_DEVICE_UID]) continue;
        if (!uid.length || uid.length > 1024) { _previous = nil; return NO; }
        _previous[keys[i]] = uid;
    }
    if (_previous[keys[0]] && _previous[keys[1]] &&
        ![self inheritVolumeFrom:[self deviceForUID:_previous[keys[0]]] to:device]) { _previous = nil; return NO; }
    if (![self save]) { _previous = nil; return NO; }
    for (unsigned i = 0; i < 2; ++i) if (_previous[keys[i]]) {
        // A manual change during preparation wins. Recover any partial switch.
        if (![[self uidForDevice:[self current:i]] isEqual:_previous[keys[i]]] ||
            ![self setCurrent:device index:i]) { [self restore]; return NO; }
    }
    return YES;
}
- (BOOL)restore {
    if (!_previous.count) return YES;
    for (unsigned i = 0; i < 2; ++i) if (_previous[keys[i]]) {
        NSString *current = [self uidForDevice:[self current:i]];
        if (!current) continue; // HAL temporarily unavailable; preserve recovery record.
        if ([current isEqual:@PLANK_OUTPUT_DEVICE_UID]) {
            AudioObjectID previous = [self deviceForUID:_previous[keys[i]]];
            if (![self usable:previous]) previous = [self builtInFallback];
            if (!previous || ![self setCurrent:previous index:i]) continue;
        }
        [_previous removeObjectForKey:keys[i]];
    }
    BOOL saved = [self save];
    return saved && !_previous.count;
}
@end
