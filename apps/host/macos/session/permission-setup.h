// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
// Interactive setup app only. Background media/authentication workers never
// construct this window or request permissions.
void PLANKMacShowPermissionSetup(NSString *version);
