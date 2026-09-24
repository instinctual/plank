// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import "preview-session.h"

// Dedicated macOS 27 capture backend. No display creation or remote input.
// Includes system audio, never microphone capture. Desktop system-audio consent
// is required for the tap; the OS may request it on first use.
@class PLANKMacOutputRoute;
@interface PLANKMacScreenCapture : NSObject <PLANKMacPreviewCapture>
@property(copy) PLANKMacOutputRoute *(^outputRoute)(dispatch_queue_t);
- (instancetype)initWithDesktopAudioTap:(BOOL)desktopAudioTap;
@end
