// SPDX-License-Identifier: GPL-3.0-or-later
#import "display-layout.h"
#import <ColorSync/ColorSync.h>

static NSArray<NSNumber *> *onlineDisplays(void) {
    CGDirectDisplayID ids[32]; uint32_t count = 0, total = 0;
    if (CGGetOnlineDisplayList(0, NULL, &total) != kCGErrorSuccess || total > 32 ||
        CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess || count != total) return nil;
    NSMutableArray *result = [NSMutableArray new];
    for (uint32_t i = 0; i < count; i++) [result addObject:@(ids[i])];
    return result;
}
static NSString *displayIdentity(CGDirectDisplayID display) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    NSString *value = uuid ? CFBridgingRelease(CFUUIDCreateString(NULL, uuid)) : nil;
    if (uuid) CFRelease(uuid);
    return value;
}

@implementation PLANKMacDisplayLayout {
    NSArray<NSDictionary *> *_saved;
    CGDirectDisplayID _target;
    NSString *_targetIdentity;
}
- (BOOL)pending { return _saved != nil; }
- (BOOL)adoptDisplay:(CGDirectDisplayID)display {
    NSString *identity = displayIdentity(display);
    if (!display || !identity || (_target == display && _targetIdentity && ![_targetIdentity isEqual:identity])) return NO;
    _target = display; _targetIdentity = identity; return YES;
}
- (BOOL)beginExcludingDisplay:(CGDirectDisplayID)display {
    NSAssert(NSThread.isMainThread, @"Display layout belongs to the graphical main queue");
    if (_saved) return NO; // Never replace the original restoration snapshot.
    if (display && ![self adoptDisplay:display]) return NO;
    NSArray *online = onlineDisplays();
    if (!online) return NO;
    NSMutableArray *saved = [NSMutableArray new];
    for (NSNumber *number in online) {
        CGDirectDisplayID identifier = number.unsignedIntValue;
        if (identifier == display) continue;
        NSString *uuid = displayIdentity(identifier);
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(identifier);
        if (!uuid || !mode || CGDisplayIsAlwaysInMirrorSet(identifier)) {
            if (mode) CGDisplayModeRelease(mode); return NO;
        }
        [saved addObject:@{@"id":number, @"uuid":uuid, @"mode":CFBridgingRelease(mode),
            @"bounds":[NSValue valueWithRect:NSRectFromCGRect(CGDisplayBounds(identifier))],
            @"mirror":@(CGDisplayMirrorsDisplay(identifier)), @"main":@(CGMainDisplayID() == identifier)}];
    }
    _saved = saved;
    // The idle PLANK output mirrors the local main screen after a prior lease.
    // Unmirror only our output before selecting its next requested mode.
    if (display && CGDisplayMirrorsDisplay(display)) {
        CGDisplayConfigRef config = NULL;
        if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return NO;
        if (CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay) != kCGErrorSuccess) {
            CGCancelDisplayConfiguration(config); return NO;
        }
        return CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) == kCGErrorSuccess;
    }
    return YES;
}
- (BOOL)activateDisplay:(CGDirectDisplayID)display {
    NSAssert(NSThread.isMainThread, @"Display layout belongs to the graphical main queue");
    if (!_saved || !display || !CGDisplayIsOnline(display)) return NO;
    if (![self adoptDisplay:display]) return NO;
    NSArray *online = onlineDisplays();
    if (!online || online.count != _saved.count + 1) return NO;
    for (NSDictionary *entry in _saved)
        if (![online containsObject:entry[@"id"]] ||
            ![entry[@"uuid"] isEqual:displayIdentity([entry[@"id"] unsignedIntValue])]) return NO;
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return NO;
    BOOL ok = CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay) == kCGErrorSuccess &&
        CGConfigureDisplayOrigin(config, display, 0, 0) == kCGErrorSuccess;
    for (NSDictionary *entry in _saved) {
        CGDirectDisplayID identifier = [entry[@"id"] unsignedIntValue];
        if (ok) ok = CGConfigureDisplayMirrorOfDisplay(config, identifier, display) == kCGErrorSuccess;
    }
    if (!ok) { CGCancelDisplayConfiguration(config); return NO; }
    return CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) == kCGErrorSuccess;
}
- (BOOL)matchesDisplay:(CGDirectDisplayID)display {
    if (!_saved || display != _target || ![_targetIdentity isEqual:displayIdentity(display)] ||
        CGMainDisplayID() != display || CGDisplayMirrorsDisplay(display)) return NO;
    NSArray *online = onlineDisplays();
    if (!online || online.count != _saved.count + 1) return NO;
    for (NSDictionary *entry in _saved) {
        CGDirectDisplayID identifier = [entry[@"id"] unsignedIntValue];
        if (![online containsObject:@(identifier)] || ![entry[@"uuid"] isEqual:displayIdentity(identifier)] ||
            CGDisplayMirrorsDisplay(identifier) != display) return NO;
    }
    return YES;
}
- (BOOL)restore {
    NSAssert(NSThread.isMainThread, @"Display layout belongs to the graphical main queue");
    if (!_saved) return YES;
    NSArray *online = onlineDisplays();
    if (!online) return NO;
    NSMutableArray *present = [NSMutableArray new];
    CGDirectDisplayID primary = 0;
    for (NSDictionary *entry in _saved) {
        CGDirectDisplayID identifier = [entry[@"id"] unsignedIntValue];
        // Never reuse an ID now belonging to another display, or touch hot-added outputs.
        if ([online containsObject:@(identifier)] && [entry[@"uuid"] isEqual:displayIdentity(identifier)]) {
            [present addObject:entry];
            if ([entry[@"main"] boolValue]) primary = identifier;
        }
    }
    if (!primary && present.count) primary = [present[0][@"id"] unsignedIntValue];
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return NO;
    BOOL ok = YES;
    for (NSDictionary *entry in present) {
        CGDirectDisplayID identifier = [entry[@"id"] unsignedIntValue];
        NSRect bounds = [entry[@"bounds"] rectValue];
        if (ok) ok = CGConfigureDisplayMirrorOfDisplay(config, identifier, kCGNullDirectDisplay) == kCGErrorSuccess &&
            CGConfigureDisplayWithDisplayMode(config, identifier, (__bridge CGDisplayModeRef)entry[@"mode"], NULL) == kCGErrorSuccess &&
            CGConfigureDisplayOrigin(config, identifier, (int32_t)bounds.origin.x, (int32_t)bounds.origin.y) == kCGErrorSuccess;
    }
    for (NSDictionary *entry in present) {
        NSNumber *master = entry[@"mirror"];
        if (ok && master.unsignedIntValue && [[present valueForKey:@"id"] containsObject:master])
            ok = CGConfigureDisplayMirrorOfDisplay(config, [entry[@"id"] unsignedIntValue], master.unsignedIntValue) == kCGErrorSuccess;
    }
    // SDK27 keeps CGVirtualDisplay alive until agent exit. Park our idle output
    // as a mirror, so it cannot strand windows on an invisible extended desktop.
    BOOL ownTarget = _target && [online containsObject:@(_target)] &&
        [_targetIdentity isEqual:displayIdentity(_target)];
    if (ok && primary && ownTarget)
        ok = CGConfigureDisplayMirrorOfDisplay(config, _target, primary) == kCGErrorSuccess;
    if (!ok) { CGCancelDisplayConfiguration(config); return NO; }
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) != kCGErrorSuccess) return NO;
    // A successful transaction is not sufficient proof of the applied layout.
    // Retain the snapshot on mismatch so the owner can retry or retire (Quartz
    // then restores app-lifetime changes). Hotplug never invents absent outputs.
    for (NSDictionary *entry in present) {
        CGDirectDisplayID identifier = [entry[@"id"] unsignedIntValue];
        NSNumber *master = entry[@"mirror"];
        CGDirectDisplayID expected = [[present valueForKey:@"id"] containsObject:master] ? master.unsignedIntValue : 0;
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(identifier);
        BOOL matches = mode && CGDisplayModeGetIODisplayModeID(mode) ==
            CGDisplayModeGetIODisplayModeID((__bridge CGDisplayModeRef)entry[@"mode"]) &&
            CGDisplayMirrorsDisplay(identifier) == expected;
        if (mode) CGDisplayModeRelease(mode);
        if (present.count == _saved.count && !expected)
            matches = matches && CGPointEqualToPoint(CGDisplayBounds(identifier).origin,
                NSRectToCGRect([entry[@"bounds"] rectValue]).origin);
        if (!matches) return NO;
    }
    if (primary && ownTarget && CGDisplayMirrorsDisplay(_target) != primary) return NO;
    _saved = nil; return YES;
}
@end
