// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include "plank_transport_camera.h"

// Serial owner of one camera activation. Validates metadata/coded dimensions
// and creates samples without an encoder. Caller supplies an already mapped
// monotonic Host timestamp; this class does not establish audio/video sync.
@interface PLANKMacNativeCameraSample : NSObject
- (instancetype)initWithGeneration:(uint64_t)generation;
@property(nonatomic, readonly) BOOL needsKeyframe;
- (CMSampleBufferRef)copySampleFromRecord:(const uint8_t *)record size:(size_t)size
                           hostTimeNanos:(uint64_t)hostTime CF_RETURNS_RETAINED;
@end
