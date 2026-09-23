// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Owned by one authenticated stream activation. All methods use the supplied
// serial audio queue. No capture permissions, physical input or default-device
// changes live here. Samples are already decoded mono 48 kHz float PCM.
@interface PLANKMacMicrophoneProducer : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue generation:(uint64_t)generation
                  requirement:(NSString *)requirement automaticInput:(BOOL)automaticInput
                        valid:(BOOL (^)(void))valid;
- (void)start:(void (^)(BOOL))ready;
- (BOOL)submit:(const float *)samples count:(uint32_t)count sampleTime:(uint64_t)sampleTime;
- (void)stop;
// Clear every queued/shared sample while retaining the session's selected
// silent input. Caller serializes this with submission on the owner queue.
- (void)silence;
@property(readonly) BOOL available;
@end
