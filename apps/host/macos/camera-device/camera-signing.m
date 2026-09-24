// SPDX-License-Identifier: GPL-3.0-or-later
#import "camera-signing.h"
#import <Security/Security.h>
NSString *PLANKCameraPeerRequirement(NSString *identifier) {
    if (![identifier isEqualToString:@"la.instinctual.PLANK.Host"] &&
        ![identifier isEqualToString:@"la.instinctual.PLANK.Host.Camera"]) return nil;
    SecCodeRef code = NULL; CFDictionaryRef information = NULL;
    OSStatus status = SecCodeCopySelf(kSecCSDefaultFlags, &code);
    if (!status) status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
    if (code) CFRelease(code);
    NSDictionary *values = CFBridgingRelease(information);
    NSString *team = values[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    if (status || ![team isKindOfClass:NSString.class] || team.length != 10 ||
        [team rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet]].location != NSNotFound) return nil;
    return [NSString stringWithFormat:@"anchor apple generic and identifier \"%@\" and "
        "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"%@\"",
        identifier, team];
}
