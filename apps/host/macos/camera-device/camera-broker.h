// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import "../session/agent-registry.h"

// Root coordinator: admission and fresh lease mappings only; never parses media.
// Extension and worker are verified by XPC code requirements. A producer must
// also match the current desktop registry's kernel UID/PID/audit session.
@interface PLANKMacCameraBroker : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue requirement:(NSString *)requirement
         extensionRequirement:(NSString *)extensionRequirement
                    authorize:(BOOL (^)(PLANKMacAgentPeer, uint64_t))authorize;
- (BOOL)start;
- (void)stop;
@end
