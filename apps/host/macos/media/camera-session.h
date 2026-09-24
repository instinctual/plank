// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include "plank_transport.h"
#include "plank_transport_control.h"

// Optional reverse camera on the authenticated session queue. Must be stopped
// before endpoint destruction. No camera decoding or physical capture here.
@interface PLANKMacCameraSession : NSObject
+ (BOOL)available;
- (instancetype)initWithQueue:(dispatch_queue_t)queue endpoint:(PlankTransportNativeEndpoint *)endpoint
                   generation:(uint64_t)generation valid:(BOOL (^)(void))valid;
- (BOOL)receive:(const PlankTransportControlPacket *)packet;
- (void)tick;
- (void)stop;
@end
