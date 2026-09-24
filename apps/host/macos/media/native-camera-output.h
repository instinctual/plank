// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

// One fixed format, on a dedicated serial media queue (VT may block).
// Coded output is retained unchanged. Pixel output creates a decoder lazily,
// waits for an independent sample and preserves the sample's mapped Host time.
// The caller bounds queued work, authorizes the session and services key requests.
@interface PLANKMacNativeCameraOutput : NSObject
- (instancetype)initWithFormat:(CMVideoFormatDescriptionRef)format;
@property(nonatomic, readonly) BOOL needsKeyframe;
@property(nonatomic, readonly) BOOL hardwareDecoder;
@property(nonatomic, readonly) uint64_t decodedFrames;
- (void)setPixelOutput:(BOOL)pixels;
- (void)discontinuity;
- (CMSampleBufferRef)copyOutputForSample:(CMSampleBufferRef)sample CF_RETURNS_RETAINED;
@end
