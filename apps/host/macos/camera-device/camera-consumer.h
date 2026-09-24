// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Extension control on one serial queue. The ready/revoke callback separates
// root admission from shared producer data. Frame callbacks are bounded private
// copies, valid only during the callback; media work must not block this queue.
@interface PLANKMacCameraConsumer : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
                        lease:(void (^)(uint64_t activation))lease
                        frame:(void (^)(const uint8_t *, size_t, uint64_t, uint64_t))frame
                          gap:(void (^)(void))gap;
- (void)start;
- (void)stop;
- (void)requestKeyframe;
- (void)rejectLease;
@property(nonatomic, readonly) BOOL available;
@end
