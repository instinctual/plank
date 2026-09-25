// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
// Explicit graphical setup only. Never starts capture or approves the OS prompt.
void PLANKMacRequestCameraExtension(BOOL enable, void (^completion)(BOOL));
// Signed Host command used by uninstall in the console user's GUI session.
// Values are CLI exit statuses: only Complete permits removal of the Host app.
typedef NS_ENUM(int, PLANKCameraRemovalResult) {
    PLANKCameraRemovalComplete = 0,
    PLANKCameraRemovalFailed = 1,
    PLANKCameraRemovalRestartRequired = 2,
};
void PLANKMacRemoveCameraExtension(void (^completion)(PLANKCameraRemovalResult));
typedef NS_ENUM(int, PLANKCameraStatus) {
    PLANKCameraUnknown, PLANKCameraDisabled, PLANKCameraEnabled,
    PLANKCameraAwaitingApproval, PLANKCameraRemoving,
};
// Read-only, bounded inspection. Does not activate an extension or show UI.
void PLANKMacCheckCameraExtension(void (^completion)(PLANKCameraStatus));
