// SPDX-License-Identifier: GPL-3.0-or-later
#import <CoreMediaIO/CoreMediaIO.h>
#import <IOKit/audio/IOAudioTypes.h>
#import "camera-consumer.h"
#import "camera-signing.h"
#import "native-camera-sample.h"
#import "native-camera-output.h"
#include "camera-link.h"
#include <time.h>

static NSError *cameraError(NSInteger code) {
    return [NSError errorWithDomain:@PLANK_CAMERA_EXTENSION_ID code:code userInfo:nil];
}
@interface PLANKCameraStream : NSObject <CMIOExtensionStreamSource>
@property(nonatomic, readonly) CMIOExtensionStream *stream;
@property(nonatomic, readonly) NSUInteger active, clients;
@property(nonatomic, copy) void (^changed)(void);
- (instancetype)initWithFormat:(CMVideoFormatDescriptionRef)format;
- (void)retire;
@end
@implementation PLANKCameraStream {
    NSArray<CMIOExtensionStreamFormat *> *_formats;
    BOOL _retired;
}
- (instancetype)init { return nil; }
- (instancetype)initWithFormat:(CMVideoFormatDescriptionRef)format {
    if (!format || !(self = [super init])) return nil;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
    CMVideoFormatDescriptionRef raw = NULL;
    if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        dimensions.width, dimensions.height, NULL, &raw)) return nil;
    _formats = @[
        [[CMIOExtensionStreamFormat alloc] initWithFormatDescription:format maxFrameDuration:CMTimeMake(1,30)
            minFrameDuration:CMTimeMake(1,30) validFrameDurations:nil],
        [[CMIOExtensionStreamFormat alloc] initWithFormatDescription:raw maxFrameDuration:CMTimeMake(1,30)
            minFrameDuration:CMTimeMake(1,30) validFrameDurations:nil]
    ];
    CFRelease(raw);
    _stream = [[CMIOExtensionStream alloc] initWithLocalizedName:@"PLANK Camera"
        streamID:[[NSUUID alloc] initWithUUIDString:@"2F31320B-B24E-48BD-A17B-318F8B6A8F11"]
        direction:CMIOExtensionStreamDirectionSource clockType:CMIOExtensionStreamClockTypeHostTime source:self];
    return self;
}
- (NSArray<CMIOExtensionStreamFormat *> *)formats { return _formats; }
- (NSSet<CMIOExtensionProperty> *)availableProperties {
    return [NSSet setWithObjects:CMIOExtensionPropertyStreamActiveFormatIndex,
        CMIOExtensionPropertyStreamFrameDuration, CMIOExtensionPropertyStreamMaxFrameDuration, nil];
}
- (CMIOExtensionStreamProperties *)streamPropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties error:(NSError **)error {
    (void)error;
    CMIOExtensionStreamProperties *result = [[CMIOExtensionStreamProperties alloc] initWithDictionary:@{}];
    if ([properties containsObject:CMIOExtensionPropertyStreamActiveFormatIndex]) result.activeFormatIndex = @(_active);
    NSDictionary *duration = CFBridgingRelease(CMTimeCopyAsDictionary(CMTimeMake(1,30), kCFAllocatorDefault));
    if ([properties containsObject:CMIOExtensionPropertyStreamFrameDuration]) result.frameDuration = duration;
    if ([properties containsObject:CMIOExtensionPropertyStreamMaxFrameDuration]) result.maxFrameDuration = duration;
    return result;
}
- (BOOL)setStreamProperties:(CMIOExtensionStreamProperties *)properties error:(NSError **)error {
    NSNumber *index = properties.activeFormatIndex;
    if (_retired || (index && (index.integerValue < 0 || index.unsignedIntegerValue >= _formats.count)) ||
        (properties.frameDuration && CMTimeCompare(CMTimeMakeFromDictionary((__bridge CFDictionaryRef)properties.frameDuration), CMTimeMake(1,30))) ||
        (properties.maxFrameDuration && CMTimeCompare(CMTimeMakeFromDictionary((__bridge CFDictionaryRef)properties.maxFrameDuration), CMTimeMake(1,30)))) {
        if (error) *error = cameraError(1); return NO;
    }
    if (index && _active != index.unsignedIntegerValue) {
        _active = index.unsignedIntegerValue; if (_changed) _changed();
    }
    return YES;
}
- (BOOL)authorizedToStartStreamForClient:(CMIOExtensionClient *)client {
    (void)client;
    // App camera consent is enforced by CoreMediaIO/TCC. Only a separately
    // authorized Host producer can populate this device; apps never inject data.
    return !_retired;
}
- (BOOL)startStreamAndReturnError:(NSError **)error {
    if (_retired || _clients == NSUIntegerMax) { if (error) *error = cameraError(2); return NO; }
    if (!_clients++ && _changed) _changed();
    return YES;
}
- (BOOL)stopStreamAndReturnError:(NSError **)error {
    (void)error;
    if (_clients && !--_clients && _changed) _changed();
    return YES;
}
- (void)retire { _retired = YES; _clients = 0; _changed = nil; }
@end

@interface PLANKCameraDevice : NSObject <CMIOExtensionDeviceSource>
@property(nonatomic, readonly) CMIOExtensionDevice *device;
@property(nonatomic, readonly) PLANKCameraStream *source;
- (instancetype)initWithFormat:(CMVideoFormatDescriptionRef)format;
@end
@implementation PLANKCameraDevice
- (instancetype)init { return nil; }
- (instancetype)initWithFormat:(CMVideoFormatDescriptionRef)format {
    if (!(self = [super init])) return nil;
    _source = [[PLANKCameraStream alloc] initWithFormat:format]; if (!_source) return nil;
    NSString *identity = @"03889AD2-D405-4583-98FB-68FB3A811092";
    _device = [[CMIOExtensionDevice alloc] initWithLocalizedName:@"PLANK Camera"
        deviceID:[[NSUUID alloc] initWithUUIDString:identity] legacyDeviceID:identity source:self];
    if (![_device addStream:_source.stream error:NULL]) return nil;
    return self;
}
- (NSSet<CMIOExtensionProperty> *)availableProperties {
    return [NSSet setWithObjects:CMIOExtensionPropertyDeviceModel, CMIOExtensionPropertyDeviceTransportType, nil];
}
- (CMIOExtensionDeviceProperties *)devicePropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties error:(NSError **)error {
    (void)error;
    CMIOExtensionDeviceProperties *result = [[CMIOExtensionDeviceProperties alloc] initWithDictionary:@{}];
    if ([properties containsObject:CMIOExtensionPropertyDeviceModel]) result.model = @"PLANK forwarded camera";
    if ([properties containsObject:CMIOExtensionPropertyDeviceTransportType]) result.transportType = @(kIOAudioDeviceTransportTypeVirtual);
    return result;
}
- (BOOL)setDeviceProperties:(CMIOExtensionDeviceProperties *)properties error:(NSError **)error {
    (void)properties; if (error) *error = cameraError(3); return NO;
}
@end

@interface PLANKCameraProvider : NSObject <CMIOExtensionProviderSource>
@property(nonatomic, readonly) CMIOExtensionProvider *provider;
- (void)start;
- (void)stop;
@end
@implementation PLANKCameraProvider {
    PLANKMacCameraConsumer *_consumer;
    PLANKCameraDevice *_device;
    dispatch_queue_t _media;
    uint64_t _activation, _epoch, _revision;
    BOOL _busy, _gap;
    // Accessed exclusively on _media. One submitted frame at a time; no
    // accumulation of frame-sized dispatch blocks behind a stalled decoder.
    uint64_t _mediaEpoch;
    PLANKMacNativeCameraSample *_builder;
    PLANKMacNativeCameraOutput *_output;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    NSString *requirement = PLANKCameraPeerRequirement(@"la.instinctual.PLANK.Host");
    if (!requirement) return nil;
    _provider = [[CMIOExtensionProvider alloc] initWithSource:self clientQueue:dispatch_get_main_queue()];
    _media = dispatch_queue_create("la.instinctual.PLANK.Camera.media", DISPATCH_QUEUE_SERIAL);
    __weak typeof(self) weakSelf = self;
    _consumer = [[PLANKMacCameraConsumer alloc] initWithQueue:dispatch_get_main_queue() requirement:requirement
        lease:^(uint64_t activation) { [weakSelf admitted:activation]; }
        frame:^(const uint8_t *record, size_t size, uint64_t time) { [weakSelf receive:record size:size time:time]; }
        gap:^{ [weakSelf changed]; }];
    if (!_consumer) return nil;
    return self;
}
- (void)changed { _revision++; _gap = YES; [_consumer requestKeyframe]; }
- (void)admitted:(uint64_t)activation {
    // This runs on the main control queue, independent of VideoToolbox. A
    // decoder completion from any retired epoch can never republish a device.
    _epoch++; _activation = activation; [self changed];
    if (_device) {
        [_device.source retire];
        [_provider removeDevice:_device.device error:NULL]; _device = nil;
    }
    uint64_t epoch = _epoch;
    dispatch_async(_media, ^{
        self->_mediaEpoch = epoch; self->_builder = nil; self->_output = nil;
    });
}
- (void)receive:(const uint8_t *)record size:(size_t)size time:(uint64_t)time {
    if (!_activation || size > PLANKCameraRecordBytes) return;
    if (_busy) { [self changed]; return; }
    _busy = YES;
    NSData *data = [NSData dataWithBytes:record length:size];
    uint64_t epoch = _epoch, revision = _revision, activation = _activation;
    BOOL gap = _gap, running = _device.source.clients > 0, pixels = _device.source.active == 1;
    _gap = NO;
    dispatch_async(_media, ^{
        if (self->_mediaEpoch != epoch) {
            self->_builder = nil; self->_output = nil; self->_mediaEpoch = epoch;
        }
        if (!self->_builder) self->_builder = [[PLANKMacNativeCameraSample alloc] initWithGeneration:activation];
        CMSampleBufferRef native = [self->_builder copySampleFromRecord:data.bytes size:data.length hostTimeNanos:time];
        if (native && !self->_output) self->_output = [[PLANKMacNativeCameraOutput alloc]
            initWithFormat:CMSampleBufferGetFormatDescription(native)];
        if (gap) [self->_output discontinuity];
        [self->_output setPixelOutput:pixels];
        CMSampleBufferRef output = running && native ? [self->_output copyOutputForSample:native] : NULL;
        BOOL needsKey = self->_builder.needsKeyframe || (running && self->_output.needsKeyframe);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            if (self->_epoch == epoch && self->_activation == activation && self->_consumer.available) {
                if (native && !self->_device) {
                    PLANKCameraDevice *device = [[PLANKCameraDevice alloc] initWithFormat:CMSampleBufferGetFormatDescription(native)];
                    if (device && [self->_provider addDevice:device.device error:NULL]) {
                        self->_device = device;
                        __weak typeof(self) weakSelf = self;
                        device.source.changed = ^{ [weakSelf changed]; };
                    }
                }
                uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
                if (output && self->_revision == revision && self->_device.source.clients &&
                    now >= time && now - time <= PLANK_CAMERA_MAX_AGE_NS) {
                    [self->_device.source.stream sendSampleBuffer:output
                        discontinuity:gap ? CMIOExtensionStreamDiscontinuityFlagUnknown : CMIOExtensionStreamDiscontinuityFlagNone
                        hostTimeInNanoseconds:time];
                } else if (running) { self->_gap = YES; [self->_consumer requestKeyframe]; }
                if (needsKey) [self->_consumer requestKeyframe];
            }
            if (output) CFRelease(output);
            if (native) CFRelease(native);
        });
    });
}
- (void)start { [_consumer start]; }
- (void)stop { [_consumer stop]; [self admitted:0]; }
- (BOOL)connectClient:(CMIOExtensionClient *)client error:(NSError **)error { (void)client; (void)error; return YES; }
- (void)disconnectClient:(CMIOExtensionClient *)client { (void)client; }
- (NSSet<CMIOExtensionProperty> *)availableProperties { return [NSSet setWithObject:CMIOExtensionPropertyProviderManufacturer]; }
- (CMIOExtensionProviderProperties *)providerPropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties error:(NSError **)error {
    (void)properties; (void)error;
    CMIOExtensionProviderProperties *result = [[CMIOExtensionProviderProperties alloc] initWithDictionary:@{}];
    result.manufacturer = @"PLANK"; return result;
}
- (BOOL)setProviderProperties:(CMIOExtensionProviderProperties *)properties error:(NSError **)error {
    (void)properties; if (error) *error = cameraError(4); return NO;
}
@end
int main(void) {
    @autoreleasepool {
        PLANKCameraProvider *source = [[PLANKCameraProvider alloc] init]; if (!source) return 1;
        [CMIOExtensionProvider startServiceWithProvider:source.provider]; [source start];
        [[NSRunLoop mainRunLoop] run];
        [source stop]; [CMIOExtensionProvider stopServiceWithProvider:source.provider];
    }
    return 0;
}
