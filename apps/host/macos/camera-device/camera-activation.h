// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
// Explicit graphical setup only. Never starts capture or approves the OS prompt.
void PLANKMacRequestCameraExtension(BOOL enable, void (^completion)(BOOL));
// Called after desktop permissions are ready. Inspect the installed extension,
// reconcile an already-enabled version, then show its actual setup status.
void PLANKMacShowCameraSetup(void (^completion)(void));
