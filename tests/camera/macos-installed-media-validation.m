// SPDX-License-Identifier: GPL-3.0-or-later
#import "../../probes/macos/installed-media-validation.h"
#include <assert.h>
#include <stdio.h>

static CMSampleBufferRef coded(FourCharCode subtype, int width, int height, CMTime pts, size_t bytes) {
    CMVideoFormatDescriptionRef format = NULL; CMBlockBufferRef block = NULL; CMSampleBufferRef sample = NULL;
    assert(!CMVideoFormatDescriptionCreate(NULL, subtype, width, height, NULL, &format));
    assert(!CMBlockBufferCreateWithMemoryBlock(NULL, NULL, bytes, NULL, NULL, 0, bytes, 0, &block));
    CMSampleTimingInfo timing = {CMTimeMake(1,30), pts, kCMTimeInvalid};
    assert(!CMSampleBufferCreateReady(NULL, block, format, 1, 1, &timing, 1, &bytes, &sample));
    CFRelease(block); CFRelease(format); return sample;
}
static CMSampleBufferRef pixels(FourCharCode subtype, CMTime pts) {
    CVPixelBufferRef image = NULL; CMVideoFormatDescriptionRef format = NULL; CMSampleBufferRef sample = NULL;
    assert(!CVPixelBufferCreate(NULL, 1280, 720, subtype, NULL, &image));
    assert(!CMVideoFormatDescriptionCreateForImageBuffer(NULL, image, &format));
    CMSampleTimingInfo timing = {CMTimeMake(1,30), pts, kCMTimeInvalid};
    assert(!CMSampleBufferCreateReadyWithImageBuffer(NULL, image, format, &timing, &sample));
    CFRelease(format); CFRelease(image); return sample;
}
int main(void) {
    float stereo[] = {.5f, .25f, -.5f, -.25f};
    PLANKReadAudioStats audio = PLANKReadAudio(stereo, 2);
    assert(audio.frames == 2 && !audio.invalid && audio.different == 2 && audio.nonzero == 4);
    assert(audio.energy[0] == 500000000 && audio.energy[1] == 125000000);
    float silence[4] = {0}; audio = PLANKReadAudio(silence, 2);
    assert(audio.frames == 2 && !audio.invalid && !audio.nonzero && !audio.different);
    float mono[] = {.2f, .2f}; audio = PLANKReadAudio(mono, 1);
    assert(!audio.invalid && !audio.different && audio.nonzero == 2);
    float corrupt[] = {NAN, INFINITY}; audio = PLANKReadAudio(corrupt, 1);
    assert(audio.invalid == 2 && !audio.energy[0] && !audio.energy[1]);
    float overshoot[] = {1.1f, 10000}; audio = PLANKReadAudio(overshoot, 1);
    assert(!audio.invalid && audio.overRange == 2 && audio.energy[1] == UINT64_C(256000000000));
    assert(PLANKReadAudio(NULL, 2).invalid && PLANKReadAudio(stereo, 0).invalid && PLANKReadAudio(stereo, 48001).invalid);

    PLANKReadVideoStats stats = {0};
    CMSampleBufferRef frame = coded(kCMVideoCodecType_H264, 1280, 720, CMTimeMake(1,30), 12);
    assert(PLANKReadVideo(&stats, frame, false));
    assert(!PLANKReadVideo(&stats, frame, false)); // duplicate presentation time
    assert(!PLANKReadVideo(&stats, frame, true)); // coded frames cannot pass pixel mode
    CFRelease(frame);
    frame = coded(kCMVideoCodecType_H264, 1280, 720, CMTimeMake(2,30), 17);
    assert(PLANKReadVideo(&stats, frame, false)); CFRelease(frame);
    assert(stats.frames == 2 && stats.bytes == 29 && stats.invalid == 2);
    frame = coded(kCMVideoCodecType_H264, 1280, 720, CMTimeMake(0,30), 12);
    assert(!PLANKReadVideo(&stats, frame, false)); CFRelease(frame);
    frame = coded(kCMVideoCodecType_H264, 1920, 1080, CMTimeMake(3,30), 12);
    assert(!PLANKReadVideo(&stats, frame, false)); CFRelease(frame);
    frame = coded(kCMVideoCodecType_JPEG, 1280, 720, CMTimeMake(3,30), 12);
    assert(!PLANKReadVideo(&stats, frame, false));
    PLANKReadVideoStats jpeg = {0}; assert(PLANKReadVideo(&jpeg, frame, false)); CFRelease(frame);
    frame = coded(kCMVideoCodecType_HEVC, 1280, 720, CMTimeMake(3,30), 12);
    assert(!PLANKReadVideo(&stats, frame, false)); CFRelease(frame);
    frame = coded(kCMVideoCodecType_H264, 1280, 720, kCMTimeInvalid, 12);
    assert(!PLANKReadVideo(&stats, frame, false)); CFRelease(frame);
    frame = coded(kCMVideoCodecType_H264, 1280, 720, kCMTimeIndefinite, 12);
    assert(!PLANKReadVideo(&stats, frame, false)); CFRelease(frame);
    frame = coded(kCMVideoCodecType_H264, 1280, 720, CMTimeMake(3,30), 4*1024*1024+1);
    assert(!PLANKReadVideo(&stats, frame, false)); CFRelease(frame);
    frame = coded(kCMVideoCodecType_H264, 3840, 2160, CMTimeMake(3,30), 12);
    PLANKReadVideoStats tooLarge = {0}; assert(!PLANKReadVideo(&tooLarge, frame, false)); CFRelease(frame);
    assert(!PLANKReadVideo(&stats, NULL, false));
    PLANKReadVideoStats raw = {0};
    frame = pixels(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, CMTimeMake(1,30));
    assert(PLANKReadVideo(&raw, frame, true)); assert(!PLANKReadVideo(&raw, frame, false)); CFRelease(frame);
    frame = pixels(kCVPixelFormatType_32BGRA, CMTimeMake(2,30));
    assert(!PLANKReadVideo(&raw, frame, true)); CFRelease(frame);
    puts("installed_media_validation=pass physical_devices_opened=no");
    return 0;
}
