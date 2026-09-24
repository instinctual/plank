// SPDX-License-Identifier: GPL-3.0-or-later
// Temporary synthetic camera. No physical capture, network or production code.
#import <CoreMediaIO/CoreMediaIO.h>
#import <IOKit/audio/IOAudioTypes.h>
#import <os/log.h>
#import "native-camera-fixture.h"

static NSError *probeError(NSInteger code) {
    return [NSError errorWithDomain:PLANK_CAMERA_PROBE_ID code:code userInfo:nil];
}

@interface ProbeStream : NSObject <CMIOExtensionStreamSource> {
    CMSampleBufferRef _coded;
    CVPixelBufferRef _decoded;
    NSUInteger _active, _clients, _sent, _decodes;
    CMTime _deadline;
    dispatch_source_t _timer;
    os_log_t _log;
    NSArray<CMIOExtensionStreamFormat *> *_formats;
}
@property(nonatomic, strong) CMIOExtensionStream *stream;
@end

@implementation ProbeStream
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _log = os_log_create("la.instinctual.PLANK.NativeCameraProbe", "synthetic-stream");
    _coded = PLANKCameraFixtureCreate();
    if (!_coded) return nil;
    CMVideoFormatDescriptionRef raw = NULL;
    if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 320, 240, NULL, &raw) != noErr) return nil;
    _formats = @[
        [[CMIOExtensionStreamFormat alloc] initWithFormatDescription:CMSampleBufferGetFormatDescription(_coded)
            maxFrameDuration:CMTimeMake(1,30) minFrameDuration:CMTimeMake(1,30) validFrameDurations:nil],
        [[CMIOExtensionStreamFormat alloc] initWithFormatDescription:raw
            maxFrameDuration:CMTimeMake(1,30) minFrameDuration:CMTimeMake(1,30) validFrameDurations:nil]
    ];
    CFRelease(raw);
    self.stream = [[CMIOExtensionStream alloc] initWithLocalizedName:@"Synthetic H264 or NV12"
        streamID:[[NSUUID alloc] initWithUUIDString:@"9E17DD07-0F58-485D-B3E0-5FE25D2C675B"]
        direction:CMIOExtensionStreamDirectionSource clockType:CMIOExtensionStreamClockTypeHostTime source:self];
    os_log_info(_log, "synthetic_h264_sha256=%{public}s", PLANKCameraFixtureDigest(_coded).UTF8String);
    return self;
}
- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    if (_coded) CFRelease(_coded);
    if (_decoded) CFRelease(_decoded);
}
- (NSArray<CMIOExtensionStreamFormat *> *)formats { return _formats; }
- (NSSet<CMIOExtensionProperty> *)availableProperties {
    return [NSSet setWithObjects:CMIOExtensionPropertyStreamActiveFormatIndex,
        CMIOExtensionPropertyStreamFrameDuration, CMIOExtensionPropertyStreamMaxFrameDuration, nil];
}
- (CMIOExtensionStreamProperties *)streamPropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties
                                                         error:(NSError **)error {
    (void)error;
    CMIOExtensionStreamProperties *result = [[CMIOExtensionStreamProperties alloc] initWithDictionary:@{}];
    if ([properties containsObject:CMIOExtensionPropertyStreamActiveFormatIndex]) result.activeFormatIndex = @(_active);
    NSDictionary *duration = CFBridgingRelease(CMTimeCopyAsDictionary(CMTimeMake(1, 30), kCFAllocatorDefault));
    if ([properties containsObject:CMIOExtensionPropertyStreamFrameDuration]) result.frameDuration = duration;
    if ([properties containsObject:CMIOExtensionPropertyStreamMaxFrameDuration]) result.maxFrameDuration = duration;
    return result;
}
- (BOOL)setStreamProperties:(CMIOExtensionStreamProperties *)properties error:(NSError **)error {
    NSNumber *index = properties.activeFormatIndex;
    if ((index && (index.integerValue < 0 || index.unsignedIntegerValue >= self.formats.count)) ||
        (properties.frameDuration && CMTimeCompare(CMTimeMakeFromDictionary((__bridge CFDictionaryRef)properties.frameDuration), CMTimeMake(1,30))) ||
        (properties.maxFrameDuration && CMTimeCompare(CMTimeMakeFromDictionary((__bridge CFDictionaryRef)properties.maxFrameDuration), CMTimeMake(1,30)))) {
        if (error) *error = probeError(1);
        return NO;
    }
    if (index) {
        _active = index.unsignedIntegerValue;
        if (_active == 0 && _decoded) { CFRelease(_decoded); _decoded = NULL; }
        os_log_info(_log, "active_format=%lu clients=%lu", (unsigned long)_active, (unsigned long)_clients);
    }
    return YES;
}
- (BOOL)authorizedToStartStreamForClient:(CMIOExtensionClient *)client {
    (void)client;
    // Framework camera consent still applies; this source contains synthetic pixels only.
    return YES;
}
- (BOOL)startStreamAndReturnError:(NSError **)error {
    (void)error;
    if (_clients++ > 0) return YES;
    _sent = 0;
    _deadline = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTimeMake(30, 1));
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_MSEC);
    __weak ProbeStream *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
    return YES;
}
- (BOOL)stopStreamAndReturnError:(NSError **)error {
    (void)error;
    if (_clients && --_clients == 0) {
        if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
        if (_decoded) { CFRelease(_decoded); _decoded = NULL; }
        os_log_info(_log, "stopped sent=%lu decode_count=%lu", (unsigned long)_sent, (unsigned long)_decodes);
    }
    return YES;
}
- (void)tick {
    // Bound each test stream to 30 seconds, even if its consumer stalls.
    if (!_clients) return;
    CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
    if (CMTimeCompare(now, _deadline) >= 0) {
        if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
        os_log_info(_log, "synthetic_stream_time_limit=30s");
        return;
    }
    CMSampleTimingInfo timing = {CMTimeMake(1,30), now, kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    OSStatus status;
    if (_active == 0) {
        status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, _coded, 1, &timing, &sample);
    } else {
        if (!_decoded) {
            _decoded = PLANKCameraFixtureDecode(_coded);
            _decodes++;
            os_log_info(_log, "decode_count=%lu success=%d", (unsigned long)_decodes, _decoded != NULL);
        }
        if (!_decoded) return;
        CMVideoFormatDescriptionRef description = NULL;
        status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, _decoded, &description);
        if (status == noErr) status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
            _decoded, description, &timing, &sample);
        if (description) CFRelease(description);
    }
    if (status == noErr && sample) {
        [self.stream sendSampleBuffer:sample discontinuity:0
            hostTimeInNanoseconds:(uint64_t)CMTimeConvertScale(now, NSEC_PER_SEC, kCMTimeRoundingMethod_Default).value];
        _sent++;
        CFRelease(sample);
    }
}
@end

@interface ProbeDevice : NSObject <CMIOExtensionDeviceSource>
@property(nonatomic, strong) ProbeStream *source;
@property(nonatomic, strong) CMIOExtensionDevice *device;
@end
@implementation ProbeDevice
- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.source = [[ProbeStream alloc] init];
    if (!self.source) return nil;
    self.device = [[CMIOExtensionDevice alloc] initWithLocalizedName:@"PLANK Synthetic Native Camera"
        deviceID:[[NSUUID alloc] initWithUUIDString:PLANK_CAMERA_DEVICE_ID]
        legacyDeviceID:PLANK_CAMERA_DEVICE_ID source:self];
    NSError *error = nil;
    if (![self.device addStream:self.source.stream error:&error]) return nil;
    return self;
}
- (NSSet<CMIOExtensionProperty> *)availableProperties {
    return [NSSet setWithObjects:CMIOExtensionPropertyDeviceModel, CMIOExtensionPropertyDeviceTransportType, nil];
}
- (CMIOExtensionDeviceProperties *)devicePropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties
                                                         error:(NSError **)error {
    (void)error;
    CMIOExtensionDeviceProperties *result = [[CMIOExtensionDeviceProperties alloc] initWithDictionary:@{}];
    if ([properties containsObject:CMIOExtensionPropertyDeviceModel]) result.model = @"Synthetic H264/NV12 qualification";
    if ([properties containsObject:CMIOExtensionPropertyDeviceTransportType]) result.transportType = @(kIOAudioDeviceTransportTypeVirtual);
    return result;
}
- (BOOL)setDeviceProperties:(CMIOExtensionDeviceProperties *)properties error:(NSError **)error {
    (void)properties; if (error) *error = probeError(2); return NO;
}
@end

@interface ProbeProvider : NSObject <CMIOExtensionProviderSource>
@property(nonatomic, strong) CMIOExtensionProvider *provider;
@property(nonatomic, strong) ProbeDevice *source;
@end
@implementation ProbeProvider
- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.provider = [[CMIOExtensionProvider alloc] initWithSource:self clientQueue:dispatch_get_main_queue()];
    self.source = [[ProbeDevice alloc] init];
    NSError *error = nil;
    if (!self.source || ![self.provider addDevice:self.source.device error:&error]) return nil;
    return self;
}
- (BOOL)connectClient:(CMIOExtensionClient *)client error:(NSError **)error { (void)client; (void)error; return YES; }
- (void)disconnectClient:(CMIOExtensionClient *)client { (void)client; }
- (NSSet<CMIOExtensionProperty> *)availableProperties { return [NSSet setWithObject:CMIOExtensionPropertyProviderManufacturer]; }
- (CMIOExtensionProviderProperties *)providerPropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties
                                                              error:(NSError **)error {
    (void)properties; (void)error;
    CMIOExtensionProviderProperties *result = [[CMIOExtensionProviderProperties alloc] initWithDictionary:@{}];
    result.manufacturer = @"PLANK synthetic probe";
    return result;
}
- (BOOL)setProviderProperties:(CMIOExtensionProviderProperties *)properties error:(NSError **)error {
    (void)properties; if (error) *error = probeError(3); return NO;
}
@end

int main(void) {
    @autoreleasepool {
        ProbeProvider *source = [[ProbeProvider alloc] init];
        if (!source) return 1;
        [CMIOExtensionProvider startServiceWithProvider:source.provider];
        // Keep the weak framework source references alive for the service lifetime.
        [[NSRunLoop mainRunLoop] run];
        [CMIOExtensionProvider stopServiceWithProvider:source.provider];
    }
    return 0;
}
