// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

// Called only after the native graphical authority admits this non-root user.
// No permission requests, shell, privileged home writes or shared private keys.
BOOL PLANKMacPrepareDesktop(NSString **directory, NSDictionary **configuration);

// Filesystem components also exercised by uninstalled, non-root unit tests.
BOOL PLANKMacPrepareDesktopIdentity(NSString *directory);
