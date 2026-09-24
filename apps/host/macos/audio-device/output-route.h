// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
@interface PLANKMacOutputRoute : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue generation:(uint64_t)generation
                  requirement:(NSString *)requirement valid:(BOOL (^)(void))valid;
- (void)start;
- (void)stopWithCompletion:(void (^)(void))completion;
@end
