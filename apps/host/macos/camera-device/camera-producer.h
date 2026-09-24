// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Serial owner, one remote activation per object. stop invalidates its lease;
// a replacement receives fresh memory. No image encoding or decoding here.
@interface PLANKMacCameraProducer : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue generation:(uint64_t)generation
                   activation:(uint64_t)activation requirement:(NSString *)requirement
                        valid:(BOOL (^)(void))valid;
- (void)start:(void (^)(BOOL))ready;
- (BOOL)submit:(const uint8_t *)record size:(size_t)size hostTimeNanos:(uint64_t)hostTime;
- (BOOL)takeKeyframeRequest;
- (void)stop;
@property(readonly) BOOL available;
@end
