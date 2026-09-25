// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Interactive Host setup only. Starting a private, empty audio tap exercises
// the public Core Audio consent path. No audio is retained/forwarded, no process
// is muted, and no physical device is selected or output routing changed. Success means
// the request path started, not proof that the user granted recording consent.
@interface PLANKMacAudioConsent : NSObject
- (void)startWithCompletion:(void (^)(BOOL started))completion;
- (void)stopWithCompletion:(void (^)(void))completion;
@end
