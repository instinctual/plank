// SPDX-License-Identifier: GPL-3.0-or-later
// Decode an operator-authorized private capture. No camera access, encoding,
// installation or image output. Input records: big-endian u32 length + bytes.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <stdio.h>
#include <unistd.h>

enum { MaxFrameBytes = 4 * 1024 * 1024, MaxFrames = 300, MaxNALs = 64 };
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "camera_decode_failed line=%d\n", __LINE__); exit(1); } } while (0)
typedef struct { unsigned frames, errors, width, height; } Decoded;

static void decoded(void *context, void *frameContext, OSStatus status,
                    VTDecodeInfoFlags flags, CVImageBufferRef image,
                    CMTime presentationTime, CMTime duration) {
    (void)frameContext; (void)presentationTime; (void)duration;
    Decoded *result = context;
    if (status || !image || (flags & kVTDecodeInfo_FrameDropped) ||
        CVPixelBufferGetWidth(image) != result->width ||
        CVPixelBufferGetHeight(image) != result->height ||
        CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        result->errors++; return;
    }
    result->frames++;
}

static size_t startCode(const uint8_t *bytes, size_t size, size_t at) {
    if (size - at >= 3 && bytes[at] == 0 && bytes[at+1] == 0) {
        if (bytes[at+2] == 1) return 3;
        if (size - at >= 4 && bytes[at+2] == 0 && bytes[at+3] == 1) return 4;
    }
    return 0;
}

// Core Media expects length-prefixed NALs. Reframe, never rewrite the NALs.
// The PLANK transport preservation boundary precedes this Mac adaptation.
static NSData *avcPayload(NSData *annexB, NSData **sps, NSData **pps, BOOL *key) {
    const uint8_t *bytes = annexB.bytes;
    size_t size = annexB.length, at = 0;
    NSMutableData *avc = [NSMutableData data];
    unsigned count = 0, slices = 0;
    while (at < size) {
        size_t prefix = startCode(bytes, size, at);
        CHECK(prefix && ++count <= MaxNALs);
        size_t begin = at + prefix, end = begin;
        while (end < size && !startCode(bytes, size, end)) end++;
        at = end;
        // trailing_zero_8bits belongs to Annex B framing, not the NAL payload.
        while (end > begin && bytes[end-1] == 0) end--;
        CHECK(end > begin && !(bytes[begin] & 0x80));
        unsigned type = bytes[begin] & 31;
        CHECK(type > 0 && type < 24);
        NSData *nal = [NSData dataWithBytes:bytes+begin length:end-begin];
        if (type == 7 || type == 8) {
            CHECK(nal.length <= 4096);
            if (type == 7) *sps = nal; else *pps = nal;
        }
        if (type == 1 || type == 5) slices++;
        if (type == 5) *key = YES;
        uint32_t length = CFSwapInt32HostToBig((uint32_t)nal.length);
        [avc appendBytes:&length length:sizeof(length)];
        [avc appendData:nal];
        CHECK(avc.length <= MaxFrameBytes);
        // Check the adapted copy contains every original NAL byte unchanged.
        CHECK(!memcmp((const uint8_t *)avc.bytes + avc.length - nal.length,
                      bytes + begin, nal.length));
    }
    CHECK(slices && *sps && *pps);
    return avc;
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc != 5) {
        fprintf(stderr, "Usage: native-camera-decode h264|mjpeg WIDTH HEIGHT PRIVATE_RECORDS\n");
        return 2;
    }
    alarm(30);
    BOOL h264 = !strcmp(argv[1], "h264");
    CHECK(h264 || !strcmp(argv[1], "mjpeg"));
    char *end = NULL;
    unsigned long width = strtoul(argv[2], &end, 10); CHECK(*argv[2] && !*end);
    unsigned long height = strtoul(argv[3], &end, 10); CHECK(*argv[3] && !*end);
    CHECK(width >= 16 && width <= 1920 && height >= 16 && height <= 1080);
    FILE *file = fopen(argv[4], "rb"); CHECK(file);
    CMVideoFormatDescriptionRef format = NULL;
    VTDecompressionSessionRef decoder = NULL;
    NSData *sps = nil, *pps = nil;
    Decoded result = {0, 0, (unsigned)width, (unsigned)height};
    unsigned submitted = 0;
    BOOL hardware = NO;
    for (;;) { @autoreleasepool {
        uint32_t length;
        size_t got = fread(&length, 1, sizeof(length), file);
        if (!got) break;
        CHECK(got == sizeof(length) && submitted < MaxFrames);
        length = CFSwapInt32BigToHost(length);
        CHECK(length && length <= MaxFrameBytes);
        NSMutableData *record = [NSMutableData dataWithLength:length];
        CHECK(fread(record.mutableBytes, 1, length, file) == length);
        NSData *payload = record;
        BOOL key = !h264;
        if (h264) {
            payload = avcPayload(record, &sps, &pps, &key);
            const uint8_t *sets[] = {sps.bytes, pps.bytes};
            size_t sizes[] = {sps.length, pps.length};
            CMVideoFormatDescriptionRef candidate = NULL;
            CHECK(!CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                2, sets, sizes, 4, &candidate));
            CHECK(candidate);
            if (format) {
                CHECK(CMFormatDescriptionEqual(format, candidate)); CFRelease(candidate);
            } else { CHECK(key); format = candidate; }
        } else {
            const uint8_t *bytes = record.bytes;
            CHECK(length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8 &&
                  bytes[length-2] == 0xff && bytes[length-1] == 0xd9);
            if (!format) CHECK(!CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                kCMVideoCodecType_JPEG, (int32_t)width, (int32_t)height, NULL, &format));
        }
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
        CHECK(dimensions.width == (int32_t)width && dimensions.height == (int32_t)height);
        if (!decoder) {
            VTDecompressionOutputCallbackRecord callback = {decoded, &result};
            NSDictionary *attributes = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
            };
            CHECK(!VTDecompressionSessionCreate(kCFAllocatorDefault, format, NULL,
                (__bridge CFDictionaryRef)attributes, &callback, &decoder));
            CHECK(decoder);
            CFTypeRef accelerated = NULL;
            if (!VTSessionCopyProperty(decoder, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                       kCFAllocatorDefault, &accelerated) && accelerated) {
                hardware = CFEqual(accelerated, kCFBooleanTrue); CFRelease(accelerated);
            }
        }
        CMBlockBufferRef block = NULL;
        CHECK(!CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, payload.length,
            kCFAllocatorDefault, NULL, 0, payload.length, 0, &block));
        CHECK(!CMBlockBufferReplaceDataBytes(payload.bytes, block, 0, payload.length));
        CMSampleTimingInfo timing = {CMTimeMake(1,30), CMTimeMake(submitted,30), kCMTimeInvalid};
        size_t bytes = payload.length;
        CMSampleBufferRef sample = NULL;
        CHECK(!CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, 1, 1, &timing,
                                         1, &bytes, &sample));
        CFRelease(block);
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
                             kCMSampleAttachmentKey_NotSync, key ? kCFBooleanFalse : kCFBooleanTrue);
        CHECK(!VTDecompressionSessionDecodeFrame(decoder, sample, 0, NULL, NULL));
        CHECK(!VTDecompressionSessionWaitForAsynchronousFrames(decoder));
        CFRelease(sample); submitted++;
        CHECK(!result.errors);
    } }
    CHECK(!ferror(file)); fclose(file);
    CHECK(submitted && decoder);
    CHECK(!VTDecompressionSessionFinishDelayedFrames(decoder));
    CHECK(!VTDecompressionSessionWaitForAsynchronousFrames(decoder));
    VTDecompressionSessionInvalidate(decoder); CFRelease(decoder); CFRelease(format);
    CHECK(!result.errors && result.frames == submitted);
    printf("native_camera_decode=pass codec=%s width=%lu height=%lu submitted=%u decoded=%u hardware=%d pixels=420v client_transcode=0\n",
           argv[1], width, height, submitted, result.frames, hardware);
    return 0;
} }
