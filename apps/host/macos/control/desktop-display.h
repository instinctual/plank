// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// One fixed-identity virtual display per graphical-agent lifetime. No root
// helper or public socket. Opt-in display mirroring leases temporarily mirror
// physical displays using app-lifetime Quartz configuration. Agent process exit
// normally removes it; WindowServer can defer that cleanup until display wake.
// Authenticated preparation wakes first and bounds retries of the same identity.
@interface PLANKMacDesktopDisplay : NSObject
// Distinct display identity, with the same selectable modes as the desktop.
- (instancetype)initForSignIn;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic) BOOL mirrorHostDisplays;
- (BOOL)restoreLayout;
- (void)prepareWidth:(unsigned)width height:(unsigned)height
              valid:(BOOL (^)(void))valid completion:(void (^)(BOOL))completion;
- (void)prepareWidth:(unsigned)width height:(unsigned)height scale:(unsigned)scale
              valid:(BOOL (^)(void))valid completion:(void (^)(BOOL))completion;
// Authenticated recovery only. Before first preparation, wake the current
// desktop without changing its mode. Otherwise reuse our display and last
// successful mode; never create another output or change a physical mode.
- (void)recoverWithValidity:(BOOL (^)(void))valid completion:(void (^)(BOOL))completion;
@end
BOOL PLANKMacDesktopModeSupported(unsigned width, unsigned height);
