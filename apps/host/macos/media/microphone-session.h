// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include "plank_transport.h"
#include "plank_transport_control.h"

// Serial session-queue component. The caller owns the endpoint and must stop
// this owner before destroying it. No physical Host microphone is ever opened.
@interface PLANKMacMicrophoneSession : NSObject
+ (BOOL)available;
- (instancetype)initWithQueue:(dispatch_queue_t)queue endpoint:(PlankTransportNativeEndpoint *)endpoint
                   generation:(uint64_t)generation valid:(BOOL (^)(void))valid;
- (BOOL)receive:(const PlankTransportControlPacket *)packet;
- (void)tick;
- (void)stop;
@end
