// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-camera-output.h"
#import <VideoToolbox/VideoToolbox.h>

typedef struct { CVPixelBufferRef image; unsigned callbacks; BOOL failed; } PLANKCameraDecoded;
static void cameraDecoded(void *context, void *frameContext, OSStatus status,
                          VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime duration) {
    (void)context; (void)pts; (void)duration;
    PLANKCameraDecoded *result = frameContext;
    if (!result) return;
    if (status || !image || result->callbacks++ || (flags & kVTDecodeInfo_FrameDropped)) { result->failed = YES; return; }
    result->image = CVPixelBufferRetain(image);
}
@implementation PLANKMacNativeCameraOutput {
    CMVideoFormatDescriptionRef _format;
    VTDecompressionSessionRef _decoder;
    BOOL _pixels, _needsKeyframe, _hardwareDecoder;
    uint64_t _decodedFrames;
}
- (instancetype)initWithFormat:(CMVideoFormatDescriptionRef)format {
    if (!format || CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video) return nil;
    FourCharCode codec = CMFormatDescriptionGetMediaSubType(format);
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
    if ((codec != kCMVideoCodecType_H264 && codec != kCMVideoCodecType_JPEG) ||
        !((dimensions.width == 1280 && dimensions.height == 720) ||
          (dimensions.width == 1920 && dimensions.height == 1080))) return nil;
    self = [super init];
    if (self) _format = (CMVideoFormatDescriptionRef)CFRetain(format);
    return self;
}
- (BOOL)needsKeyframe { return _needsKeyframe; }
- (BOOL)hardwareDecoder { return _hardwareDecoder; }
- (uint64_t)decodedFrames { return _decodedFrames; }
- (void)resetDecoder {
    if (_decoder) { VTDecompressionSessionInvalidate(_decoder); CFRelease(_decoder); _decoder = NULL; }
    _hardwareDecoder = NO;
}
- (void)setPixelOutput:(BOOL)pixels {
    if (pixels == _pixels) return;
    [self resetDecoder]; _pixels = pixels; _needsKeyframe = pixels;
}
- (void)discontinuity {
    [self resetDecoder]; _needsKeyframe = YES;
}
- (CMSampleBufferRef)copyOutputForSample:(CMSampleBufferRef)sample {
    if (!sample || !CMSampleBufferDataIsReady(sample) || CMSampleBufferGetNumSamples(sample) != 1 ||
        !CMSampleBufferGetFormatDescription(sample) || !CMSampleBufferGetDataBuffer(sample) ||
        !CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(sample)) ||
        CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(sample)) > 4u*1024u*1024u ||
        !CMFormatDescriptionEqual(_format, CMSampleBufferGetFormatDescription(sample)) ||
        !CMTIME_IS_NUMERIC(CMSampleBufferGetPresentationTimeStamp(sample))) return NULL;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    // Only samples from the validated builder are accepted; require an explicit
    // sync flag rather than interpreting a missing attachment as permission.
    if (!attachments || CFArrayGetCount(attachments) != 1) return NULL;
    CFTypeRef notSync = CFDictionaryGetValue(CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_NotSync);
    if (!notSync || CFGetTypeID(notSync) != CFBooleanGetTypeID()) return NULL;
    BOOL independent = CFEqual(notSync, kCFBooleanFalse);
    if (_needsKeyframe && !independent) return NULL;
    if (!_pixels) { _needsKeyframe = NO; return (CMSampleBufferRef)CFRetain(sample); }
    if (!_decoder) {
        VTDecompressionOutputCallbackRecord callback = {cameraDecoded, NULL};
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        if (VTDecompressionSessionCreate(kCFAllocatorDefault, _format, NULL,
            (__bridge CFDictionaryRef)attributes, &callback, &_decoder) || !_decoder) {
            [self discontinuity]; return NULL;
        }
        CFTypeRef hardware = NULL;
        if (!VTSessionCopyProperty(_decoder, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  kCFAllocatorDefault, &hardware) && hardware) {
            _hardwareDecoder = CFEqual(hardware, kCFBooleanTrue); CFRelease(hardware);
        }
    }
    PLANKCameraDecoded decoded = {0};
    OSStatus status = VTDecompressionSessionDecodeFrame(_decoder, sample, 0, &decoded, NULL);
    // Drain before the stack callback context can disappear, including failure.
    OSStatus waited = VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(_format);
    if (status || waited || decoded.failed || decoded.callbacks != 1 || !decoded.image ||
        CVPixelBufferGetWidth(decoded.image) != (size_t)dimensions.width ||
        CVPixelBufferGetHeight(decoded.image) != (size_t)dimensions.height ||
        CVPixelBufferGetPixelFormatType(decoded.image) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        [self discontinuity];
        if (decoded.image) CFRelease(decoded.image);
        return NULL;
    }
    CMVideoFormatDescriptionRef raw = NULL;
    CMSampleBufferRef output = NULL;
    status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, decoded.image, &raw);
    CMSampleTimingInfo timing = {CMSampleBufferGetDuration(sample),
        CMSampleBufferGetPresentationTimeStamp(sample), kCMTimeInvalid};
    if (!status) status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, decoded.image, raw, &timing, &output);
    CFRelease(decoded.image); if (raw) CFRelease(raw);
    if (status || !output) {
        if (output) CFRelease(output);
        [self discontinuity]; return NULL;
    }
    _needsKeyframe = NO; _decodedFrames++;
    return output;
}
- (void)dealloc {
    [self resetDecoder];
    if (_format) CFRelease(_format);
}
@end
