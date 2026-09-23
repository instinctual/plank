// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import "../session/agent-registry.h"

// Lives inside the existing root coordinator. No network or PCM processing.
// All calls/authorizer callbacks belong to the supplied serial queue.
@interface PLANKMacMicrophoneBroker : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
                    authorize:(BOOL (^)(PLANKMacAgentPeer, uint64_t))authorize;
- (BOOL)start;
- (void)stop;
@end
