// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include "account-policy.h"

// Local graphical scope, not remote authorization. Require an explicit role;
// do not infer LoginWindow from a missing desktop. Construct inside the actual
// graphical agent, never SSH/the machine daemon. Never re-arms after revocation.
// The final auth snapshot must also bind this to the machine's live admission
// with PLANKMacAgentConnection.bindGraphicalScope:.
@interface PLANKMacGraphicalAuthority : NSObject
- (instancetype)initWithPhase:(PLANKMacGraphicalPhase)phase;
// Nonblocking local observation, refreshed every500ms off the media/UI queues.
// An observation aged1s, OS failure, or resignation/sleep permanently revokes
// this authority. A late OS reply cannot re-arm it. Machine admission is still
// checked separately at every media/input boundary.
- (PLANKMacGraphicalIdentity)snapshot;
- (void)revoke;
@end
