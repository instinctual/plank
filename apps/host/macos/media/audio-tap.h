// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

// One-shot desktop audio capture. Public methods and delivered callbacks use
// the supplied serial owner queue. HAL lifecycle work is off that queue.
// Capture only audio routed to PLANK Output, without muting any local device.
// Audio includes this non-root user's processes (excluding the Host), plus
// Apple's verified system-alert service only while this user owns the console.
// stop drops buffered audio. Active IO is destroyed before completion. A pending
// consent request is cancelled logically: IO can never start, session references
// are detached immediately, and unstarted HAL objects are cleaned up on return.
@interface PLANKMacAudioTap : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                        sample:(BOOL (^)(CMSampleBufferRef sample))sample
                        failed:(void (^)(void))failed;
- (void)startWithCompletion:(void (^)(BOOL ready))completion;
- (void)stopWithCompletion:(void (^)(void))completion;
@end
