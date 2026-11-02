// SPDX-License-Identifier: GPL-3.0-or-later
#import "fixed-capture.h"
#include "../../../../protocol/plank-transport/include/plank_encoding_profiles.h"
#include <math.h>
#include <stdatomic.h>
#include <time.h>

// One process-lifetime observer; no object pointer can outlive its owner and
// no object-specific callback or polling thread is needed. The low bit denotes
// reconfiguration in progress; other bits identify each event.
static atomic_uint_fast64_t displayRevision = 0;
static BOOL displayObservationAvailable;
// Notifications invalidate immediately. A bounded refresh also catches a
// missing notification; reads never extend the lifetime of cached geometry.
static const uint64_t snapshotLifetimeNs = 20 * NSEC_PER_MSEC;
static void displayChanged(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    (void)display; (void)context;
    uint64_t previous = atomic_load(&displayRevision);
    uint64_t next;
    do {
        next = ((previous + 2) & ~UINT64_C(1)) |
            ((flags & kCGDisplayBeginConfigurationFlag) ? 1 : 0);
    } while (!atomic_compare_exchange_weak(&displayRevision, &previous, next));
}

NSDictionary *PLANKMacEncodingProfile(NSString *mode) {
    if (![mode isKindOfClass:NSString.class]) return nil;
    const PlankEncodingProfile *profile = plank_encoding_profile_named(mode.UTF8String);
    if (!profile || profile->encoder != PLANK_ENCODER_APPLE) return nil;
    return @{@"capture_source": @"screencapturekit", @"encoder_backend": @(profile->backend),
        @"encoding_mode": @(profile->mode), @"codec": @(profile->codec), @"profile": @(profile->profile),
        @"bit_depth": @(profile->bit_depth), @"chroma": @(profile->chroma), @"range": @"full",
        @"matrix": @(profile->matrix), @"primaries": @"bt709", @"transfer": @"srgb", @"rgb_identity": @(!!profile->rgb_identity)};
}

NSDictionary *PLANKMacFixedCaptureDescription(NSString *generation, NSString *identifier,
        size_t width, size_t height, CGRect bounds, NSString *encodingMode) {
    NSDictionary *profile = PLANKMacEncodingProfile(encodingMode);
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:generation];
    if (!profile || !uuid || ![uuid.UUIDString.lowercaseString isEqual:generation] ||
        [generation isEqual:@"00000000-0000-0000-0000-000000000000"] ||
        !identifier.length || identifier.length > 128 || width < 2 || height < 2 ||
        width > 8192 || height > 8192 || width % 2 || height % 2 ||
        !isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
        !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
        fabs(bounds.origin.x) > 65536 || fabs(bounds.origin.y) > 65536 ||
        bounds.size.width <= 0 || bounds.size.height <= 0 ||
        bounds.size.width > 65536 || bounds.size.height > 65536) return nil;
    return @{@"schema_version": @13, @"feature_flags": @7897201, @"generation": generation,
        @"capture": @{@"id": identifier, @"width": @(width), @"height": @(height),
            @"logical_bounds": @{@"x": @(bounds.origin.x), @"y": @(bounds.origin.y),
                @"width": @(bounds.size.width), @"height": @(bounds.size.height)},
            @"encoding_profile": profile}};
}

@implementation PLANKMacFixedCapture {
    NSDictionary *_previous;
    NSDictionary *_cached;
    uint64_t _cachedRevision, _cachedAt;
    CGDirectDisplayID _selectedDisplay;
    NSString *_encodingMode;
    NSString *_generation;
    NSString *_unavailableReason;
}
- (NSDictionary *)unavailable:(NSString *)reason {
    if (![_unavailableReason isEqual:reason]) NSLog(@"PLANK capture geometry unavailable: %@", reason);
    _unavailableReason = reason; _previous = nil; _generation = nil; _cached = nil;
    return nil;
}
- (instancetype)init {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        displayObservationAvailable = CGDisplayRegisterReconfigurationCallback(displayChanged, NULL) == kCGErrorSuccess;
    });
    if (!displayObservationAvailable) return nil;
    self = [super init];
    if (self) _encodingMode = @"hevc-10-420-videotoolbox";
    return self;
}
- (CGDirectDisplayID)selectedDisplay { @synchronized(self) { return _selectedDisplay; } }
- (void)setSelectedDisplay:(CGDirectDisplayID)display {
    @synchronized(self) {
        if (_selectedDisplay == display) return;
        _selectedDisplay = display; _cached = nil; _previous = nil; _generation = nil;
    }
}
- (NSString *)encodingMode { @synchronized(self) { return _encodingMode; } }
- (void)setEncodingMode:(NSString *)mode {
    @synchronized(self) {
        if ([_encodingMode isEqual:mode]) return;
        _encodingMode = [mode copy]; _cached = nil; _previous = nil; _generation = nil;
    }
}
- (NSDictionary *)snapshot {
    @synchronized(self) {
        uint64_t revision = atomic_load(&displayRevision);
        if (revision & 1) return [self unavailable:@"display reconfiguration in progress"];
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        if (_cached && revision == _cachedRevision && now >= _cachedAt &&
            now - _cachedAt < snapshotLifetimeNs) {
            // The observer is independent of this lock. Reject a change that
            // arrived while checking the cache, just as after a full read.
            if (revision != atomic_load(&displayRevision))
                return [self unavailable:@"display changed during snapshot"];
            return _cached;
        }
        CGDirectDisplayID selection = _selectedDisplay;
        NSString *encodingMode = _encodingMode;
        if (!PLANKMacEncodingProfile(encodingMode)) return [self unavailable:@"unsupported encoding mode"];
        CGDirectDisplayID display = selection ?: CGMainDisplayID();
        if (!display || !CGDisplayIsActive(display)) return [self unavailable:@"selected display is inactive"];
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
        if (!mode) return [self unavailable:@"display mode unavailable"];
        size_t width = CGDisplayModeGetPixelWidth(mode), height = CGDisplayModeGetPixelHeight(mode);
        int32_t modeID = CGDisplayModeGetIODisplayModeID(mode);
        CGDisplayModeRelease(mode);
        CGRect bounds = CGDisplayBounds(display);
        CGDisplayModeRef check = CGDisplayCopyDisplayMode(display);
        BOOL stable = check && selection == self.selectedDisplay && [encodingMode isEqual:self.encodingMode] &&
            display == (selection ?: CGMainDisplayID()) && CGDisplayIsActive(display) &&
            modeID == CGDisplayModeGetIODisplayModeID(check) &&
            width == CGDisplayModeGetPixelWidth(check) && height == CGDisplayModeGetPixelHeight(check) &&
            CGRectEqualToRect(bounds, CGDisplayBounds(display)) &&
            revision == atomic_load(&displayRevision);
        if (check) CGDisplayModeRelease(check);
        if (!stable) return [self unavailable:@"display changed during snapshot"];
        NSString *identifier = [NSString stringWithFormat:@"cgdisplay:%u", display];
        // Refresh/mode identity is part of the generation even if pixel size
        // is unchanged. No guessed point-to-pixel ratio or monitor provenance.
        NSDictionary *fingerprint = @{@"display": @(display), @"mode": @(modeID), @"revision": @(revision),
            @"width": @(width), @"height": @(height), @"encoding_mode": encodingMode,
            @"bounds": [NSValue valueWithRect:NSRectFromCGRect(bounds)]};
        if (![_previous isEqual:fingerprint]) {
            _generation = NSUUID.UUID.UUIDString.lowercaseString;
            _previous = fingerprint;
        }
        NSDictionary *description = PLANKMacFixedCaptureDescription(_generation, identifier, width, height, bounds, encodingMode);
        if (!description) return [self unavailable:@"unsupported pixel or desktop bounds"];
        _unavailableReason = nil;
        _cached = description; _cachedRevision = revision; _cachedAt = now;
        return description;
    }
}
@end
