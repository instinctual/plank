// SPDX-License-Identifier: GPL-3.0-or-later
// Constructs/inspects Quartz events only. Never posts or records OS input.
#import "input-events.h"
#import "quartz-input.h"
#import <AppKit/AppKit.h>
#include "plank_transport_input.h"
#include <math.h>
#include <unistd.h>

static unsigned checks;
static uint64_t now = 1000000000;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #x); exit(1); } ++checks; } while (0)
static NSData *packet(const uint8_t *p, size_t n) { return [NSData dataWithBytes:p length:n]; }
static int64_t sequence(CGEventRef event) {
    int64_t number = CGEventGetIntegerValueField(event, kCGMouseEventNumber);
    CHECK(number > 0);
    CHECK([NSEvent eventWithCGEvent:event].eventNumber == number);
    return number;
}
static CGEventRef sendInput(PLANKMacInputEvents *mapper, uint8_t type, NSData *data, PLANKMacInputResult expected) {
    __block CGEventRef event = NULL;
    CHECK([mapper consumeType:type payload:data time:now++ accept:^BOOL(CGEventRef value) {
        event = (CGEventRef)CFRetain(value); return YES;
    }] == expected);
    CHECK((event != NULL) == (expected == PLANKMacInputEvent));
    return event;
}
static NSData *motion(unsigned x, unsigned y, unsigned mx, unsigned my) {
    uint8_t data[8]; plank_transport_input_encode_absolute_mouse(data, x, y, mx, my);
    return packet(data, sizeof(data));
}
static NSData *key(unsigned code, BOOL down, unsigned mods, unsigned flags) {
    uint8_t data[5] = {0, 0, down, mods, flags}; plank_transport_input_write_u16(data, code);
    return packet(data, sizeof(data));
}
static PLANKMacInputEvents *make(CGEventSourceRef source, CGRect bounds, CGSize pixels) {
    PLANKMacInputEvents *mapper = [[PLANKMacInputEvents alloc] initWithSource:source
        bounds:bounds pixels:pixels initialPosition:bounds.origin doubleClickInterval:0.5];
    CHECK(mapper != nil); return mapper;
}
int main(void) {
    alarm(30);
    @autoreleasepool {
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
        CHECK(source != NULL);
        CGEventSourceSetPixelsPerLine(source, 10);
        // Independent expected endpoints, including negative origin and Retina.
        CGRect rectangles[] = {CGRectMake(0, 0, 1920, 1080), CGRectMake(0, 0, 1920, 1080),
            CGRectMake(-2560, -100, 2560, 2160), CGRectMake(40, 90, 1280, 720)};
        CGSize pixels[] = {CGSizeMake(1920, 1080), CGSizeMake(3840, 2160),
            CGSizeMake(2560, 2160), CGSizeMake(5120, 2880)};
        CGPoint ends[] = {CGPointMake(1919, 1079), CGPointMake(1919.5, 1079.5),
            CGPointMake(-1, 2059), CGPointMake(1319.75, 809.75)};
        for (unsigned g = 0; g < 4; ++g) {
            PLANKMacInputEvents *mapper = make(source, rectangles[g], pixels[g]);
            for (unsigned scale = 1; scale < 4; ++scale) for (unsigned step = 0; step <= 10; ++step) {
                CGEventRef event = sendInput(mapper, 1, motion(step * scale, step * scale, 10 * scale, 10 * scale), PLANKMacInputEvent);
                CGPoint actual = CGEventGetLocation(event);
                CHECK(fabs(actual.x - (rectangles[g].origin.x + step / 10.0 * (ends[g].x - rectangles[g].origin.x))) < 1e-7);
                CHECK(fabs(actual.y - (rectangles[g].origin.y + step / 10.0 * (ends[g].y - rectangles[g].origin.y))) < 1e-7);
                CHECK(CGEventGetType(event) == kCGEventMouseMoved);
                CHECK(CGEventGetTimestamp(event) == now - 1); CFRelease(event);
            }
            CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        }
        PLANKMacInputEvents *mapper = make(source, rectangles[0], pixels[0]);
        sendInput(mapper, 1, motion(0, 0, 0, 10), PLANKMacInputMalformed);
        sendInput(mapper, 1, motion(11, 0, 10, 10), PLANKMacInputMalformed);
        sendInput(mapper, 1, motion(0, 11, 10, 10), PLANKMacInputMalformed);
        CGEventRef event = NULL;
        CHECK([mapper consumeType:1 payload:motion(0, 0, 10, 10) time:now accept:nil] == PLANKMacInputMalformed);
        for (unsigned type = 1; type <= 5; ++type) for (unsigned length = 0; length <= 10; ++length) {
            unsigned size = type == 1 ? 8 : type == 5 ? 5 : 2;
            if (length == size) continue;
            sendInput(mapper, type, [NSMutableData dataWithLength:length], PLANKMacInputMalformed);
        }
        for (unsigned type = 6; type <= 255; ++type)
            sendInput(mapper, type, packet((uint8_t[]){1}, 1), type == 7 ? PLANKMacInputMalformed : PLANKMacInputUnsupported);
        sendInput(mapper, 5, key(0x141, YES, 0, 0), PLANKMacInputMalformed);
        sendInput(mapper, 5, key(0x8041, YES, 16, 0), PLANKMacInputMalformed);
        sendInput(mapper, 5, key(0x8041, YES, 0, 2), PLANKMacInputMalformed);
        sendInput(mapper, 5, key(0x8041, YES, 0, 1), PLANKMacInputUnsupported);
        sendInput(mapper, 5, key(0x8000, YES, 0, 0), PLANKMacInputUnsupported);
        sendInput(mapper, 2, packet((uint8_t[]){0, 1}, 2), PLANKMacInputMalformed);
        sendInput(mapper, 2, packet((uint8_t[]){6, 1}, 2), PLANKMacInputMalformed);
        sendInput(mapper, 2, packet((uint8_t[]){1, 2}, 2), PLANKMacInputMalformed);
        // All five button identities, drag, paired up, duplicate suppression.
        unsigned buttons[] = {0, 2, 1, 3, 4};
        CGEventType drag[] = {kCGEventLeftMouseDragged, kCGEventOtherMouseDragged,
            kCGEventRightMouseDragged, kCGEventOtherMouseDragged, kCGEventOtherMouseDragged};
        int64_t previousNumber = 0;
        for (unsigned i = 0; i < 5; ++i) {
            event = sendInput(mapper, 2, packet((uint8_t[]){i + 1, 1}, 2), PLANKMacInputEvent);
            int64_t number = sequence(event);
            CHECK(number != previousNumber); previousNumber = number;
            CHECK(CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) == buttons[i]);
            CHECK(CGEventGetIntegerValueField(event, kCGMouseEventClickState) == 1); CFRelease(event);
            sendInput(mapper, 2, packet((uint8_t[]){i + 1, 1}, 2), PLANKMacInputNoEvent);
            event = sendInput(mapper, 1, motion(5, 5, 10, 10), PLANKMacInputEvent);
            CHECK(sequence(event) == number);
            CHECK(CGEventGetIntegerValueField(event, kCGMouseEventClickState) == 1);
            CHECK(CGEventGetType(event) == drag[i]); CFRelease(event);
            event = sendInput(mapper, 2, packet((uint8_t[]){i + 1, 0}, 2), PLANKMacInputEvent);
            CHECK(sequence(event) == number); CFRelease(event);
            sendInput(mapper, 2, packet((uint8_t[]){i + 1, 0}, 2), PLANKMacInputNoEvent);
        }
        for (unsigned i = 1; i <= 3; ++i) {
            now += 100000000;
            event = sendInput(mapper, 2, packet((uint8_t[]){1, 1}, 2), PLANKMacInputEvent);
            int64_t number = sequence(event);
            CHECK(number != previousNumber); previousNumber = number;
            CHECK(CGEventGetIntegerValueField(event, kCGMouseEventClickState) == i); CFRelease(event);
            event = sendInput(mapper, 1, motion(5, 5, 10, 10), PLANKMacInputEvent);
            CHECK(sequence(event) == number);
            CHECK(CGEventGetIntegerValueField(event, kCGMouseEventClickState) == i); CFRelease(event);
            event = sendInput(mapper, 2, packet((uint8_t[]){1, 0}, 2), PLANKMacInputEvent);
            CHECK(sequence(event) == number); CFRelease(event);
        }
        now += 1000000000;
        event = sendInput(mapper, 2, packet((uint8_t[]){1, 1}, 2), PLANKMacInputEvent);
        CHECK(CGEventGetIntegerValueField(event, kCGMouseEventClickState) == 1); CFRelease(event);
        event = sendInput(mapper, 2, packet((uint8_t[]){1, 0}, 2), PLANKMacInputEvent); CFRelease(event);
        // Fractions must survive both directions/axes. Never truncate 1/120.
        int amounts[] = {1, 60, 120, -1, -60, -120, 32767, -32768};
        for (unsigned axis = 0; axis < 2; ++axis) for (unsigned a = 0; a < 8; ++a) {
            uint8_t p[2]; plank_transport_input_write_u16(p, (uint16_t)amounts[a]);
            event = sendInput(mapper, axis ? 4 : 3, packet(p, 2), PLANKMacInputEvent);
            CHECK(CGEventGetType(event) == kCGEventScrollWheel);
            CHECK(fabs(CGEventGetDoubleValueField(event, axis ? kCGScrollWheelEventFixedPtDeltaAxis2 : kCGScrollWheelEventFixedPtDeltaAxis1) - amounts[a] / 120.0) < 1.0 / 65536);
            CHECK(CGEventGetIntegerValueField(event, axis ? kCGScrollWheelEventPointDeltaAxis2 : kCGScrollWheelEventPointDeltaAxis1) == llround(amounts[a] / 12.0));
            CFRelease(event);
        }
        sendInput(mapper, 3, packet((uint8_t[]){0, 0}, 2), PLANKMacInputNoEvent);
        // Exact measured OS slider positions, odd persisted values, and safe
        // fallbacks. Never read or modify the test account's OS preferences.
        double positions[] = {0, 0.0735, 0.1265, 0.1838, 0.3125, 0.4412, 0.5882, 1};
        CHECK(PLANKMacScrollLinesForPreference(NULL) == 1);
        CHECK(PLANKMacScrollLinesForPreference(kCFBooleanTrue) == 1);
        CHECK(PLANKMacScrollLinesForPreference(CFSTR("1")) == 1);
        CHECK(PLANKMacScrollLinesForPreference((__bridge CFTypeRef)@(NAN)) == 1);
        CHECK(PLANKMacScrollLinesForPreference((__bridge CFTypeRef)@(INFINITY)) == 1);
        CHECK(PLANKMacScrollLinesForPreference((__bridge CFTypeRef)@(-2)) == 1);
        CHECK(PLANKMacScrollLinesForPreference((__bridge CFTypeRef)@(2)) == 8);
        for (unsigned step = 0; step < 8; ++step) {
            double lines = PLANKMacScrollLinesForPreference((__bridge CFTypeRef)@(positions[step]));
            CHECK(fabs(lines - (step + 1)) < 1e-9);
            if (step) {
                double between = (positions[step - 1] + positions[step]) / 2;
                CHECK(fabs(PLANKMacScrollLinesForPreference((__bridge CFTypeRef)@(between)) - (step + 0.5)) < 1e-9);
            }
            mapper.scrollLinesPerNotch = ^double { return lines; };
            for (unsigned axis = 0; axis < 2; ++axis) for (unsigned a = 0; a < 8; ++a) {
                uint8_t p[2]; plank_transport_input_write_u16(p, (uint16_t)amounts[a]);
                event = sendInput(mapper, axis ? 4 : 3, packet(p, 2), PLANKMacInputEvent);
                double expected = amounts[a] / 120.0 * lines;
                CHECK(CGEventGetIntegerValueField(event, axis ? kCGScrollWheelEventDeltaAxis2 : kCGScrollWheelEventDeltaAxis1) == (int64_t)expected);
                CHECK(fabs(CGEventGetDoubleValueField(event, axis ? kCGScrollWheelEventFixedPtDeltaAxis2 : kCGScrollWheelEventFixedPtDeltaAxis1) - expected) < 1.0 / 65536);
                CHECK(CGEventGetIntegerValueField(event, axis ? kCGScrollWheelEventPointDeltaAxis2 : kCGScrollWheelEventPointDeltaAxis1) == llround(expected * 10));
                CFRelease(event);
            }
        }
        // Invalid providers cannot reverse, disable, or amplify scrolling.
        for (NSNumber *invalid in @[@(NAN), @(INFINITY), @0, @(-1), @9]) {
            mapper.scrollLinesPerNotch = ^double { return invalid.doubleValue; };
            uint8_t p[2]; plank_transport_input_write_u16(p, 120);
            event = sendInput(mapper, 3, packet(p, 2), PLANKMacInputEvent);
            CHECK(CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1) == 1);
            CFRelease(event);
        }
        mapper.scrollLinesPerNotch = nil;
        // Explicit expected public Mac keycodes (not reusing mapper's table).
        unsigned vk[] = {0x41, 0x5a, 0x30, 0x31, 0x60, 0x69, 0x70, 0x83,
            0x08, 0x09, 0x0d, 0x1b, 0x25, 0x28, 0xba, 0xde};
        unsigned mac[] = {0, 6, 29, 18, 82, 92, 122, 90, 51, 48, 36, 53, 123, 125, 41, 39};
        for (unsigned i = 0; i < sizeof(vk)/sizeof(vk[0]); ++i) {
            event = sendInput(mapper, 5, key(vk[i] | 0x8000, YES, 0, 0), PLANKMacInputEvent);
            CHECK(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == mac[i]);
            CHECK(CGEventGetType(event) == kCGEventKeyDown); CFRelease(event);
            event = sendInput(mapper, 5, key(vk[i], YES, 0, 0), PLANKMacInputEvent);
            CHECK(CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) == 1); CFRelease(event);
            event = sendInput(mapper, 5, key(vk[i], NO, 0, 0), PLANKMacInputEvent);
            CHECK(CGEventGetType(event) == kCGEventKeyUp); CFRelease(event);
            sendInput(mapper, 5, key(vk[i], NO, 0, 0), PLANKMacInputNoEvent);
        }
        // Both shifts held; release one must not release the other. Snapshots
        // also affect subsequent mouse events (e.g. shift-click).
        event = sendInput(mapper, 5, key(0xa0, YES, 1, 0), PLANKMacInputEvent);
        CHECK(CGEventGetType(event) == kCGEventFlagsChanged); CFRelease(event);
        event = sendInput(mapper, 5, key(0xa1, YES, 1, 0), PLANKMacInputEvent); CFRelease(event);
        event = sendInput(mapper, 5, key(0xa0, NO, 0, 0), PLANKMacInputEvent);
        CHECK(CGEventGetFlags(event) & kCGEventFlagMaskShift); CFRelease(event);
        event = sendInput(mapper, 1, motion(10, 10, 10, 10), PLANKMacInputEvent);
        CHECK(CGEventGetFlags(event) & kCGEventFlagMaskShift); CFRelease(event);
        event = sendInput(mapper, 5, key(0xa1, NO, 0, 0), PLANKMacInputEvent);
        CHECK(!(CGEventGetFlags(event) & kCGEventFlagMaskShift)); CFRelease(event);
        event = sendInput(mapper, 5, key(0x41, YES, 0, 0), PLANKMacInputEvent); CFRelease(event);
        event = sendInput(mapper, 5, key(0xa2, YES, 2, 0), PLANKMacInputEvent); CFRelease(event);
        event = sendInput(mapper, 2, packet((uint8_t[]){3, 1}, 2), PLANKMacInputEvent);
        int64_t cleanupNumber = sequence(event); CFRelease(event);
        CHECK([mapper consumeType:1 payload:motion(0, 0, 10, 10) time:1 accept:^BOOL(CGEventRef value) {
            (void)value; CHECK(NO); return YES;
        }] == PLANKMacInputMalformed);
        NSArray *releases = [mapper stopAndCopyReleaseEvents]; CHECK(releases.count == 3);
        CHECK(CGEventGetType((__bridge CGEventRef)releases[0]) == kCGEventKeyUp);
        CHECK(CGEventGetType((__bridge CGEventRef)releases[1]) == kCGEventFlagsChanged);
        CHECK(!(CGEventGetFlags((__bridge CGEventRef)releases[1]) & kCGEventFlagMaskControl));
        CHECK(CGEventGetType((__bridge CGEventRef)releases[2]) == kCGEventRightMouseUp);
        CHECK(sequence((__bridge CGEventRef)releases[2]) == cleanupNumber);
        CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        sendInput(mapper, 1, motion(0, 0, 10, 10), PLANKMacInputStopped);
        mapper = make(source, rectangles[0], pixels[0]);
        for (unsigned kind = 0; kind < 3; ++kind) {
            uint8_t type = kind == 0 ? 1 : kind == 1 ? 2 : 5;
            NSData *data = kind == 0 ? motion(10, 10, 10, 10) : kind == 1 ?
                packet((uint8_t[]){1, 1}, 2) : key(0x41, YES, 0, 0);
            CHECK([mapper consumeType:type payload:data time:now++ accept:^BOOL(CGEventRef value) {
                CHECK(value != NULL); return NO;
            }] == PLANKMacInputDenied);
        }
        event = sendInput(mapper, 2, packet((uint8_t[]){1, 1}, 2), PLANKMacInputEvent);
        cleanupNumber = sequence(event);
        CHECK(CGEventGetLocation(event).x == 0 && CGEventGetLocation(event).y == 0);
        CHECK(CGEventGetIntegerValueField(event, kCGMouseEventClickState) == 1); CFRelease(event);
        NSArray *rollback = [mapper stopAndCopyReleaseEvents];
        CHECK(rollback.count == 1 && CGEventGetType((__bridge CGEventRef)rollback[0]) == kCGEventLeftMouseUp);
        CHECK(sequence((__bridge CGEventRef)rollback[0]) == cleanupNumber);
        CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        // Interleaved buttons must retain independent press identities; a later
        // press cannot replace the number needed by an earlier drag or release.
        mapper = make(source, rectangles[0], pixels[0]);
        event = sendInput(mapper, 5, key(0xa0, YES, 1, 0), PLANKMacInputEvent); CFRelease(event);
        int64_t held[5];
        for (unsigned i = 0; i < 5; ++i) {
            event = sendInput(mapper, 2, packet((uint8_t[]){i + 1, 1}, 2), PLANKMacInputEvent);
            held[i] = sequence(event);
            for (unsigned j = 0; j < i; ++j) CHECK(held[i] != held[j]);
            CHECK(CGEventGetFlags(event) & kCGEventFlagMaskShift); CFRelease(event);
        }
        for (unsigned i = 0; i < 5; ++i) {
            event = sendInput(mapper, 1, motion(i, i, 10, 10), PLANKMacInputEvent);
            CHECK(CGEventGetType(event) == drag[i] && sequence(event) == held[i]);
            CHECK(CGEventGetFlags(event) & kCGEventFlagMaskShift); CFRelease(event);
            event = sendInput(mapper, 2, packet((uint8_t[]){i + 1, 0}, 2), PLANKMacInputEvent);
            CHECK(sequence(event) == held[i]); CFRelease(event);
        }
        CHECK([mapper stopAndCopyReleaseEvents].count == 1); // Shift only.
        // A rejected release leaves the accepted press available for drag and
        // eventual cleanup, without allocating another press identity.
        mapper = make(source, rectangles[0], pixels[0]);
        event = sendInput(mapper, 2, packet((uint8_t[]){1, 1}, 2), PLANKMacInputEvent);
        cleanupNumber = sequence(event); CFRelease(event);
        CHECK([mapper consumeType:2 payload:packet((uint8_t[]){1, 0}, 2) time:now++ accept:^BOOL(CGEventRef value) {
            CHECK(sequence(value) == cleanupNumber); return NO;
        }] == PLANKMacInputDenied);
        event = sendInput(mapper, 1, motion(1, 1, 10, 10), PLANKMacInputEvent);
        CHECK(CGEventGetType(event) == kCGEventLeftMouseDragged && sequence(event) == cleanupNumber); CFRelease(event);
        rollback = [mapper stopAndCopyReleaseEvents];
        CHECK(rollback.count == 1 && sequence((__bridge CGEventRef)rollback[0]) == cleanupNumber);
        CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        mapper = make(source, rectangles[0], pixels[0]);
        mapper.keyRepeatTiming = ^PLANKMacKeyRepeatTiming { return (PLANKMacKeyRepeatTiming){0.25, 0.05}; };
        now = 10000000000;
        event = sendInput(mapper, 5, key(0x41, YES, 0, 0), PLANKMacInputEvent); CFRelease(event);
        uint64_t due = mapper.nextRepeatTime;
        CHECK(due == 10250000000);
        BOOL (^repeatSink)(CGEventRef) = ^BOOL(CGEventRef value) {
            CHECK(CGEventGetType(value) == kCGEventKeyDown);
            CHECK(CGEventGetIntegerValueField(value, kCGKeyboardEventAutorepeat) == 1);
            CHECK(CGEventGetIntegerValueField(value, kCGKeyboardEventKeycode) == 0);
            return YES;
        };
        CHECK([mapper repeatAtTime:due - 1 accept:repeatSink] == PLANKMacInputNoEvent);
        CHECK([mapper repeatAtTime:due accept:repeatSink] == PLANKMacInputEvent);
        CHECK(mapper.nextRepeatTime == due + 50000000);
        now = due + 1;
        event = sendInput(mapper, 5, key(0xa0, YES, 1, 0), PLANKMacInputEvent); CFRelease(event);
        CHECK(mapper.nextRepeatTime == due + 50000000); // modifier doesn't restart delay
        CHECK([mapper repeatAtTime:due + 50000000 accept:^BOOL(CGEventRef value) {
            CHECK(CGEventGetFlags(value) & kCGEventFlagMaskShift); return repeatSink(value);
        }] == PLANKMacInputEvent);
        uint64_t deniedDue = mapper.nextRepeatTime;
        CHECK([mapper repeatAtTime:deniedDue accept:^BOOL(CGEventRef value) { (void)value; return NO; }] == PLANKMacInputDenied);
        CHECK(mapper.nextRepeatTime == deniedDue);
        CHECK([mapper repeatAtTime:deniedDue + 1000000000 accept:repeatSink] == PLANKMacInputEvent);
        CHECK(mapper.nextRepeatTime == deniedDue + 1050000000); // no catch-up burst
        now = deniedDue + 1000000001;
        event = sendInput(mapper, 5, key(0x41, NO, 1, 0), PLANKMacInputEvent); CFRelease(event);
        CHECK(mapper.nextRepeatTime == 0);
        CHECK([mapper repeatAtTime:now accept:repeatSink] == PLANKMacInputNoEvent);
        event = sendInput(mapper, 5, key(0x42, YES, 1, 0), PLANKMacInputEvent); CFRelease(event);
        event = sendInput(mapper, 5, key(0x43, YES, 1, 0), PLANKMacInputEvent); CFRelease(event);
        CHECK([mapper repeatAtTime:mapper.nextRepeatTime accept:^BOOL(CGEventRef value) {
            CHECK(CGEventGetIntegerValueField(value, kCGKeyboardEventKeycode) == 8); return YES;
        }] == PLANKMacInputEvent); // newest held key only
        CHECK([mapper stopAndCopyReleaseEvents].count == 3); // B, C, Shift
        CHECK(mapper.nextRepeatTime == 0);
        CHECK([mapper repeatAtTime:UINT64_MAX accept:repeatSink] == PLANKMacInputStopped);
        CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        for (NSNumber *delay in @[@(NAN), @(INFINITY), @(-1), @1000000]) {
            mapper = make(source, rectangles[0], pixels[0]);
            mapper.keyRepeatTiming = ^PLANKMacKeyRepeatTiming { return (PLANKMacKeyRepeatTiming){delay.doubleValue, 0.05}; };
            event = sendInput(mapper, 5, key(0x41, YES, 0, 0), PLANKMacInputEvent); CFRelease(event);
            CHECK(mapper.nextRepeatTime == 0);
            CHECK([mapper stopAndCopyReleaseEvents].count == 1);
        }
        mapper = make(source, rectangles[0], pixels[0]);
        mapper.keyRepeatTiming = ^PLANKMacKeyRepeatTiming { return (PLANKMacKeyRepeatTiming){0.25, 0}; };
        event = sendInput(mapper, 5, key(0x41, YES, 0, 0), PLANKMacInputEvent); CFRelease(event);
        CHECK(mapper.nextRepeatTime == 0);
        CHECK([mapper stopAndCopyReleaseEvents].count == 1);
        CFRelease(source);
        printf("macos_input_events checks=%u posted_events=0\n", checks);
    }
    return 0;
}
