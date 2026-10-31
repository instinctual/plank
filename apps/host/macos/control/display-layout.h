// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Graphical-main-queue owner of an opt-in, app-lifetime mirror configuration.
// Never uses permanent/session configuration, private display-disable APIs or AX.
@interface PLANKMacDisplayLayout : NSObject
- (BOOL)beginExcludingDisplay:(CGDirectDisplayID)display;
- (BOOL)adoptDisplay:(CGDirectDisplayID)display;
- (BOOL)activateDisplay:(CGDirectDisplayID)display;
- (BOOL)matchesDisplay:(CGDirectDisplayID)display;
- (BOOL)restore;
@property(nonatomic, readonly) BOOL pending;
@end
