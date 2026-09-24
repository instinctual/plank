// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include "output-format.h"

// One instance, one serial HAL queue in the root coordinator. Persist before
// changing either default, so coordinator restart can recover an orphaned route.
@interface PLANKMacOutputSelection : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
- (BOOL)recover;
- (BOOL)select;
- (BOOL)restore;
@end
