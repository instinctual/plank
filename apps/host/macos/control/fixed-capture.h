// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Authenticated metadata only. Caller must recheck desktop authority before
// and after snapshot. This neither starts capture nor grants remote input.
// Construction fails if display-change observation cannot be installed.
// Every observed reconfiguration changes generation, including change-back.
// The eventual stream owner must compare this generation and stop on change.
// Stable geometry is cached for at most 20 ms; notifications and property
// changes invalidate immediately. Expiry performs the complete stable double
// read, including detection of unnotified changes. Account authority is never
// cached here and must still be checked at each media/input boundary.
@interface PLANKMacFixedCapture : NSObject
// Zero describes the current main display. Nonzero describes only the selected
// owned display, never silently falling back to a different screen.
@property CGDirectDisplayID selectedDisplay;
@property(copy) NSString *encodingMode;
- (NSDictionary *)snapshot;
@end

// Shared serializer also used by synthetic tests, never a source of authority.
NSDictionary *PLANKMacFixedCaptureDescription(NSString *generation, NSString *identifier,
    size_t width, size_t height, CGRect logicalBounds, NSString *encodingMode);
// Exact YCbCr contracts; unknown modes are rejected, never substituted.
NSDictionary *PLANKMacEncodingProfile(NSString *encodingMode);
