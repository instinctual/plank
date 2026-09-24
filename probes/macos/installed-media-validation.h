// SPDX-License-Identifier: GPL-3.0-or-later
// Structural application-delivery checks, not source identity or lip-sync proof.
#pragma once
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <math.h>
#include <stdint.h>

typedef struct {
    uint64_t frames, invalid, nonzero, different, overRange;
    uint64_t energy[2]; // Sum of squared samples, scaled by 1e9.
} PLANKReadAudioStats;

static inline PLANKReadAudioStats PLANKReadAudio(const float *samples, size_t frames) {
    PLANKReadAudioStats stats = {0};
    if (!samples || !frames || frames > 48000) { stats.invalid = 1; return stats; }
    stats.frames = frames;
    for (size_t frame = 0; frame < frames; frame++) {
        stats.different += samples[2*frame] != samples[2*frame+1];
        for (unsigned channel = 0; channel < 2; channel++) {
            double value = samples[2*frame+channel];
            if (!isfinite(value)) { stats.invalid++; continue; }
            stats.nonzero += fabs(value) > .0001;
            stats.overRange += fabs(value) > 1;
            // Bound diagnostics even for corrupt samples. Opus float output can
            // exceed full scale; report that separately from nonfinite data.
            value = fmin(fabs(value), 16);
            stats.energy[channel] += (uint64_t)(value*value*1e9);
        }
    }
    return stats;
}

typedef struct {
    uint64_t frames, invalid, bytes;
    int32_t width, height;
    FourCharCode subtype;
    CMTime firstPTS, lastPTS;
} PLANKReadVideoStats;

static inline bool PLANKReadVideo(PLANKReadVideoStats *stats, CMSampleBufferRef sample, bool pixels) {
    CMFormatDescriptionRef format = sample ? CMSampleBufferGetFormatDescription(sample) : NULL;
    if (!sample || !format || !CMSampleBufferDataIsReady(sample) ||
        CMSampleBufferGetNumSamples(sample) != 1 ||
        CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video) {
        stats->invalid++; return false;
    }
    FourCharCode subtype = CMFormatDescriptionGetMediaSubType(format);
    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format);
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    bool valid = size.width > 0 && size.width <= 1920 && size.height > 0 && size.height <= 1080 &&
        CMTIME_IS_NUMERIC(pts) && (!stats->frames || CMTimeCompare(pts, stats->lastPTS) > 0) &&
        (!stats->frames || (size.width == stats->width && size.height == stats->height && subtype == stats->subtype));
    size_t bytes = 0;
    CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    if (pixels) {
        valid = valid && image && !block && subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            CVPixelBufferGetPixelFormatType(image) == subtype && CVPixelBufferGetPlaneCount(image) == 2 &&
            CVPixelBufferGetWidth(image) == (size_t)size.width && CVPixelBufferGetHeight(image) == (size_t)size.height;
    } else {
        bytes = block ? CMBlockBufferGetDataLength(block) : 0;
        valid = valid && !image && (subtype == kCMVideoCodecType_H264 || subtype == kCMVideoCodecType_JPEG) &&
            bytes > 0 && bytes <= 4*1024*1024;
    }
    if (!valid) { stats->invalid++; return false; }
    if (!stats->frames) stats->firstPTS = pts;
    stats->lastPTS = pts; stats->width = size.width; stats->height = size.height;
    stats->subtype = subtype; stats->bytes += bytes; stats->frames++;
    return true;
}
