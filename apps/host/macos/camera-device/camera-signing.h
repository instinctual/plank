// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Developer ID code with the caller's signed Team ID and one exact identifier.
// Nil for unsigned/ad-hoc code; never weaken to an identifier-only check.
NSString *PLANKCameraPeerRequirement(NSString *identifier);
