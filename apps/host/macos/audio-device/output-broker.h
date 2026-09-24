// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import "../session/agent-registry.h"
#define PLANK_OUTPUT_SERVICE "la.instinctual.PLANK.Host.output-routing"
enum { PLANKOutputRoutingVersion = 1 };
// Local routing only. No PCM, credentials or remote media protocol changes.
@interface PLANKMacOutputBroker : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
                    authorize:(BOOL (^)(PLANKMacAgentPeer, uint64_t))authorize;
- (BOOL)start;
- (void)stopWithCompletion:(void (^)(void))completion;
@end
