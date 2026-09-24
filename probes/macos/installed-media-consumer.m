// SPDX-License-Identifier: GPL-3.0-or-later
// Select only installed PLANK virtual devices. Never records samples, changes
// default devices, installs extensions, or bypasses normal application consent.
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import "installed-media-validation.h"
#include <stdatomic.h>
#include <unistd.h>

static NSString *const CameraUID = @"03889AD2-D405-4583-98FB-68FB3A811092";
static CFStringRef const MicrophoneUID = CFSTR("la.instinctual.PLANK.Microphone");
static void report(NSDictionary *value) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (json) fwrite(json.bytes, 1, json.length, stdout);
    putchar('\n'); fflush(stdout);
}
static NSString *fourcc(FourCharCode code) {
    char value[5] = {(char)(code>>24), (char)(code>>16), (char)(code>>8), (char)code, 0};
    return [NSString stringWithUTF8String:value] ?: @"invalid";
}
static AVCaptureDevice *camera(void) {
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal] mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionUnspecified];
    for (AVCaptureDevice *device in discovery.devices)
        if ([device.uniqueID isEqual:CameraUID]) return device;
    return nil;
}
static AudioDeviceID microphone(AudioStreamBasicDescription *format) {
    AudioDeviceID device = kAudioObjectUnknown;
    CFStringRef uid = MicrophoneUID;
    AudioValueTranslation translation = {(void *)&uid, sizeof(uid), &device, sizeof(device)};
    AudioObjectPropertyAddress property = {kAudioHardwarePropertyDeviceForUID,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(translation);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &translation) || !device) return 0;
    property.mSelector = kAudioDevicePropertyStreamFormat; property.mScope = kAudioDevicePropertyScopeInput;
    size = sizeof(*format);
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, format)) return 0;
    return device;
}
static BOOL audioFormatValid(AudioStreamBasicDescription format) {
    return format.mSampleRate == 48000 && format.mChannelsPerFrame == 2 &&
        format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
        format.mBytesPerFrame == 8 && format.mBytesPerPacket == 8 && format.mFramesPerPacket == 1 &&
        format.mFormatFlags == (kAudioFormatFlagsNativeFloatPacked);
}
static BOOL allowed(AVMediaType type) {
    BOOL granted = [AVCaptureDevice authorizationStatusForMediaType:type] == AVAuthorizationStatusAuthorized;
    if (!granted) report(@{@"permission_required": [type isEqual:AVMediaTypeVideo] ? @"camera" : @"microphone"});
    return granted;
}

static _Atomic uint64_t audioFrames, audioInvalid, audioNonzero, audioDifferent, audioOverRange, audioEnergy[2];
static OSStatus readAudio(AudioDeviceID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)output; (void)outputTime; (void)context;
    if (!input || input->mNumberBuffers != 1 || input->mBuffers[0].mNumberChannels != 2 ||
        input->mBuffers[0].mDataByteSize % 8) { atomic_fetch_add(&audioInvalid, 1); return noErr; }
    PLANKReadAudioStats stats = PLANKReadAudio(input->mBuffers[0].mData, input->mBuffers[0].mDataByteSize/8);
    atomic_fetch_add(&audioFrames, stats.frames); atomic_fetch_add(&audioInvalid, stats.invalid);
    atomic_fetch_add(&audioNonzero, stats.nonzero); atomic_fetch_add(&audioDifferent, stats.different);
    atomic_fetch_add(&audioOverRange, stats.overRange);
    for (unsigned channel = 0; channel < 2; channel++) atomic_fetch_add(&audioEnergy[channel], stats.energy[channel]);
    return noErr;
}
static int captureAudio(unsigned seconds) {
    if (!allowed(AVMediaTypeAudio)) return 3;
    AudioStreamBasicDescription format = {0}; AudioDeviceID device = microphone(&format);
    if (!device || !audioFormatValid(format)) { report(@{@"microphone_format_valid": @NO}); return 1; }
    AudioDeviceIOProcID io = NULL;
    OSStatus status = AudioDeviceCreateIOProcID(device, readAudio, NULL, &io);
    if (!status) status = AudioDeviceStart(device, io);
    if (!status) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
        while (deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        status = AudioDeviceStop(device, io);
    }
    if (io) { OSStatus destroyed = AudioDeviceDestroyIOProcID(device, io); if (!status) status = destroyed; }
    uint64_t frames = atomic_load(&audioFrames), invalid = atomic_load(&audioInvalid);
    BOOL passed = !status && !invalid && frames >= (uint64_t)seconds*48000*9/10;
    report(@{@"probe": @"installed-microphone", @"seconds": @(seconds), @"status": @(status),
        @"frames": @(frames), @"invalid": @(invalid), @"sample_rate": @48000, @"channels": @2,
        @"nonzero_samples": @(atomic_load(&audioNonzero)), @"different_frames": @(atomic_load(&audioDifferent)),
        @"over_full_scale_samples": @(atomic_load(&audioOverRange)),
        @"left_rms": @(frames ? sqrt(atomic_load(&audioEnergy[0])/1e9/frames) : 0),
        @"right_rms": @(frames ? sqrt(atomic_load(&audioEnergy[1])/1e9/frames) : 0),
        @"delivery_pass": @(passed), @"source_routing_qualified": @NO});
    return passed ? 0 : 1;
}

@interface CameraReader : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
    PLANKReadVideoStats _stats;
}
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureDevice *device;
@property(nonatomic, strong) dispatch_queue_t control, frames;
@property(nonatomic) BOOL pixels, done, locked;
@property(nonatomic) unsigned seconds;
@property(nonatomic) uint64_t dropped;
- (void)finish;
@end
@implementation CameraReader
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample
    fromConnection:(AVCaptureConnection *)connection {
    (void)output; (void)connection;
    if (!self.done) PLANKReadVideo(&_stats, sample, self.pixels);
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sample
    fromConnection:(AVCaptureConnection *)connection {
    (void)output; (void)sample; (void)connection;
    if (!self.done) self.dropped++;
}
- (void)finish {
    // The frame queue owns all statistics, including the deadline callback.
    if (self.done) return;
    self.done = YES;
    double span = _stats.frames > 1 ? CMTimeGetSeconds(CMTimeSubtract(_stats.lastPTS, _stats.firstPTS)) : 0;
    // Delivery threshold deliberately allows startup and physical auto-exposure
    // below nominal 30fps. Rate acceptance remains a separate hardware gate.
    BOOL passed = !_stats.invalid && _stats.frames >= self.seconds*5 && span >= self.seconds*.5;
    NSDictionary *result = @{@"probe": @"installed-camera", @"output": self.pixels ? @"pixels" : @"native",
        @"seconds": @(self.seconds), @"frames": @(_stats.frames), @"invalid": @(_stats.invalid),
        @"app_dropped_frames": @(self.dropped), @"coded_bytes": @(_stats.bytes),
        @"width": @(_stats.width), @"height": @(_stats.height), @"subtype": fourcc(_stats.subtype),
        @"pts_span_seconds": @(span), @"delivery_pass": @(passed), @"source_payload_equality_qualified": @NO};
    dispatch_async(self.control, ^{
        [self.session stopRunning];
        if (self.locked) [self.device unlockForConfiguration];
        report(result); exit(passed ? 0 : 1);
    });
}
@end

int main(int argc, const char *argv[]) { @autoreleasepool {
    BOOL inspect = argc == 2 && !strcmp(argv[1], "--inspect");
    BOOL permission = argc == 3 && !strcmp(argv[1], "--request-permission") &&
        (!strcmp(argv[2], "camera") || !strcmp(argv[2], "microphone"));
    BOOL audio = argc == 4 && !strcmp(argv[1], "--microphone") && !strcmp(argv[2], "--seconds");
    BOOL video = argc == 6 && !strcmp(argv[1], "--camera") &&
        (!strcmp(argv[2], "native") || !strcmp(argv[2], "pixels")) &&
        (!strcmp(argv[3], "auto") || !strcmp(argv[3], "native") || !strcmp(argv[3], "nv12")) &&
        !strcmp(argv[4], "--seconds");
    unsigned seconds = 0;
    if (audio || video) {
        const char *number = argv[argc-1]; char *end = NULL;
        unsigned long value = strtoul(number, &end, 10);
        if (!*number || *end || value < 2 || value > 120) audio = video = NO;
        else seconds = (unsigned)value;
    }
    if (!inspect && !permission && !audio && !video) {
        fputs("Use --inspect, --request-permission camera|microphone, --microphone --seconds 2..120, or --camera native|pixels auto|native|nv12 --seconds 2..120\n", stderr);
        return 2;
    }
    alarm(permission ? 125 : seconds+20);
    if (permission) {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AVMediaType type = !strcmp(argv[2], "camera") ? AVMediaTypeVideo : AVMediaTypeAudio;
        [AVCaptureDevice requestAccessForMediaType:type completionHandler:^(BOOL granted) {
            report(@{@"permission_granted": @(granted)}); exit(granted ? 0 : 3);
        }];
        [[NSRunLoop mainRunLoop] run]; return 1;
    }
    if (audio) return captureAudio(seconds);
    AVCaptureDevice *device = camera();
    if (inspect) {
        NSMutableArray *formats = [NSMutableArray array];
        for (AVCaptureDeviceFormat *format in device.formats) {
            CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            [formats addObject:@{@"subtype": fourcc(CMFormatDescriptionGetMediaSubType(format.formatDescription)),
                @"width": @(size.width), @"height": @(size.height)}];
        }
        AudioStreamBasicDescription format = {0}; AudioDeviceID mic = microphone(&format);
        report(@{@"camera_found": @(device != nil), @"camera_formats": formats, @"microphone_found": @(mic != 0),
            @"microphone_format_valid": @(mic && audioFormatValid(format)),
            @"microphone_rate": @(format.mSampleRate), @"microphone_channels": @(format.mChannelsPerFrame),
            @"camera_permission": @([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]),
            @"microphone_permission": @([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio])});
        return 0; // Inventory is diagnostic; absence is not a capture pass.
    }
    if (!device) { report(@{@"camera_found": @NO}); return 1; }
    if (!allowed(AVMediaTypeVideo)) return 3;
    __attribute__((objc_precise_lifetime)) CameraReader *reader = [[CameraReader alloc] init];
    reader.pixels = !strcmp(argv[2], "pixels"); reader.seconds = seconds; reader.device = device;
    reader.session = [[AVCaptureSession alloc] init];
    reader.control = dispatch_queue_create("plank.installed-media.control", DISPATCH_QUEUE_SERIAL);
    reader.frames = dispatch_queue_create("plank.installed-media.frames", DISPATCH_QUEUE_SERIAL);
    NSString *source = [NSString stringWithUTF8String:argv[3]];
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
        if (![source isEqual:@"auto"]) {
            AVCaptureDeviceFormat *selected = nil;
            for (AVCaptureDeviceFormat *format in device.formats) {
                FourCharCode code = CMFormatDescriptionGetMediaSubType(format.formatDescription);
                if (([source isEqual:@"native"] && (code == kCMVideoCodecType_H264 || code == kCMVideoCodecType_JPEG)) ||
                    ([source isEqual:@"nv12"] && code == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) { selected = format; break; }
            }
            if (!selected || ![device lockForConfiguration:&error]) {
                report(@{@"source_format_unavailable": source}); exit(1);
            }
            reader.locked = YES; device.activeFormat = selected;
            device.activeVideoMinFrameDuration = CMTimeMake(1,30); device.activeVideoMaxFrameDuration = CMTimeMake(1,30);
        }
        output.videoSettings = reader.pixels ?
            @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)} : @{};
        output.alwaysDiscardsLateVideoFrames = YES;
        [output setSampleBufferDelegate:reader queue:reader.frames];
        [reader.session commitConfiguration]; [reader.session startRunning];
        report(@{@"active_source_subtype": fourcc(CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription))});
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds*NSEC_PER_SEC), reader.frames, ^{ [reader finish]; });
    });
    [[NSRunLoop mainRunLoop] run]; return 1;
} }
