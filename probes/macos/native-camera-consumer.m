// SPDX-License-Identifier: GPL-3.0-or-later
// Only selects our synthetic device. Never records a physical camera or audio.
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <SystemExtensions/SystemExtensions.h>
#import "native-camera-fixture.h"
#include <unistd.h>

static void report(NSDictionary *value) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (json) fwrite(json.bytes, 1, json.length, stdout);
    putchar('\n'); fflush(stdout);
}
static NSString *fourcc(FourCharCode code) {
    char text[5] = {(char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0};
    return [NSString stringWithUTF8String:text] ?: @"invalid";
}

@interface ProbeActivation : NSObject <OSSystemExtensionRequestDelegate>
@end
@implementation ProbeActivation
- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request {
    (void)request; report(@{@"extension_activation": @"needs_user_approval"});
}
- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
    (void)request; report(@{@"extension_activation": @"failed", @"domain": error.domain, @"code": @(error.code)}); exit(1);
}
- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    (void)request; report(@{@"extension_activation": @"finished", @"result": @(result)});
    exit(result == OSSystemExtensionRequestCompleted ? 0 : 2);
}
- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request
                 actionForReplacingExtension:(OSSystemExtensionProperties *)existing
                               withExtension:(OSSystemExtensionProperties *)candidate {
    (void)request;
    return [existing.bundleIdentifier isEqual:PLANK_CAMERA_EXTENSION_ID] &&
           [candidate.bundleIdentifier isEqual:PLANK_CAMERA_EXTENSION_ID] ?
        OSSystemExtensionReplacementActionReplace : OSSystemExtensionReplacementActionCancel;
}
@end

@interface ProbeCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureDevice *device;
@property(nonatomic, strong) dispatch_queue_t control;
@property(nonatomic, strong) dispatch_queue_t frames;
@property(nonatomic, strong) NSString *mode;
@property(nonatomic, strong) NSString *firstHash;
@property(nonatomic, strong) NSMutableSet<NSString *> *subtypes;
@property(nonatomic) NSUInteger count, images, coded;
@property(nonatomic) NSUInteger targetFrames;
@property(nonatomic) uint64_t firstFrameHostTime, lastFrameHostTime;
@property(nonatomic) BOOL configurationLocked;
@property(nonatomic) BOOL done, stableHash, validPixels;
- (void)finish:(BOOL)timedOut;
@end
@implementation ProbeCapture
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample
      fromConnection:(AVCaptureConnection *)connection {
    (void)output; (void)connection;
    if (self.done) return;
    uint64_t hostTime = (uint64_t)CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()),
        NSEC_PER_SEC, kCMTimeRoundingMethod_Default).value;
    if (!self.count) self.firstFrameHostTime = hostTime;
    self.lastFrameHostTime = hostTime;
    FourCharCode subtype = CMFormatDescriptionGetMediaSubType(CMSampleBufferGetFormatDescription(sample));
    [self.subtypes addObject:fourcc(subtype)];
    CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (image) {
        self.images++;
        self.validPixels = self.validPixels && CVPixelBufferGetWidth(image) == 320 &&
            CVPixelBufferGetHeight(image) == 240 &&
            CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
    if (CMSampleBufferGetDataBuffer(sample) && subtype == kCMVideoCodecType_H264) {
        self.coded++;
        NSString *hash = PLANKCameraFixtureDigest(sample);
        if (!self.firstHash) self.firstHash = hash;
        self.stableHash = self.stableHash && [hash isEqual:self.firstHash] && hash.length == 64;
    }
    if (++self.count >= self.targetFrames) [self finish:NO];
}
- (void)finish:(BOOL)timedOut {
    // Called only on the serial frame queue, including the timeout callback.
    if (self.done) return;
    self.done = YES;
    BOOL passed = !timedOut && self.count >= self.targetFrames &&
        ([self.mode isEqual:@"native"] ? self.coded == self.count && self.stableHash :
         self.images == self.count && self.validPixels);
    NSDictionary *result = @{
        @"probe": @"native-camera-consumer", @"output_request": self.mode,
        @"frames": @(self.count), @"image_frames": @(self.images), @"h264_frames": @(self.coded),
        @"subtypes": self.subtypes.allObjects, @"first_h264_sha256": self.firstHash ?: @"none",
        @"stable_h264_payload": @(self.stableHash && self.coded > 0),
        @"first_frame_host_ns": @(self.firstFrameHostTime),
        @"last_frame_host_ns": @(self.lastFrameHostTime),
        @"timed_out": @(timedOut), @"passed": @(passed)
    };
    dispatch_async(self.control, ^{
        [self.session stopRunning];
        if (self.configurationLocked) {
            [self.device unlockForConfiguration];
            self.configurationLocked = NO;
        }
        report(result);
        exit(passed ? 0 : 1);
    });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && (!strcmp(argv[1], "--activate") || !strcmp(argv[1], "--deactivate"))) {
            [NSApplication sharedApplication];
            __attribute__((objc_precise_lifetime)) ProbeActivation *delegate = [[ProbeActivation alloc] init];
            OSSystemExtensionRequest *request = !strcmp(argv[1], "--activate") ?
                [OSSystemExtensionRequest activationRequestForExtension:PLANK_CAMERA_EXTENSION_ID queue:dispatch_get_main_queue()] :
                [OSSystemExtensionRequest deactivationRequestForExtension:PLANK_CAMERA_EXTENSION_ID queue:dispatch_get_main_queue()];
            request.delegate = delegate;
            [OSSystemExtensionManager.sharedManager submitRequest:request];
            [[NSRunLoop mainRunLoop] run];
            return 1;
        }
        if (argc == 2 && !strcmp(argv[1], "--request-camera-permission")) {
            [NSApplication sharedApplication];
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                report(@{@"camera_permission_granted": @(granted)}); exit(granted ? 0 : 3);
            }];
            [[NSRunLoop mainRunLoop] run];
            return 1;
        }
        BOOL inspect = argc == 2 && !strcmp(argv[1], "--inspect");
        BOOL capture = (argc == 4 || argc == 6) && !strcmp(argv[1], "--capture") &&
            (!strcmp(argv[2], "native") || !strcmp(argv[2], "pixels")) &&
            (!strcmp(argv[3], "h264") || !strcmp(argv[3], "nv12") || !strcmp(argv[3], "auto"));
        NSUInteger targetFrames = 30;
        if (capture && argc == 6) {
            char *end = NULL;
            unsigned long requested = strtoul(argv[5], &end, 10);
            if (strcmp(argv[4], "--frames") || !argv[5][0] || *end || requested < 1 || requested > 180)
                capture = NO;
            else targetFrames = requested;
        }
        if (!inspect && !capture) {
            fputs("Use --inspect, --activate, --deactivate, --request-camera-permission, or --capture native|pixels h264|nv12|auto [--frames 1..180]\n", stderr);
            return 2;
        }
        alarm(20);
        AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal] mediaType:AVMediaTypeVideo
            position:AVCaptureDevicePositionUnspecified];
        AVCaptureDevice *device = nil;
        for (AVCaptureDevice *candidate in discovery.devices)
            if ([candidate.uniqueID isEqual:PLANK_CAMERA_DEVICE_ID]) device = candidate;
        if (!device) { report(@{@"synthetic_device_found": @NO}); return 1; }
        NSMutableArray *formats = [NSMutableArray array];
        for (AVCaptureDeviceFormat *format in device.formats) {
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            [formats addObject:@{@"subtype": fourcc(CMFormatDescriptionGetMediaSubType(format.formatDescription)),
                                  @"width": @(dimensions.width), @"height": @(dimensions.height)}];
        }
        report(@{@"synthetic_device_found": @YES, @"formats": formats});
        if (inspect) return 0;
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
            // No hidden permission prompt: approve this signed probe through a deliberate GUI launch first.
            report(@{@"camera_permission": @"required_for_signed_probe"}); return 3;
        }
        __attribute__((objc_precise_lifetime)) ProbeCapture *reader = [[ProbeCapture alloc] init];
        reader.mode = [NSString stringWithUTF8String:argv[2]];
        reader.subtypes = [NSMutableSet set]; reader.stableHash = YES; reader.validPixels = YES;
        reader.control = dispatch_queue_create("plank.probe.capture-control", DISPATCH_QUEUE_SERIAL);
        reader.frames = dispatch_queue_create("plank.probe.capture-frames", DISPATCH_QUEUE_SERIAL);
        reader.session = [[AVCaptureSession alloc] init];
        reader.device = device;
        reader.targetFrames = targetFrames;
        NSString *sourceFormat = [NSString stringWithUTF8String:argv[3]];
        dispatch_async(reader.control, ^{
            NSError *error = nil;
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
            if (!input) { report(@{@"input_error": @(error.code)}); exit(1); }
            AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
            [reader.session beginConfiguration];
            if (![reader.session canAddInput:input]) exit(1);
            [reader.session addInput:input];
            if (![reader.session canAddOutput:output]) exit(1);
            [reader.session addOutput:output];
            if (![sourceFormat isEqual:@"auto"]) {
                FourCharCode wanted = [sourceFormat isEqual:@"h264"] ? kCMVideoCodecType_H264 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
                AVCaptureDeviceFormat *selected = nil;
                for (AVCaptureDeviceFormat *format in device.formats)
                    if (CMFormatDescriptionGetMediaSubType(format.formatDescription) == wanted) { selected = format; break; }
                if (!selected || ![device lockForConfiguration:&error]) {
                    report(@{@"requested_source_format_unavailable": sourceFormat}); exit(1);
                }
                device.activeFormat = selected;
                device.activeVideoMinFrameDuration = CMTimeMake(1,30);
                device.activeVideoMaxFrameDuration = CMTimeMake(1,30);
                // macOS may change activeFormat at commit/start unless the lock
                // remains held. Pin only this synthetic device in explicit modes;
                // the auto cases deliberately leave negotiation unconstrained.
                reader.configurationLocked = YES;
            }
            output.videoSettings = [reader.mode isEqual:@"native"] ? @{} :
                @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
            [output setSampleBufferDelegate:reader queue:reader.frames];
            output.alwaysDiscardsLateVideoFrames = YES;
            [reader.session commitConfiguration];
            [reader.session startRunning];
            report(@{@"active_source_subtype": fourcc(CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription))});
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), reader.frames, ^{ [reader finish:YES]; });
        });
        [[NSRunLoop mainRunLoop] run];
        return 1;
    }
}
