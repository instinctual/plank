// SPDX-License-Identifier: GPL-3.0-or-later
// Construction/authorization-boundary tests. Never posts OS input.
#import "input-events.h"
#import <AppKit/AppKit.h>
#include "plank_transport_input.h"
#include <math.h>
#include <unistd.h>
static unsigned checks;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "pen failure line%d: %s\n", __LINE__, #x); exit(1); } ++checks; } while (0)
static NSData *pen(unsigned action, unsigned tool, float x, float y, float pressure) {
    uint8_t p[32]; plank_transport_input_encode_pen(p, action, tool, 0, 255, 65535, x, y, pressure, 0, 0);
    return [NSData dataWithBytes:p length:sizeof(p)];
}
static NSArray *sendPen(PLANKMacInputEvents *mapper, NSData *payload, PLANKMacInputResult result) {
    NSMutableArray *events = [NSMutableArray array];
    CHECK([mapper consumeType:7 payload:payload time:1000000000 accept:^BOOL(CGEventRef event) {
        [events addObject:(__bridge id)event]; return YES;
    }] == result);
    return events;
}
static CGEventRef event(NSArray *events, unsigned index) { CHECK(index < events.count); return (__bridge CGEventRef)events[index]; }
static int64_t sequence(CGEventRef e) {
    int64_t number = CGEventGetIntegerValueField(e, kCGMouseEventNumber);
    CHECK(number > 0);
    CHECK([NSEvent eventWithCGEvent:e].eventNumber == number);
    return number;
}
static NSData *buttons(unsigned action, unsigned value) {
    NSMutableData *p = [pen(action,1,.5,.5,.75) mutableCopy];
    ((uint8_t *)p.mutableBytes)[2] = value;
    return p;
}
static void checkProximity(CGEventRef e, BOOL entering, NSUInteger tool) {
    CHECK(CGEventGetType(e) == kCGEventTabletProximity);
    CHECK(CGEventGetIntegerValueField(e, kCGTabletProximityEventCapabilityMask) == 0x447);
    CHECK(CGEventGetIntegerValueField(e, kCGTabletProximityEventDeviceID) == 1);
    CHECK(CGEventGetIntegerValueField(e, kCGTabletProximityEventPointerID) == 0);
    CHECK(CGEventGetIntegerValueField(e, kCGTabletProximityEventEnterProximity) == entering);
    // Verify what an AppKit consumer actually sees, not just CG field storage.
    NSEvent *native = [NSEvent eventWithCGEvent:e]; CHECK(native);
    CHECK(native.type == NSEventTypeTabletProximity);
    CHECK(native.capabilityMask == 0x447); // identity, X/Y, buttons, pressure ONLY
    CHECK(native.deviceID == 1 && native.pointingDeviceID == 0);
    CHECK(native.pointingDeviceType == tool && native.isEnteringProximity == entering);
    CHECK(native.vendorID == 0 && native.uniqueID == 0); // no claimed Wacom identity
}
static PLANKMacInputEvents *make(CGEventSourceRef source, CGRect bounds, CGSize pixels) {
    return [[PLANKMacInputEvents alloc] initWithSource:source bounds:bounds pixels:pixels
        initialPosition:bounds.origin doubleClickInterval:.5];
}
int main(void) {
    alarm(20);
    @autoreleasepool {
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate); CHECK(source);
        CGRect bounds[] = {CGRectMake(0, 0, 1920, 1080), CGRectMake(-1920, 90, 1920, 1080), CGRectMake(0, 0, 5120, 2160)};
        CGSize pixels[] = {CGSizeMake(3840,2160), CGSizeMake(1920,1080), CGSizeMake(5120,2160)};
        for (unsigned g = 0; g < 3; ++g) {
            PLANKMacInputEvents *mapper = make(source, bounds[g], pixels[g]); CHECK(mapper);
            NSArray *events = sendPen(mapper, pen(0,1,0,0,1), PLANKMacInputEvent);
            CHECK(events.count == 2 && CGEventGetType(event(events,0)) == kCGEventTabletProximity);
            CHECK(CGEventGetIntegerValueField(event(events,0), kCGTabletProximityEventEnterProximity) == 1);
            checkProximity(event(events,0), YES, NSPointingDeviceTypePen);
            CHECK(CGEventGetType(event(events,1)) == kCGEventMouseMoved);
            CHECK(CGEventGetDoubleValueField(event(events,1), kCGTabletEventPointPressure) == 0);
            int64_t tipNumber = 0;
            for (unsigned i = 0; i <= 20; ++i) {
                float p = i / 20.0f;
                events = sendPen(mapper, pen(i ? 3 : 1,1,p,p,p), PLANKMacInputEvent);
                CHECK(events.count == 1);
                CGEventRef e = event(events,0);
                CHECK(CGEventGetType(e) == (i ? kCGEventLeftMouseDragged : kCGEventLeftMouseDown));
                if (!i) tipNumber = sequence(e);
                CHECK(sequence(e) == tipNumber);
                CHECK(fabs(CGEventGetDoubleValueField(e,kCGTabletEventPointPressure) - p) < .0001);
                CHECK(CGEventGetIntegerValueField(e,kCGMouseEventSubtype) == kCGEventMouseSubtypeTabletPoint);
                NSEvent *native = [NSEvent eventWithCGEvent:e]; CHECK(native);
                CHECK(native.subtype == NSEventSubtypeTabletPoint && native.deviceID == 1);
                // AppKit may expose the mouse-compatible pressure field with
                // 8-bit quantization; the exact CG tablet value is checked above.
                CHECK(fabs(native.pressure - p) <= 1.0 / 255.0);
                CGPoint pos = CGEventGetLocation(e);
                CHECK(fabs(pos.x - (bounds[g].origin.x + p * (bounds[g].size.width - bounds[g].size.width / pixels[g].width))) < .001);
                CHECK(fabs(pos.y - (bounds[g].origin.y + p * (bounds[g].size.height - bounds[g].size.height / pixels[g].height))) < .001);
            }
            events = sendPen(mapper, pen(2,1,1,1,0), PLANKMacInputEvent);
            CHECK(CGEventGetType(event(events,0)) == kCGEventLeftMouseUp);
            CHECK(sequence(event(events,0)) == tipNumber);
            events = sendPen(mapper, pen(0,2,.5,.5,0), PLANKMacInputEvent);
            CHECK(events.count == 3); // old tool leaves before eraser enters
            checkProximity(event(events,0), NO, NSPointingDeviceTypePen);
            checkProximity(event(events,1), YES, NSPointingDeviceTypeEraser);
            CHECK(CGEventGetIntegerValueField(event(events,1), kCGTabletProximityEventPointerType) == 3);
            events = sendPen(mapper, pen(1,2,.5,.5,.5), PLANKMacInputEvent);
            CHECK(CGEventGetType(event(events,0)) == kCGEventLeftMouseDown);
            int64_t eraserNumber = sequence(event(events,0)); CHECK(eraserNumber != tipNumber);
            events = sendPen(mapper, pen(7,0,0,0,0), PLANKMacInputEvent);
            CHECK(events.count == 2 && CGEventGetType(event(events,0)) == kCGEventLeftMouseUp);
            CHECK(sequence(event(events,0)) == eraserNumber);
            CHECK(CGEventGetIntegerValueField(event(events,1), kCGTabletProximityEventEnterProximity) == 0);
            checkProximity(event(events,1), NO, NSPointingDeviceTypeEraser);
            CHECK(sendPen(mapper,pen(7,0,0,0,0),PLANKMacInputNoEvent).count == 0);
            CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        }
        for (unsigned denied = 0; denied < 2; ++denied) {
            PLANKMacInputEvents *mapper = make(source,bounds[0],pixels[0]);
            __block unsigned calls = 0;
            CHECK([mapper consumeType:7 payload:pen(1,1,.5,.5,.75) time:1 accept:^BOOL(CGEventRef e) {
                CHECK(e); return calls++ < denied;
            }] == PLANKMacInputDenied);
            CHECK(calls == denied + 1);
            NSArray *cleanup = [mapper stopAndCopyReleaseEvents];
            CHECK(cleanup.count == denied); // only accepted proximity, never rejected tip
            if (denied) checkProximity(event(cleanup,0), NO, NSPointingDeviceTypePen);
            CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        }
        PLANKMacInputEvents *mapper = make(source,bounds[0],pixels[0]);
        sendPen(mapper,pen(0,1,.5,.5,0),PLANKMacInputEvent);
        for (unsigned bit = 1; bit <= 4; bit <<= 1) {
            NSMutableData *p = [pen(5,1,NAN,NAN,NAN) mutableCopy]; ((uint8_t *)p.mutableBytes)[2] = bit;
            NSArray *events = sendPen(mapper,p,PLANKMacInputEvent);
            CHECK(events.count == 1);
            CHECK(CGEventGetType(event(events,0)) == (bit == 1 ? kCGEventRightMouseDown : kCGEventOtherMouseDown));
            CHECK(CGEventGetIntegerValueField(event(events,0),kCGMouseEventButtonNumber) == (bit == 1 ? 2 : bit == 2 ? 1 : 3));
            int64_t number = sequence(event(events,0));
            CHECK(sendPen(mapper,p,PLANKMacInputNoEvent).count == 0);
            NSArray *drag = sendPen(mapper,buttons(0,bit),PLANKMacInputEvent);
            CHECK(drag.count == 1 && sequence(event(drag,0)) == number);
            CHECK(CGEventGetType(event(drag,0)) == (bit == 1 ? kCGEventRightMouseDragged : kCGEventOtherMouseDragged));
            ((uint8_t *)p.mutableBytes)[2] = 0;
            events = sendPen(mapper,p,PLANKMacInputEvent);
            CHECK(CGEventGetType(event(events,0)) == (bit == 1 ? kCGEventRightMouseUp : kCGEventOtherMouseUp));
            CHECK(sequence(event(events,0)) == number);
        }
        int64_t previousNumber = 0;
        for (unsigned click = 1; click <= 3; ++click) {
            NSArray *events = sendPen(mapper,pen(1,1,.5,.5,.5),PLANKMacInputEvent);
            CHECK(CGEventGetIntegerValueField(event(events,0),kCGMouseEventClickState) == click);
            int64_t number = sequence(event(events,0));
            CHECK(number != previousNumber); previousNumber = number;
            events = sendPen(mapper,pen(2,1,.5,.5,0),PLANKMacInputEvent);
            CHECK(sequence(event(events,0)) == number);
        }
        sendPen(mapper,pen(7,0,0,0,0),PLANKMacInputEvent);
        for (unsigned length = 0; length < 34; ++length) if (length != 32)
            CHECK(sendPen(mapper,[NSMutableData dataWithLength:length],PLANKMacInputMalformed).count == 0);
        for (unsigned offset = 8; offset <= 24; offset += 4) for (NSNumber *bad in @[@(NAN), @(INFINITY), @(-.1), @1.1]) {
            NSMutableData *p = [pen(1,1,.5,.5,.5) mutableCopy];
            plank_transport_input_write_float((uint8_t *)p.mutableBytes + offset,bad.floatValue);
            CHECK(sendPen(mapper,p,PLANKMacInputMalformed).count == 0);
        }
        for (unsigned offset = 6; offset < 32; ++offset) if (offset < 8 || offset >= 28) {
            NSMutableData *p = [pen(1,1,.5,.5,.5) mutableCopy]; ((uint8_t *)p.mutableBytes)[offset] = 1;
            CHECK(sendPen(mapper,p,PLANKMacInputMalformed).count == 0);
        }
        NSArray *tip = sendPen(mapper,pen(1,1,.5,.5,.75),PLANKMacInputEvent);
        int64_t cleanupNumber = sequence(event(tip,1)); // proximity then tip
        NSArray *cleanup = [mapper stopAndCopyReleaseEvents];
        CHECK(cleanup.count == 2 && CGEventGetType(event(cleanup,0)) == kCGEventLeftMouseUp);
        CHECK(sequence(event(cleanup,0)) == cleanupNumber);
        CHECK(CGEventGetDoubleValueField(event(cleanup,0),kCGTabletEventPointPressure) == 0);
        checkProximity(event(cleanup,1), NO, NSPointingDeviceTypePen);
        CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        CHECK(sendPen(mapper,pen(0,1,0,0,0),PLANKMacInputStopped).count == 0);
        // Tip plus all side buttons, with a simultaneous ordinary mouse press:
        // each accepted press retains its own identity through cleanup.
        mapper = make(source,bounds[0],pixels[0]);
        NSArray *held = sendPen(mapper,buttons(1,7),PLANKMacInputEvent);
        CHECK(held.count == 5); // proximity, tip, three side buttons
        int64_t numbers[4];
        for (unsigned i = 0; i < 4; ++i) {
            numbers[i] = sequence(event(held,i + 1));
            for (unsigned j = 0; j < i; ++j) CHECK(numbers[i] != numbers[j]);
        }
        __block int64_t mouseNumber = 0;
        NSData *mousePress = [NSData dataWithBytes:(uint8_t[]){1,1} length:2];
        CHECK([mapper consumeType:2 payload:mousePress
            time:1000000000 accept:^BOOL(CGEventRef e) { mouseNumber = sequence(e); return YES; }] == PLANKMacInputEvent);
        for (unsigned i = 0; i < 4; ++i) CHECK(mouseNumber != numbers[i]);
        CHECK(sequence(event(sendPen(mapper,buttons(3,7),PLANKMacInputEvent),0)) == numbers[0]);
        cleanup = [mapper stopAndCopyReleaseEvents];
        CHECK(cleanup.count == 6); // side releases, tip release, proximity, mouse release
        for (unsigned i = 0; i < 3; ++i) CHECK(sequence(event(cleanup,i)) == numbers[i + 1]);
        CHECK(sequence(event(cleanup,3)) == numbers[0]);
        checkProximity(event(cleanup,4), NO, NSPointingDeviceTypePen);
        CHECK(sequence(event(cleanup,5)) == mouseNumber);
        CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        // Reject a side-button press after accepting proximity and tip. A later
        // accepted side press must not replace the tip's active sequence.
        mapper = make(source,bounds[0],pixels[0]);
        __block unsigned accepted = 0;
        __block int64_t tipNumber = 0;
        CHECK([mapper consumeType:7 payload:buttons(1,1) time:1000000000 accept:^BOOL(CGEventRef e) {
            if (CGEventGetType(e) == kCGEventLeftMouseDown) tipNumber = sequence(e);
            return accepted++ < 2;
        }] == PLANKMacInputDenied);
        CHECK(accepted == 3);
        held = sendPen(mapper,buttons(5,1),PLANKMacInputEvent);
        CHECK(held.count == 1 && sequence(event(held,0)) != tipNumber);
        // A denied tip release also keeps the original press for teardown.
        CHECK([mapper consumeType:7 payload:buttons(2,1) time:1000000000 accept:^BOOL(CGEventRef e) {
            CHECK(CGEventGetType(e) == kCGEventLeftMouseUp && sequence(e) == tipNumber); return NO;
        }] == PLANKMacInputDenied);
        cleanup = [mapper stopAndCopyReleaseEvents];
        CHECK(cleanup.count == 3);
        CHECK(sequence(event(cleanup,0)) == sequence(event(held,0)));
        CHECK(sequence(event(cleanup,1)) == tipNumber);
        checkProximity(event(cleanup,2), NO, NSPointingDeviceTypePen);
        CFRelease(source);
        printf("macos_pen_events_pass checks=%u posted=0\n",checks);
    }
}
