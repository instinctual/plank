// SPDX-License-Identifier: GPL-3.0-or-later
#import "screen-capture.h"
#import "opus-encoder.h"
#import "audio-tap.h"
#import "../audio-device/output-route.h"
#import "fixed-capture.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#include <time.h>
#include <math.h>
#include "frame-timing.h"

@interface PLANKMacScreenCapture () <SCStreamOutput, SCStreamDelegate>
@end

@implementation PLANKMacScreenCapture {
    dispatch_queue_t _queue;
    PLANKMacNativeVideo *_video;
    PLANKMacNativeAudio *_audio;
    PLANKMacOpusEncoder *_audioEncoder;
    PLANKMacAudioTap *_audioTap;
    PLANKMacOutputRoute *_outputSelection;
    BOOL _desktopAudioTap, _audioStopped;
    BOOL _audioReady, _audioRestartPending, _audioDiscontinuity;
    unsigned _audioRestarts;
    SCStream *_stream;
    VTCompressionSessionRef _encoder;
    void (^_failed)(void);
    void (^_drained)(void);
    BOOL _stopping, _captureStopped, _starting;
    unsigned _inFlight;
    BOOL _changingEncoder, _buildingEncoder;
    uint32_t _replacementBitrate;
    void (^_replacementCompletion)(uint32_t);
    size_t _width, _height;
    BOOL _fullChroma;
    CMTime _lastPTS;
    uint64_t _completeFrames, _preEncodeDrops, _encoderDrops, _sendDrops;
    uint64_t _maxEncodeNs, _maxCallbackQueueNs;
    PLANKFrameTiming *_timing;
}
- (instancetype)init { return [self initWithDesktopAudioTap:NO]; }
- (instancetype)initWithDesktopAudioTap:(BOOL)desktopAudioTap {
    self = [super init];
    if (self) { _desktopAudioTap = desktopAudioTap; _audioStopped = YES; }
    return self;
}

+ (VTCompressionSessionRef)createEncoder:(uint32_t)bitrate width:(size_t)width height:(size_t)height fullChroma:(BOOL)fullChroma {
    VTCompressionSessionRef encoder = NULL;
    NSDictionary *spec = @{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES};
    NSDictionary *surface = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(fullChroma ?
            kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    if (VTCompressionSessionCreate(NULL, (int32_t)width, (int32_t)height, kCMVideoCodecType_HEVC,
        (__bridge CFDictionaryRef)spec, (__bridge CFDictionaryRef)surface, NULL, NULL, NULL, &encoder)) return NULL;
    NSDictionary *properties = @{
        (__bridge NSString *)kVTCompressionPropertyKey_RealTime: @YES,
        (__bridge NSString *)kVTCompressionPropertyKey_AllowFrameReordering: @NO,
        // Qualified mixed idle/motion behavior: preserve actual SCK timestamps.
        (__bridge NSString *)kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: @YES,
        (__bridge NSString *)kVTCompressionPropertyKey_ExpectedFrameRate: @60,
        (__bridge NSString *)kVTCompressionPropertyKey_MaxKeyFrameInterval: @120,
        (__bridge NSString *)kVTCompressionPropertyKey_AverageBitRate: @((uint64_t)bitrate * 1000),
        // Two times target over one second, in bytes; not an added frame queue.
        (__bridge NSString *)kVTCompressionPropertyKey_DataRateLimits: @[@((uint64_t)bitrate * 250), @1],
        // SDK27 exports this Main44410 value but does not declare it in headers.
        // Exact hardware setup must succeed; never fall back to Main10 here.
        (__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel: (__bridge NSString *)(fullChroma ?
            CFSTR("HEVC_Main44410_AutoLevel") : kVTProfileLevel_HEVC_Main10_AutoLevel),
        (__bridge NSString *)kVTCompressionPropertyKey_ColorPrimaries: (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2,
        (__bridge NSString *)kVTCompressionPropertyKey_TransferFunction: (__bridge NSString *)kCVImageBufferTransferFunction_sRGB,
        (__bridge NSString *)kVTCompressionPropertyKey_YCbCrMatrix: (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2
    };
    BOOL valid = !VTSessionSetProperties(encoder, (__bridge CFDictionaryRef)properties) &&
        !VTCompressionSessionPrepareToEncodeFrames(encoder);
    CFTypeRef hardware = NULL;
    OSStatus result = VTSessionCopyProperty(encoder, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &hardware);
    valid = valid && !result && hardware && CFEqual(hardware, kCFBooleanTrue);
    if (hardware) CFRelease(hardware);
    if (!valid) { VTCompressionSessionInvalidate(encoder); CFRelease(encoder); return NULL; }
    return encoder;
}
- (void)setBitrate:(uint32_t)bitrate completion:(void (^)(uint32_t))completion {
    if (!_encoder || !completion || _stopping || _changingEncoder || bitrate < 10000 || bitrate > 150000) {
        if (completion) completion(0); return;
    }
    _changingEncoder = YES; _replacementBitrate = bitrate;
    _replacementCompletion = [completion copy];
    [self replaceEncoderWhenDrained];
}
- (void)replaceEncoderWhenDrained {
    if (!_changingEncoder || _buildingEncoder || _inFlight || _stopping) return;
    _buildingEncoder = YES;
    size_t width = _width, height = _height;
    uint32_t bitrate = _replacementBitrate;
    BOOL fullChroma = _fullChroma;
    // No old frame can cross the switch. Framework setup is off the session
    // queue so input, audio, network control and cancellation stay responsive.
    VTCompressionSessionInvalidate(_encoder); CFRelease(_encoder); _encoder = NULL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VTCompressionSessionRef replacement = [PLANKMacScreenCapture createEncoder:bitrate width:width height:height fullChroma:fullChroma];
        dispatch_async(self->_queue, ^{
            self->_buildingEncoder = NO; self->_changingEncoder = NO;
            if (self->_stopping) {
                if (replacement) { VTCompressionSessionInvalidate(replacement); CFRelease(replacement); }
                [self finishStop]; return;
            }
            self->_encoder = replacement;
            [self->_video requestKeyFrame];
            void (^completion)(uint32_t) = self->_replacementCompletion;
            self->_replacementCompletion = nil;
            NSLog(@"PLANK encoder replacement: target=%u Kbps peak=%u Kbps ready=%d", bitrate, bitrate * 2, replacement != NULL);
            if (completion) completion(replacement ? bitrate * 2 : 0);
        });
    });
}
- (BOOL)available { return CGPreflightScreenCaptureAccess(); }
- (void)createAudioEncoder {
    __weak typeof(self) weakSelf = self;
    _audioEncoder = [[PLANKMacOpusEncoder alloc] initWithOutput:^BOOL(NSData *packet, CMTime pts, BOOL discontinuity) {
        typeof(self) capture = weakSelf;
        if (!capture || capture->_stopping) return NO;
        int32_t sent = [capture->_audio sendOpusPacket:packet presentationTime:pts
            discontinuity:discontinuity || capture->_audioDiscontinuity];
        BOOL accepted = sent == PLANK_TRANSPORT_OK || sent == PLANK_TRANSPORT_DROPPED;
        if (accepted) capture->_audioDiscontinuity = NO;
        else NSLog(@"PLANK audio send failed: result=%d", sent);
        return accepted;
    }];
}
- (void)createDesktopAudioTap {
    __weak typeof(self) weakSelf = self;
    _audioReady = NO;
    _audioTap = [[PLANKMacAudioTap alloc] initWithQueue:_queue sample:^BOOL(CMSampleBufferRef sample) {
        typeof(self) capture = weakSelf;
        return capture && !capture->_stopping && [capture->_audioEncoder encodeSample:sample];
    } failed:^{
        typeof(self) capture = weakSelf;
        if (capture && !capture->_stopping) [capture disableDesktopAudio];
    }];
    _audioStopped = _audioTap == nil;
    if (!_audioTap) NSLog(@"PLANK desktop audio unavailable; video and input remain enabled");
}
- (void)startDesktopAudio {
    if (_stopping || !_audioTap) return;
    NSLog(@"PLANK desktop audio starting; video and input are ready");
    __weak typeof(self) weakSelf = self;
    [_audioTap startWithCompletion:^(BOOL ready) {
        typeof(self) capture = weakSelf;
        if (!capture || capture->_stopping) return;
        capture->_audioReady = ready;
        if (!ready) [capture disableDesktopAudio];
        else if (capture.outputRoute) {
            capture->_outputSelection = capture.outputRoute(capture->_queue);
            [capture->_outputSelection start];
        }
    }];
}
- (void)startWithTopology:(NSDictionary *)topology bitrate:(uint32_t)bitrate video:(PLANKMacNativeVideo *)video
                   audio:(PLANKMacNativeAudio *)audio
                   queue:(dispatch_queue_t)queue started:(void (^)(uint32_t))started failed:(void (^)(void))failed {
    if (_queue || !queue || !video || !audio || !started || !failed) { if (failed) failed(); return; }
    _queue = queue; _video = video; _audio = audio; _failed = [failed copy];
    _timing = PLANKFrameTimingCreate();
    [self createAudioEncoder];
    if (_desktopAudioTap) [self createDesktopAudioTap];
    _lastPTS = kCMTimeInvalid;
    _width = [topology[@"capture"][@"width"] unsignedIntegerValue];
    _height = [topology[@"capture"][@"height"] unsignedIntegerValue];
    NSString *identifier = topology[@"capture"][@"id"];
    NSDictionary *profile = topology[@"capture"][@"encoding_profile"];
    if (![profile isEqual:PLANKMacEncodingProfile(profile[@"encoding_mode"])]) {
        NSLog(@"PLANK capture startup failed: invalid encoding profile"); failed(); return;
    }
    _fullChroma = [profile[@"chroma"] isEqual:@"4:4:4"];
    if (![self available]) {
        NSLog(@"PLANK capture startup failed: Screen Recording permission required"); failed(); return;
    }
    if (!_width || !_height || _width > 8192 || _height > 8192 || (_width & 1) || (_height & 1)) {
        NSLog(@"PLANK capture startup failed: invalid dimensions"); failed(); return;
    }
    _starting = YES;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(self->_queue, ^{
            self->_starting = NO;
            if (self->_stopping) { self->_captureStopped = YES; [self finishStop]; return; }
            SCDisplay *selected = nil;
            for (SCDisplay *display in content.displays)
                if ([[NSString stringWithFormat:@"cgdisplay:%u", display.displayID] isEqual:identifier]) selected = display;
            if (error || !selected) {
                NSLog(@"PLANK capture startup failed: display discovery error=%ld display-found=%d", (long)error.code, selected != nil);
                self->_failed(); return;
            }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:selected excludingWindows:@[]];
            double w = filter.contentRect.size.width * filter.pointPixelScale;
            double h = filter.contentRect.size.height * filter.pointPixelScale;
            if (!isfinite(w) || !isfinite(h) || w != self->_width || h != self->_height) {
                NSLog(@"PLANK capture startup failed: geometry mismatch requested=%lux%lu actual=%.0fx%.0f",
                    (unsigned long)self->_width, (unsigned long)self->_height, w, h);
                self->_failed(); return;
            }
            uint32_t peak = bitrate * 2;
            self->_encoder = [PLANKMacScreenCapture createEncoder:bitrate width:self->_width height:self->_height fullChroma:self->_fullChroma];
            if (!self->_encoder) {
                NSLog(@"PLANK capture startup failed: VideoToolbox encoder initialization"); self->_failed(); return;
            }
            SCStreamConfiguration *config = [SCStreamConfiguration new];
            config.width = self->_width; config.height = self->_height;
            // Native cadence on the qualified 60 Hz displays. An explicit 1/60
            // SCK throttle skipped refresh intervals in capture-only tests.
            config.minimumFrameInterval = kCMTimeZero; config.queueDepth = 3;
            config.pixelFormat = self->_fullChroma ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange :
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
            config.captureDynamicRange = SCCaptureDynamicRangeSDR; config.colorSpaceName = kCGColorSpaceSRGB;
            // macOS uses ScreenCaptureKit's embedded system/application cursor.
            // This is the Mac contract, not a Linux separate-cursor fallback.
            config.showsCursor = YES; config.capturesAudio = !self->_desktopAudioTap;
            config.captureMicrophone = NO; config.sampleRate = 48000; config.channelCount = 2;
            config.excludesCurrentProcessAudio = YES;
            self->_stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
            if (![self->_stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self->_queue error:NULL] ||
                (!self->_desktopAudioTap && ![self->_stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self->_queue error:NULL])) {
                self->_failed(); return;
            }
            self->_starting = YES;
            [self->_stream startCaptureWithCompletionHandler:^(NSError *startError) {
                dispatch_async(self->_queue, ^{
                    self->_starting = NO;
                    if (self->_stopping) { [self stopCapture]; return; }
                    if (startError) {
                        NSLog(@"PLANK capture startup failed: ScreenCaptureKit error=%ld", (long)startError.code);
                        self->_failed(); return;
                    }
                    // Screen/input readiness is independent of optional audio
                    // consent. In particular, remote input must already work
                    // while macOS presents an audio permission dialog.
                    started(peak);
                    [self startDesktopAudio];
                });
            }];
        });
    }];
}
- (void)disableDesktopAudio {
    if (!_audioTap) return;
    // Retry only a previously active tap, never a denied/pending consent flow.
    // Cap restarts per connection; persistent HAL/transport faults must not loop.
    _audioRestartPending = _audioReady && !_stopping && _audioRestarts < 3;
    if (_audioRestartPending) ++_audioRestarts;
    NSLog(@"PLANK desktop audio interrupted; video and input continue; restart=%d attempt=%u/3",
        _audioRestartPending, _audioRestarts);
    _audioReady = NO;
    [_audioEncoder stop]; _audioEncoder = nil;
    [self stopDesktopAudio];
}
- (void)stopDesktopAudio {
    PLANKMacAudioTap *tap = _audioTap;
    if (!tap) return;
    _audioTap = nil; // one stop per tap, including failure followed by disconnect
    PLANKMacOutputRoute *route = _outputSelection; _outputSelection = nil;
    void (^stopTap)(void) = ^{
        [tap stopWithCompletion:^{
            self->_audioStopped = YES;
            [self finishStop];
            if (self->_stopping || !self->_audioRestartPending) return;
            // HAL teardown and release of the single-tap slot have completed.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self->_queue, ^{
                if (self->_stopping || !self->_audioRestartPending) return;
                self->_audioRestartPending = NO;
                self->_audioDiscontinuity = YES; // new encoder clock/priming, same transport
                [self createAudioEncoder];
                [self createDesktopAudioTap];
                [self startDesktopAudio];
            });
        }];
    };
    // Keep local suppression until routing restoration completes (or times out).
    if (route) [route stopWithCompletion:stopTap]; else stopTap();
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    (void)stream;
    if (_stopping) return;
    if (type == SCStreamOutputTypeAudio) {
        PLANKMacOpusEncoder *encoder = _audioEncoder;
        if (![encoder encodeSample:sample]) {
            fprintf(stderr, "macos_capture_failure stage=audio\n");
            _failed();
        }
        return;
    }
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    NSNumber *status = attachments.firstObject[SCStreamFrameInfoStatus];
    if (![status isKindOfClass:NSNumber.class] || status.integerValue != SCFrameStatusComplete) return;
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    if (!pixel || !CVPixelBufferGetIOSurface(pixel) || CVPixelBufferGetWidth(pixel) != _width ||
        CVPixelBufferGetHeight(pixel) != _height ||
        CVPixelBufferGetPixelFormatType(pixel) != (_fullChroma ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange :
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) ||
        !CMTIME_IS_NUMERIC(pts) || pts.value < 0 ||
        (CMTIME_IS_VALID(_lastPTS) && CMTimeCompare(pts, _lastPTS) <= 0)) {
        fprintf(stderr, "macos_capture_failure stage=video-sample\n"); _failed(); return;
    }
    _lastPTS = pts;
    PLANKFrameTimingRecord *timing = NULL;
    if (_timing) {
        uint64_t captured = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        if (!_timing->origin_ns) {
            _timing->origin_ns = captured;
            _timing->wall_ns = clock_gettime_nsec_np(CLOCK_REALTIME);
        }
        timing = PLANKFrameTimingAppend(_timing, captured);
    }
    if (timing) {
        timing->pts_ns = (uint64_t)CMTimeConvertScale(pts, 1000000000, kCMTimeRoundingMethod_RoundTowardZero).value;
        timing->in_flight = _inFlight;
    }
    ++_completeFrames;
    if (_changingEncoder || _inFlight >= 3) {
        if (timing) timing->stage = 1; // pre-encode skip
        ++_preEncodeDrops; return; // no encoded reference-frame dependency
    }
    // Explicit qualified SDK-27 xf20/xf44 full-range interpretation, distinct from the
    // BT.709 encoded output. Revalidate on final OS; no CPU color conversion.
    CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
    BOOL forceKey = [_video beginKeyFrameRequest];
    NSDictionary *options = forceKey ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;
    uint64_t submitted = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (timing) { timing->submitted_ns = submitted; timing->forced = options != nil; }
    ++_inFlight;
    OSStatus result = VTCompressionSessionEncodeFrameWithOutputHandler(_encoder, pixel, pts, kCMTimeInvalid,
        (__bridge CFDictionaryRef)options, NULL, ^(OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef output) {
        uint64_t completed = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        if (output) CFRetain(output);
        dispatch_async(self->_queue, ^{
            if (timing) {
                timing->completed_ns = completed;
                timing->handled_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            }
            --self->_inFlight;
            self->_maxEncodeNs = MAX(self->_maxEncodeNs, completed - submitted);
            self->_maxCallbackQueueNs = MAX(self->_maxCallbackQueueNs,
                clock_gettime_nsec_np(CLOCK_MONOTONIC) - completed);
            if (!self->_stopping) {
                if (status || !output || (flags & kVTEncodeInfo_FrameDropped)) {
                    if (timing) { timing->stage = 2; timing->result = status; }
                    ++self->_encoderDrops; [self->_video requestKeyFrame];
                }
                else {
                    uint64_t latency = (clock_gettime_nsec_np(CLOCK_MONOTONIC) - submitted) / 100000;
                    int32_t sent = [self->_video sendSample:output processingLatency:(uint16_t)MIN(latency, UINT16_MAX)];
                    if (timing) {
                        timing->sent_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC);
                        timing->number = self->_video.lastFrameNumber;
                        timing->bytes = CMSampleBufferGetTotalSampleSize(output);
                        NSArray *metadata = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(output, false);
                        timing->key = ![metadata.firstObject[(__bridge NSString *)kCMSampleAttachmentKey_NotSync] boolValue];
                        timing->stage = 3; timing->result = sent;
                    }
                    if (sent == PLANK_TRANSPORT_DROPPED) ++self->_sendDrops;
                    if (sent != PLANK_TRANSPORT_OK && sent != PLANK_TRANSPORT_DROPPED) self->_failed();
                }
            }
            else if (timing) timing->stage = 5; // stop suppressed delivery
            if (forceKey) [self->_video completeKeyFrameRequest];
            if (output) CFRelease(output);
            [self replaceEncoderWhenDrained];
            [self finishStop];
        });
    });
    if (result) {
        if (forceKey) [_video completeKeyFrameRequest];
        if (timing) { timing->stage = 4; timing->result = result; }
        --_inFlight; _failed();
    }
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    fprintf(stderr, "macos_capture_failure stage=stream code=%ld\n", (long)error.code);
    dispatch_async(_queue, ^{ if (!self->_stopping) self->_failed(); });
}
- (void)stopWithCompletion:(void (^)(void))completion {
    if (_stopping) return; // owner calls once and fans out its own completions
    _stopping = YES; _failed = nil; _drained = [completion copy];
    _audioRestartPending = NO;
    _replacementCompletion = nil;
    [_audioEncoder stop]; _audioEncoder = nil;
    [self stopDesktopAudio];
    if (!_starting) [self stopCapture];
}
- (void)stopCapture {
    if (!_stream) { _captureStopped = YES; [self finishStop]; return; }
    [_stream stopCaptureWithCompletionHandler:^(NSError *error) {
        (void)error;
        dispatch_async(self->_queue, ^{ self->_captureStopped = YES; [self finishStop]; });
    }];
}
- (void)finishStop {
    if (!_stopping || !_captureStopped || !_audioStopped || _inFlight || _buildingEncoder) return;
    if (_timing) {
        // The launch agent directs stderr to its product log. All callbacks are
        // drained before exporting; no frame can still reference these records.
        PLANKFrameTimingDump(_timing, stderr);
        free(_timing); _timing = NULL;
    }
    if (_drained) NSLog(@"PLANK capture summary: complete=%llu pre-encode-drops=%llu encoder-drops=%llu recovery-or-send-drops=%llu encode-max-ms=%.3f callback-queue-max-ms=%.3f",
        (unsigned long long)_completeFrames, (unsigned long long)_preEncodeDrops,
        (unsigned long long)_encoderDrops, (unsigned long long)_sendDrops,
        _maxEncodeNs / 1e6, _maxCallbackQueueNs / 1e6);
    if (_encoder) { VTCompressionSessionInvalidate(_encoder); CFRelease(_encoder); _encoder = NULL; }
    _stream = nil; _video = nil; _audio = nil;
    void (^completion)(void) = _drained; _drained = nil;
    if (completion) completion();
}
- (void)dealloc { free(_timing); }
@end
