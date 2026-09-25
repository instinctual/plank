// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

NSDictionary *PLANKMacParseHostConfiguration(NSData *data);
NSString *PLANKMacReadWorkstationUUID(NSData *data);
NSDictionary *PLANKMacReadHostConfiguration(NSString *configDirectory, NSString *stateDirectory,
                                           uid_t owner, BOOL privateFixture);
