// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import "native-camera-fixture.h"

typedef struct {
    CMSampleBufferRef sample;
    OSStatus status;
} EncodedFrame;

static void encoded(void *context, void *frameContext, OSStatus status,
                    VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    (void)frameContext;
    EncodedFrame *frame = context;
    frame->status = status;
    if (status == noErr && sample && !(flags & kVTEncodeInfo_FrameDropped))
        frame->sample = (CMSampleBufferRef)CFRetain(sample);
}

CMSampleBufferRef PLANKCameraFixtureCreate(void) {
    return PLANKCameraFixtureCreateSized(320, 240);
}

CMSampleBufferRef PLANKCameraFixtureCreateSized(unsigned width, unsigned height) {
    NSArray *samples = PLANKCameraFixtureCreateSequence(width, height, 1);
    return samples.count ? (CMSampleBufferRef)CFRetain((__bridge CFTypeRef)samples[0]) : NULL;
}

NSArray *PLANKCameraFixtureCreateSequence(unsigned width, unsigned height, unsigned count) {
    if (width < 16 || height < 16 || width > 1920 || height > 1080 || !count || count > 120) return nil;
    CVPixelBufferRef pixels = NULL;
    VTCompressionSessionRef encoder = NULL;
    EncodedFrame frame = {NULL, noErr};
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}},
        &pixels);
    if (status != noErr || !pixels) return NULL;
    status = CVPixelBufferLockBaseAddress(pixels, 0);
    if (status != noErr) { CFRelease(pixels); return NULL; }
    size_t stride = CVPixelBufferGetBytesPerRow(pixels);
    uint8_t *base = CVPixelBufferGetBaseAddress(pixels);
    memset(base, 0, stride * height);
    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            uint8_t *p = base + stride * y + 4 * x;
            p[0] = (uint8_t)(x * 255 / width);
            p[1] = (uint8_t)(y * 255 / height);
            p[2] = 64;
            p[3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    status = VTCompressionSessionCreate(kCFAllocatorDefault, width, height,
        kCMVideoCodecType_H264, NULL, NULL, NULL, encoded, &frame, &encoder);
    if (status == noErr)
        status = VTSessionSetProperty(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    if (status == noErr)
        status = VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering,
                                       kCFBooleanFalse);
    if (status == noErr)
        status = VTSessionSetProperty(encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                       (__bridge CFNumberRef)@300);
    NSMutableArray *samples = [NSMutableArray array];
    for (unsigned i = 0; status == noErr && i < count; i++) {
        frame.sample = NULL;
        status = VTCompressionSessionEncodeFrame(encoder, pixels, CMTimeMake(i, 30),
            CMTimeMake(1, 30),
            (__bridge CFDictionaryRef)@{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @(i == 0)},
            NULL, NULL);
        // Drain even a failed submission before releasing the callback context.
        OSStatus drained = VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid);
        if (status == noErr) status = drained;
        if (status == noErr) status = frame.status;
        if (frame.sample) [samples addObject:CFBridgingRelease(frame.sample)];
        if (samples.count != i + 1) status = -1;
    }
    if (encoder) { VTCompressionSessionInvalidate(encoder); CFRelease(encoder); }
    CFRelease(pixels);
    if (status != noErr || samples.count != count) {
        fprintf(stderr, "synthetic_h264_failed status=%d callback=%d\n", (int)status, (int)frame.status);
        return nil;
    }
    return samples;
}

static void decoded(void *context, void *frameContext, OSStatus status,
                    VTDecodeInfoFlags flags, CVImageBufferRef image,
                    CMTime presentationTime, CMTime duration) {
    (void)frameContext; (void)flags; (void)presentationTime; (void)duration;
    if (status == noErr && image) *(CVPixelBufferRef *)context = CVPixelBufferRetain(image);
}

CVPixelBufferRef PLANKCameraFixtureDecode(CMSampleBufferRef sample) {
    CVPixelBufferRef image = NULL;
    VTDecompressionSessionRef decoder = NULL;
    VTDecompressionOutputCallbackRecord callback = {decoded, &image};
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault,
        CMSampleBufferGetFormatDescription(sample), NULL,
        (__bridge CFDictionaryRef)attributes, &callback, &decoder);
    if (status == noErr) status = VTDecompressionSessionDecodeFrame(decoder, sample, 0, NULL, NULL);
    if (status == noErr) status = VTDecompressionSessionWaitForAsynchronousFrames(decoder);
    if (decoder) { VTDecompressionSessionInvalidate(decoder); CFRelease(decoder); }
    if (status != noErr && image) { CFRelease(image); image = NULL; }
    return image;
}

NSString *PLANKCameraFixtureDigest(CMSampleBufferRef sample) {
    CMBlockBufferRef buffer = CMSampleBufferGetDataBuffer(sample);
    if (!buffer) return @"no-coded-payload";
    size_t size = CMBlockBufferGetDataLength(buffer);
    if (!size || size > 4 * 1024 * 1024) return @"invalid-coded-payload";
    NSMutableData *bytes = [NSMutableData dataWithLength:size];
    if (CMBlockBufferCopyDataBytes(buffer, 0, size, bytes.mutableBytes) != noErr)
        return @"payload-copy-failed";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)size, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:2 * sizeof(digest)];
    for (size_t i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
