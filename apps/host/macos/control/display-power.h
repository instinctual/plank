// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

// Owned by a bounded display preparation or an authenticated stream. This does
// not synthesize input, change power preferences, or unlock the console. It
// prevents idle display sleep; it does not override explicit sleep or lid close.
static inline IOPMAssertionID PLANKMacPreventIdleDisplaySleep(CFStringRef reason) {
    IOPMAssertionID assertion = kIOPMNullAssertionID;
    IOReturn result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn, reason, &assertion);
    if (result != kIOReturnSuccess) {
        NSLog(@"PLANK display sleep protection failed: %d", result);
        return kIOPMNullAssertionID;
    }
    return assertion;
}

static inline void PLANKMacReleaseDisplayAssertion(IOPMAssertionID *assertion) {
    if (*assertion != kIOPMNullAssertionID) IOPMAssertionRelease(*assertion);
    *assertion = kIOPMNullAssertionID;
}
