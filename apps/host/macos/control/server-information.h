// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Public, immutable discovery metadata. No account, desktop geometry, token,
// or hardware serial number belongs in this object. Occupancy is a nameless
// bit only: LoginWindow is free, the Aqua desktop agent is occupied.
// The installer/service must supply its persisted workstation UUID; do not
// derive it from an account or regenerate it for every graphical agent.
@interface PLANKMacServerInformation : NSObject
- (instancetype)initWithName:(NSString *)name workstationUUID:(NSUUID *)uuid
                    version:(NSString *)version;
- (instancetype)initWithName:(NSString *)name workstationUUID:(NSUUID *)uuid
                    version:(NSString *)version streaming:(BOOL)streaming;
- (instancetype)initWithName:(NSString *)name workstationUUID:(NSUUID *)uuid
                    version:(NSString *)version streaming:(BOOL)streaming
                   occupied:(BOOL)occupied;
- (NSData *)XMLForControlPort:(uint16_t)port;
// Reflect only this request's validated bearer, never another client's state.
- (NSData *)XMLForControlPort:(uint16_t)port authorized:(BOOL)authorized;
@end

// These GET endpoints accept exact paths, without legacy client metadata or
// query parameters. Authentication is carried only in the Authorization header.
BOOL PLANKMacIsServerInformationTarget(NSString *target);
BOOL PLANKMacIsTopologyTarget(NSString *target);
BOOL PLANKMacIsDesktopTarget(NSString *target);
