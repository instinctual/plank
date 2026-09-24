// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import "fixed-capture.h"
#include <math.h>

static inline NSArray<NSString *> *PLANKMacMediaNames(void) {
    return @[@"desktop", @"audio", @"input", @"clipboard", @"microphone", @"camera"];
}
static inline BOOL PLANKMacMediaInteger(id value, unsigned minimum, unsigned maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double n = [value doubleValue];
    return isfinite(n) && n >= minimum && n <= maximum && n == floor(n);
}
static inline NSDictionary *PLANKMacMediaProfile(NSString *name, NSString *mode) {
    if ([name isEqual:@"desktop"]) return @{@"schema_version": @1, @"encoding_mode": mode ?: @""};
    if ([name isEqual:@"audio"]) return @{@"schema_version": @1, @"codec": @"opus",
        @"sample_rate": @48000, @"channels": @2, @"packet_duration_ms": @5};
    if ([name isEqual:@"input"]) return @{@"schema_version": @1, @"keyboard": @YES,
        @"mouse": @"absolute", @"pen": @"normalized"};
    if ([name isEqual:@"clipboard"]) return @{@"schema_version": @1};
    if ([name isEqual:@"microphone"]) return @{@"schema_version": @2, @"codec": @"opus",
        @"sample_rate": @48000, @"channels": @2, @"packet_duration_ms": @10};
    if ([name isEqual:@"camera"]) return @{@"schema_version": @1, @"codecs": @[@"h264-annex-b", @"mjpeg"]};
    return nil;
}
static inline unsigned PLANKMacMicrophoneSchema(NSDictionary *request) {
    if ([request[@"schema_version"] isEqual:@7] &&
        [request[@"features"] isKindOfClass:NSDictionary.class] &&
        [request[@"features"][@"microphone"] isKindOfClass:NSDictionary.class] &&
        [request[@"features"][@"microphone"][@"schema_version"] isEqual:@3]) return 3;
    return 2;
}
static inline NSDictionary *PLANKMacMediaSelectedProfile(NSString *name, NSString *mode, id choice) {
    if ([name isEqual:@"microphone"] && [choice isKindOfClass:NSDictionary.class] &&
        [choice[@"schema_version"] isEqual:@3])
        return @{@"schema_version":@3, @"codec":@"opus", @"sample_rate":@48000,
            @"channels":@2, @"packet_duration_ms":@10, @"capture_clock":@"monotonic-ns"};
    return PLANKMacMediaProfile(name, mode);
}
static inline BOOL PLANKMacMediaContainsProfile(id value, NSDictionary *expected) {
    if (![value isKindOfClass:NSDictionary.class] || [value count] > 32 || !expected.count) return NO;
    for (NSString *key in expected) {
        id actual = value[key], wanted = expected[key];
        if ([wanted isKindOfClass:NSNumber.class] &&
            (![actual isKindOfClass:NSNumber.class] ||
             (CFGetTypeID((__bridge CFTypeRef)actual) == CFBooleanGetTypeID()) !=
             (CFGetTypeID((__bridge CFTypeRef)wanted) == CFBooleanGetTypeID()))) return NO;
        if (![actual isEqual:wanted]) return NO;
    }
    return YES;
}
static inline BOOL PLANKMacMediaRequired(id value) {
    if (![value isKindOfClass:NSArray.class] || [value count] > 16) return NO;
    NSMutableSet *seen = [NSMutableSet set];
    for (id name in value) {
        if (![name isKindOfClass:NSString.class] || ![PLANKMacMediaNames() containsObject:name] || [seen containsObject:name]) return NO;
        [seen addObject:name];
    }
    return [seen containsObject:@"desktop"] && [seen containsObject:@"audio"] && [seen containsObject:@"input"];
}

// Read-only negotiation. It neither claims the authenticated setup token nor
// opens media/devices. Unknown optional features/fields are bounded and ignored.
static inline NSDictionary *PLANKMacNegotiateMedia(NSDictionary *request, unsigned *status) {
    *status = 400;
    if (![request isKindOfClass:NSDictionary.class] || request.count > 16 ||
        !PLANKMacMediaInteger(request[@"schema_version"], 1, 65535) ||
        ![request[@"transport"] isKindOfClass:NSString.class] ||
        ![request[@"features"] isKindOfClass:NSDictionary.class] || [request[@"features"] count] > 32) return nil;
    *status = 426;
    if (![request[@"schema_version"] isEqual:@1] || ![request[@"transport"] isEqual:@"plank-native/2"] ||
        !PLANKMacMediaRequired(request[@"required_features"])) return nil;
    NSDictionary *offers = request[@"features"];
    NSMutableDictionary *selected = [NSMutableDictionary dictionary];
    NSString *mode = nil;
    for (NSString *name in PLANKMacMediaNames()) {
        id choices = offers[name];
        if (!choices) choices = @[];
        if (![choices isKindOfClass:NSArray.class] || [choices count] > 8) { *status = 400; return nil; }
        NSDictionary *chosen = nil;
        for (id choice in choices) {
            if (![choice isKindOfClass:NSDictionary.class] || [choice count] > 32 ||
                !PLANKMacMediaInteger(choice[@"schema_version"], 1, 65535)) { *status = 400; return nil; }
            NSString *candidateMode = [name isEqual:@"desktop"] ? choice[@"encoding_mode"] : mode;
            if ([name isEqual:@"desktop"] && !PLANKMacEncodingProfile(candidateMode)) continue;
            NSDictionary *profile = PLANKMacMediaSelectedProfile(name, candidateMode, choice);
            if (!chosen && PLANKMacMediaContainsProfile(choice, profile)) {
                chosen = profile;
                if ([name isEqual:@"desktop"]) mode = candidateMode;
            }
        }
        if (!chosen && [request[@"required_features"] containsObject:name]) return nil;
        selected[name] = chosen ?: NSNull.null;
    }
    *status = 200;
    return @{@"schema_version": @1, @"launch_schema": @7, @"transport": @"plank-native/2",
        @"required_features": request[@"required_features"], @"features": selected};
}

// All supported external formats become one internal request. Schema4's mono
// microphone is deliberately disabled; no version1 audio decoder is restored.
static inline NSDictionary *PLANKMacNormalizeMediaLaunch(NSDictionary *request) {
    if (![request isKindOfClass:NSDictionary.class] || !PLANKMacMediaInteger(request[@"schema_version"], 4, 7)) return nil;
    unsigned schema = [request[@"schema_version"] unsignedIntValue];
    if (schema <= 6) {
        if (request.count != (schema == 6 ? 12u : 11u)) return nil;
        for (NSString *name in @[@"clipboard", @"microphone", @"camera"]) {
            if ([name isEqual:@"camera"] && schema < 6) continue;
            id value = request[name];
            if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return nil;
        }
        NSMutableDictionary *normalized = [request mutableCopy];
        normalized[@"schema_version"] = @6;
        if (schema == 4) normalized[@"microphone"] = @NO;
        if (schema < 6) normalized[@"camera"] = @NO;
        return normalized;
    }
    if (request.count > 16 || ![request[@"transport"] isEqual:@"plank-native/2"] ||
        !PLANKMacMediaRequired(request[@"required_features"]) ||
        ![request[@"features"] isKindOfClass:NSDictionary.class] || [request[@"features"] count] > 32) return nil;
    NSDictionary *features = request[@"features"], *desktop = features[@"desktop"];
    if (![desktop isKindOfClass:NSDictionary.class] || !PLANKMacEncodingProfile(desktop[@"encoding_mode"])) return nil;
    for (NSString *name in PLANKMacMediaNames()) {
        id value = features[name];
        if ((!value || value == NSNull.null) && ![request[@"required_features"] containsObject:name]) continue;
        if (!PLANKMacMediaContainsProfile(value, PLANKMacMediaSelectedProfile(name, desktop[@"encoding_mode"], value))) return nil;
    }
    NSMutableDictionary *normalized = [NSMutableDictionary dictionaryWithDictionary:@{
        @"schema_version": @6,
        @"clipboard": @([features[@"clipboard"] isKindOfClass:NSDictionary.class]),
        @"microphone": @([features[@"microphone"] isKindOfClass:NSDictionary.class]),
        @"camera": @([features[@"camera"] isKindOfClass:NSDictionary.class])}];
    for (NSString *key in @[@"capture_generation", @"capture_id", @"max_udp_payload_size"])
        if (request[key]) normalized[key] = request[key];
    for (NSString *key in @[@"width", @"height", @"encoding_mode", @"frame_rate", @"bitrate_kbps"])
        if (desktop[key]) normalized[key] = desktop[key];
    return normalized.count == 12 ? normalized : nil;
}

static inline NSDictionary *PLANKMacMediaReplyFeatures(NSDictionary *request, BOOL clipboard, BOOL microphone, BOOL camera) {
    NSDictionary *normalized = PLANKMacNormalizeMediaLaunch(request);
    if (!normalized) return nil;
    NSMutableDictionary *features = [NSMutableDictionary dictionary];
    for (NSString *name in PLANKMacMediaNames()) {
        BOOL enabled = !([name isEqual:@"clipboard"] && !clipboard) &&
            !([name isEqual:@"microphone"] && !microphone) && !([name isEqual:@"camera"] && !camera);
        id selected = [request[@"schema_version"] isEqual:@7] ? request[@"features"][name] : nil;
        features[name] = enabled ? PLANKMacMediaSelectedProfile(name, normalized[@"encoding_mode"], selected) : (id)NSNull.null;
    }
    NSMutableDictionary *desktop = [features[@"desktop"] mutableCopy];
    for (NSString *key in @[@"width", @"height", @"frame_rate", @"bitrate_kbps"]) desktop[key] = normalized[key];
    features[@"desktop"] = desktop;
    return features;
}
