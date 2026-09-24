// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-camera-sample.h"
#include "native-camera-payload.h"
#import "native-camera-fixture.h"
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <unistd.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "camera_sample_failed line=%d\n", __LINE__); exit(1); } } while (0)

static NSData *annexB(CMSampleBufferRef sample) {
    NSMutableData *data = [NSMutableData data];
    const uint8_t prefix[] = {0,0,0,1};
    CMVideoFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    for (unsigned i = 0; i < 2; i++) {
        const uint8_t *bytes = NULL; size_t size = 0;
        CHECK(!CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &bytes, &size, NULL, NULL));
        [data appendBytes:prefix length:4]; [data appendBytes:bytes length:size];
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t size = CMBlockBufferGetDataLength(block), at = 0;
    NSMutableData *source = [NSMutableData dataWithLength:size];
    CHECK(!CMBlockBufferCopyDataBytes(block, 0, size, source.mutableBytes));
    const uint8_t *bytes = source.bytes;
    while (at < size) {
        CHECK(size - at >= 4);
        size_t count = plank_transport_control_read_u32(bytes+at); at += 4;
        CHECK(count && count <= size - at);
        [data appendBytes:prefix length:4]; [data appendBytes:bytes+at length:count]; at += count;
    }
    return data;
}
static NSData *jpeg(unsigned width, unsigned height) {
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width*4, color, kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(color); CHECK(context);
    CGContextSetRGBFillColor(context, .2, .6, .4, 1);
    CGContextFillRect(context, CGRectMake(0,0,width,height));
    CGImageRef image = CGBitmapContextCreateImage(context); CHECK(image);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
    CHECK(destination); CGImageDestinationAddImage(destination, image, NULL);
    CHECK(CGImageDestinationFinalize(destination));
    CFRelease(destination); CGImageRelease(image); CGContextRelease(context);
    return data;
}
static CMSampleBufferRef make(PLANKMacNativeCameraSample *owner, PlankCameraHeader header, NSData *payload, uint64_t time) CF_RETURNS_RETAINED;
static CMSampleBufferRef make(PLANKMacNativeCameraSample *owner, PlankCameraHeader header, NSData *payload, uint64_t time) {
    NSMutableData *record = [NSMutableData dataWithLength:PLANK_CAMERA_HEADER_BYTES];
    CHECK(!plank_camera_header_encode(&header, payload.length, record.mutableBytes, record.length));
    [record appendData:payload];
    return [owner copySampleFromRecord:record.bytes size:record.length hostTimeNanos:time];
}
static void preserved(CMSampleBufferRef sample, NSData *source, const PlankCameraHeader *header) {
    PLANKCameraPayload parsed;
    CHECK(PLANKCameraParsePayload(header, source.bytes, source.length, &parsed));
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    NSMutableData *copy = [NSMutableData dataWithLength:CMBlockBufferGetDataLength(block)];
    CHECK(!CMBlockBufferCopyDataBytes(block, 0, copy.length, copy.mutableBytes));
    if (header->codec == PLANK_CAMERA_MJPEG) { CHECK([copy isEqualToData:source]); return; }
    const uint8_t *bytes = copy.bytes; size_t at = 0;
    for (unsigned i = 0; i < parsed.count; i++) {
        PLANKCameraNAL nal = parsed.nals[i];
        CHECK(copy.length - at >= 4 && plank_transport_control_read_u32(bytes+at) == nal.size); at += 4;
        CHECK(copy.length - at >= nal.size && !memcmp(bytes+at, (const uint8_t *)source.bytes+nal.offset, nal.size));
        at += nal.size;
    }
    CHECK(at == copy.length);
}
int main(void) { @autoreleasepool {
    alarm(60);
    CHECK(![[PLANKMacNativeCameraSample alloc] initWithGeneration:0]);
    for (unsigned mode = 0; mode < 2; mode++) {
        PLANKMacNativeCameraSample *owner = [[PLANKMacNativeCameraSample alloc] initWithGeneration:7];
        CMSampleBufferRef fixture = mode ? NULL : PLANKCameraFixtureCreateSized(1280, 720);
        CHECK(mode || fixture);
        NSData *payload = mode ? jpeg(1280,720) : annexB(fixture);
        if (fixture) CFRelease(fixture);
        PlankCameraHeader header = {.generation=7,.capture_time_us=1,.codec=mode ? PLANK_CAMERA_MJPEG : PLANK_CAMERA_H264,
            .width=1280,.height=720,.flags=PLANK_CAMERA_KEY_FRAME};
        CHECK(!make(owner, header, payload, 0));
        CMSampleBufferRef sample = make(owner, header, payload, 1000000000); CHECK(sample);
        CHECK(!owner.needsKeyframe && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(1,1)) == 0);
        preserved(sample, payload, &header);
        CVPixelBufferRef image = PLANKCameraFixtureDecode(sample);
        CHECK(image && CVPixelBufferGetWidth(image) == 1280 && CVPixelBufferGetHeight(image) == 720);
        CFRelease(image); CFRelease(sample);
        CHECK(!make(owner, header, payload, 1000000001)); // Replayed sequence.
        header.sequence = 1; header.capture_time_us = 2;
        CHECK(!make(owner, header, payload, 1000000000)); // Regressed Host time.
        header.capture_time_us = 1;
        CHECK(!make(owner, header, payload, 1100000000)); // Regressed capture time.
        header.capture_time_us = 2; header.generation = 8;
        CHECK(!make(owner, header, payload, 1100000000)); // Other activation.
        header.generation = 7; header.width = 1920; header.height = 1080;
        CHECK(!make(owner, header, payload, 1100000000)); // False dimensions.
        PLANKMacNativeCameraSample *fresh = [[PLANKMacNativeCameraSample alloc] initWithGeneration:7];
        CHECK(!make(fresh, header, payload, 1100000000)); // Must inspect coded dimensions before first format.
        header.width = 1280; header.height = 720;
        if (!mode) {
            const uint8_t slice[] = {0,0,1,0x41,0x80};
            header.sequence = 2; header.flags = 0;
            CHECK(!make(owner, header, [NSData dataWithBytes:slice length:sizeof(slice)], 1100000000));
            CHECK(owner.needsKeyframe);
            header.flags = PLANK_CAMERA_KEY_FRAME;
        }
        header.sequence = 3; header.capture_time_us = 3;
        sample = make(owner, header, payload, 1200000000); CHECK(sample && !owner.needsKeyframe); CFRelease(sample);
        header.sequence = 4; header.capture_time_us = 4;
        NSMutableData *bad = [payload mutableCopy]; ((uint8_t *)bad.mutableBytes)[0] = 0x55;
        CHECK(!make(owner, header, bad, 1300000000) && owner.needsKeyframe);
        header.sequence = 5; header.capture_time_us = 5;
        sample = make(owner, header, payload, 1400000000); CHECK(sample); CFRelease(sample);
        printf("native_camera_sample=pass codec=%s payload_preserved=1 nv12_decode=1 replay_rejected=1 recovery=1\n", mode ? "mjpeg" : "h264");
    }
    return 0;
} }
