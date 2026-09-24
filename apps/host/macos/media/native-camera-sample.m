// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-camera-sample.h"
#include "native-camera-payload.h"

@implementation PLANKMacNativeCameraSample {
    uint64_t _generation, _sequence, _captureTime, _hostTime;
    PlankCameraHeader _metadata;
    CMVideoFormatDescriptionRef _format;
    NSData *_sps, *_pps;
    BOOL _hasFrame, _needsKeyframe;
}
- (instancetype)initWithGeneration:(uint64_t)generation {
    if (!generation) return nil;
    self = [super init];
    if (self) { _generation = generation; _needsKeyframe = YES; }
    return self;
}
- (BOOL)needsKeyframe { return _needsKeyframe; }
- (CMSampleBufferRef)copySampleFromRecord:(const uint8_t *)record size:(size_t)size
                           hostTimeNanos:(uint64_t)hostTime {
    PlankCameraHeader header;
    if (plank_camera_header_decode(record, size, &header) || header.generation != _generation ||
        !hostTime || hostTime > INT64_MAX ||
        (_hasFrame && (header.sequence <= _sequence || header.capture_time_us <= _captureTime || hostTime <= _hostTime))) return NULL;
    if (_format && (header.codec != _metadata.codec || header.width != _metadata.width ||
        header.height != _metadata.height || header.colorspace != _metadata.colorspace ||
        header.transfer != _metadata.transfer || header.ycbcr != _metadata.ycbcr ||
        header.quantization != _metadata.quantization)) { _needsKeyframe = YES; return NULL; }
    if ((_hasFrame && header.sequence != _sequence + 1) || (header.flags & PLANK_CAMERA_DISCONTINUITY)) _needsKeyframe = YES;
    const uint8_t *bytes = record + PLANK_CAMERA_HEADER_BYTES;
    size_t length = size - PLANK_CAMERA_HEADER_BYTES;
    PLANKCameraPayload parsed;
    if (!PLANKCameraParsePayload(&header, bytes, length, &parsed)) { _needsKeyframe = YES; return NULL; }
    if (_needsKeyframe && !parsed.independent) return NULL;
    NSData *sps = _sps, *pps = _pps;
    CMVideoFormatDescriptionRef candidate = NULL;
    NSMutableData *adapted = nil;
    if (header.codec == PLANK_CAMERA_H264) {
        if (parsed.sps < parsed.count) {
            PLANKCameraNAL nal = parsed.nals[parsed.sps];
            sps = [NSData dataWithBytes:bytes+nal.offset length:nal.size];
        }
        if (parsed.pps < parsed.count) {
            PLANKCameraNAL nal = parsed.nals[parsed.pps];
            pps = [NSData dataWithBytes:bytes+nal.offset length:nal.size];
        }
        if (!sps || !pps || (_format && (![_sps isEqualToData:sps] || ![_pps isEqualToData:pps]))) {
            _needsKeyframe = YES; return NULL;
        }
        const uint8_t *sets[] = {sps.bytes, pps.bytes};
        size_t sizes[] = {sps.length, pps.length};
        if (CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
            2, sets, sizes, 4, &candidate) || !candidate) { _needsKeyframe = YES; return NULL; }
    } else if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_JPEG,
        header.width, header.height, NULL, &candidate) || !candidate) return NULL;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(candidate);
    BOOL valid = dimensions.width == header.width && dimensions.height == header.height &&
        (!_format || CMFormatDescriptionEqual(_format, candidate));
    if (!valid) { CFRelease(candidate); _needsKeyframe = YES; return NULL; }
    if (header.codec == PLANK_CAMERA_H264) {
        adapted = [NSMutableData dataWithCapacity:length];
        for (unsigned i = 0; i < parsed.count; i++) {
            PLANKCameraNAL nal = parsed.nals[i];
            uint32_t prefix = CFSwapInt32HostToBig((uint32_t)nal.size);
            [adapted appendBytes:&prefix length:4];
            [adapted appendBytes:bytes+nal.offset length:nal.size];
        }
        bytes = adapted.bytes; length = adapted.length;
    }
    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, length,
        kCFAllocatorDefault, NULL, 0, length, 0, &block);
    if (!status) status = CMBlockBufferReplaceDataBytes(bytes, block, 0, length);
    // Actual capture cadence can differ from the nominal negotiated interval.
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake((int64_t)hostTime, 1000000000), kCMTimeInvalid};
    if (!status) status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, candidate,
        1, 1, &timing, 1, &length, &sample);
    if (block) CFRelease(block);
    if (status || !sample) {
        if (sample) CFRelease(sample);
        CFRelease(candidate); _needsKeyframe = YES; return NULL;
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    if (!attachments || CFArrayGetCount(attachments) != 1) {
        CFRelease(sample); CFRelease(candidate); _needsKeyframe = YES; return NULL;
    }
    CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
        kCMSampleAttachmentKey_NotSync, parsed.independent ? kCFBooleanFalse : kCFBooleanTrue);
    if (!_format) { _format = candidate; _metadata = header; _sps = sps; _pps = pps; }
    else CFRelease(candidate);
    _hasFrame = YES; _needsKeyframe = NO;
    _sequence = header.sequence; _captureTime = header.capture_time_us; _hostTime = hostTime;
    return sample;
}
- (void)dealloc { if (_format) CFRelease(_format); }
@end
