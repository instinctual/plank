// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
// Explicit graphical setup only. Never starts capture or approves the OS prompt.
void PLANKMacRequestCameraExtension(BOOL enable, void (^completion)(BOOL));
