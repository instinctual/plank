// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic, non-installing format probe. No camera, microphone or screen input.
#import <Foundation/Foundation.h>
#import <CoreMediaIO/CoreMediaIO.h>
#import <VideoToolbox/VideoToolbox.h>
#include <unistd.h>
#import "native-camera-fixture.h"

static NSString *fourcc(FourCharCode code) {
    char text[5] = {(char)(code >> 24), (char)(code >> 16),
                    (char)(code >> 8), (char)code, 0};
    return [NSString stringWithUTF8String:text] ?: @"invalid";
}

static NSDictionary *inspectFormat(CMVideoFormatDescriptionRef description) {
    NSMutableDictionary *result = [@{
        @"subtype": fourcc(CMFormatDescriptionGetMediaSubType(description)),
        @"constructed": @NO, @"secure_archive_round_trip": @NO
    } mutableCopy];
    @try {
        CMIOExtensionStreamFormat *format = [[CMIOExtensionStreamFormat alloc]
            initWithFormatDescription:description
            maxFrameDuration:CMTimeMake(1, 30) minFrameDuration:CMTimeMake(1, 30)
            validFrameDurations:nil];
        result[@"constructed"] = @(format != nil);
        if (format) {
            NSError *error = nil;
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:format
                requiringSecureCoding:YES error:&error];
            CMIOExtensionStreamFormat *copy = data ?
                [NSKeyedUnarchiver unarchivedObjectOfClass:CMIOExtensionStreamFormat.class
                    fromData:data error:&error] : nil;
            result[@"secure_archive_round_trip"] =
                @(copy && CMFormatDescriptionEqual(description, copy.formatDescription));
            if (error) {
                result[@"archive_error_code"] = @(error.code);
                result[@"archive_error"] = error.localizedDescription;
            }
        }
    } @catch (NSException *exception) {
        result[@"exception"] = exception.name;
        result[@"reason"] = exception.reason ?: @"unspecified";
    }
    return result;
}

int main(int argc, const char *argv[]) {
    (void)argv;
    if (argc != 1) return 2;
    // Bound a framework stall without touching any system service.
    alarm(20);
    @autoreleasepool {
        const int width = 320, height = 240;
        CMSampleBufferRef sample = PLANKCameraFixtureCreate();
        if (!sample) return 1;
        OSStatus status;
        NSMutableArray *formats = [NSMutableArray array];
        [formats addObject:inspectFormat(CMSampleBufferGetFormatDescription(sample))];
        for (NSNumber *subtype in @[@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                    @(kCVPixelFormatType_32BGRA), @(kCMVideoCodecType_JPEG)]) {
            CMVideoFormatDescriptionRef description = NULL;
            status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, subtype.unsignedIntValue,
                                                     width, height, NULL, &description);
            if (status != noErr) { CFRelease(sample); return 1; }
            [formats addObject:inspectFormat(description)];
            CFRelease(description);
        }
        CVPixelBufferRef decoded = PLANKCameraFixtureDecode(sample);
        BOOL decodeValid = decoded && CVPixelBufferGetWidth(decoded) == (size_t)width &&
            CVPixelBufferGetHeight(decoded) == (size_t)height &&
            CVPixelBufferGetPixelFormatType(decoded) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        if (decoded) CFRelease(decoded);
        NSDictionary *report = @{
            @"probe": @"native-camera-formats", @"synthetic_h264_bytes": @(CMSampleBufferGetTotalSampleSize(sample)),
            @"h264_decode_to_nv12": @(decodeValid), @"synthetic_h264_sha256": PLANKCameraFixtureDigest(sample),
            @"formats": formats, @"extension_installed": @NO,
            @"application_delivery_tested": @NO
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        putchar('\n');
        CFRelease(sample);
        return json && decodeValid ? 0 : 1;
    }
}
