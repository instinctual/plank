// SPDX-License-Identifier: GPL-3.0-or-later
// Decode an operator-authorized private capture. No camera access, encoding,
// installation or image output. Input records: big-endian u32 length + bytes.
#import <Foundation/Foundation.h>
#import "../../apps/host/macos/media/native-camera-output.h"
#import "../../apps/host/macos/media/native-camera-sample.h"
#include "../../apps/host/macos/media/native-camera-payload.h"
#include <stdio.h>
#include <unistd.h>

enum { MaxFrameBytes = 4 * 1024 * 1024, MaxFrames = 300 };
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "camera_decode_failed line=%d\n", __LINE__); exit(1); } } while (0)
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
    CHECK((width == 1280 && height == 720) || (width == 1920 && height == 1080));
    FILE *file = fopen(argv[4], "rb"); CHECK(file);
    PLANKMacNativeCameraOutput *output = nil;
    PLANKMacNativeCameraSample *owner = [[PLANKMacNativeCameraSample alloc] initWithGeneration:1];
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
        PLANKCameraPayload parsed = {0};
        BOOL key = !h264;
        if (h264) {
            CHECK(PLANKCameraParseAVC(record.bytes, record.length, &parsed));
            key = parsed.independent;
        }
        PlankCameraHeader header = {.generation=1, .sequence=submitted,
            .capture_time_us=1 + (uint64_t)submitted*33333,
            .codec=h264 ? PLANK_CAMERA_H264 : PLANK_CAMERA_MJPEG,
            .width=(uint16_t)width, .height=(uint16_t)height,
            .flags=key ? PLANK_CAMERA_KEY_FRAME : 0};
        NSMutableData *envelope = [NSMutableData dataWithLength:PLANK_CAMERA_HEADER_BYTES];
        CHECK(!plank_camera_header_encode(&header, record.length, envelope.mutableBytes, envelope.length));
        [envelope appendData:record];
        CMSampleBufferRef sample = [owner copySampleFromRecord:envelope.bytes size:envelope.length
            hostTimeNanos:1000000000 + (uint64_t)submitted*33333333];
        CHECK(sample);
        if (!output) {
            output = [[PLANKMacNativeCameraOutput alloc] initWithFormat:CMSampleBufferGetFormatDescription(sample)];
            CHECK(output); [output setPixelOutput:YES];
        }
        CMSampleBufferRef pixels = [output copyOutputForSample:sample]; CHECK(pixels);
        CVPixelBufferRef image = CMSampleBufferGetImageBuffer(pixels);
        CHECK(image && CVPixelBufferGetWidth(image) == width && CVPixelBufferGetHeight(image) == height &&
            CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        CHECK(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(pixels), CMSampleBufferGetPresentationTimeStamp(sample)) == 0);
        hardware = output.hardwareDecoder;
        CFRelease(pixels); CFRelease(sample); submitted++;
    } }
    CHECK(!ferror(file)); fclose(file);
    CHECK(submitted && output.decodedFrames == submitted);
    printf("native_camera_decode=pass codec=%s width=%lu height=%lu submitted=%u decoded=%u hardware=%d pixels=420v client_transcode=0 product_sample_validation=1\n",
           argv[1], width, height, submitted, (unsigned)output.decodedFrames, hardware);
    return 0;
} }
