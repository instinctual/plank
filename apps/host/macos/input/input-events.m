// SPDX-License-Identifier: GPL-3.0-or-later
#import "input-events.h"
#import <Carbon/Carbon.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#include "plank_transport_input.h"
#include <math.h>
#include <stdint.h>

// The existing Client sends QWERTY-normalized Windows virtual key identities,
// not macOS keycodes. Keep this boundary explicit; no Sunshine packet wrapper.
static int keyCode(uint8_t key) {
    static const CGKeyCode letters[] = {
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
        kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
        kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
        kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
        kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z};
    static const CGKeyCode numbers[] = {kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2,
        kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9};
    static const CGKeyCode keypad[] = {kVK_ANSI_Keypad0, kVK_ANSI_Keypad1,
        kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
        kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9};
    static const CGKeyCode function[] = {kVK_F1, kVK_F2, kVK_F3, kVK_F4,
        kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20};
    if (key >= 0x41 && key <= 0x5a) return letters[key - 0x41];
    if (key >= 0x30 && key <= 0x39) return numbers[key - 0x30];
    if (key >= 0x60 && key <= 0x69) return keypad[key - 0x60];
    if (key >= 0x70 && key <= 0x83) return function[key - 0x70];
    switch (key) {
        case 0x08: return kVK_Delete;
        case 0x09: return kVK_Tab;
        case 0x0c: return kVK_ANSI_KeypadClear;
        case 0x0d: return kVK_Return;
        case 0x14: return kVK_CapsLock;
        case 0x1b: return kVK_Escape;
        case 0x20: return kVK_Space;
        case 0x21: return kVK_PageUp;
        case 0x22: return kVK_PageDown;
        case 0x23: return kVK_End;
        case 0x24: return kVK_Home;
        case 0x25: return kVK_LeftArrow;
        case 0x26: return kVK_UpArrow;
        case 0x27: return kVK_RightArrow;
        case 0x28: return kVK_DownArrow;
        case 0x2e: return kVK_ForwardDelete;
        case 0x2f: return kVK_Help;
        case 0x5b: return kVK_Command;
        case 0x5c: return kVK_RightCommand;
        case 0x6a: return kVK_ANSI_KeypadMultiply;
        case 0x6b: return kVK_ANSI_KeypadPlus;
        case 0x6d: return kVK_ANSI_KeypadMinus;
        case 0x6e: return kVK_ANSI_KeypadDecimal;
        case 0x6f: return kVK_ANSI_KeypadDivide;
        case 0xa0: return kVK_Shift;
        case 0xa1: return kVK_RightShift;
        case 0xa2: return kVK_Control;
        case 0xa3: return kVK_RightControl;
        case 0xa4: return kVK_Option;
        case 0xa5: return kVK_RightOption;
        case 0xba: return kVK_ANSI_Semicolon;
        case 0xbb: return kVK_ANSI_Equal;
        case 0xbc: return kVK_ANSI_Comma;
        case 0xbd: return kVK_ANSI_Minus;
        case 0xbe: return kVK_ANSI_Period;
        case 0xbf: return kVK_ANSI_Slash;
        case 0xc0: return kVK_ANSI_Grave;
        case 0xdb: return kVK_ANSI_LeftBracket;
        case 0xdc: return kVK_ANSI_Backslash;
        case 0xdd: return kVK_ANSI_RightBracket;
        case 0xde: return kVK_ANSI_Quote;
        case 0xe2: return kVK_ISO_Section;
        default: return -1; // Never substitute keycode zero (the A key).
    }
}
static CGEventFlags modifier(uint8_t key) {
    switch (key) {
        case 0xa0: case 0xa1: return kCGEventFlagMaskShift;
        case 0xa2: case 0xa3: return kCGEventFlagMaskControl;
        case 0xa4: case 0xa5: return kCGEventFlagMaskAlternate;
        case 0x5b: case 0x5c: return kCGEventFlagMaskCommand;
        default: return 0;
    }
}
static CGEventFlags wireFlags(uint8_t value) {
    return ((value & 1) ? kCGEventFlagMaskShift : 0) |
        ((value & 2) ? kCGEventFlagMaskControl : 0) |
        ((value & 4) ? kCGEventFlagMaskAlternate : 0) |
        ((value & 8) ? kCGEventFlagMaskCommand : 0);
}
static CGMouseButton mouseButton(unsigned index) {
    static const CGMouseButton buttons[] = {kCGMouseButtonLeft, kCGMouseButtonCenter,
        kCGMouseButtonRight, 3, 4};
    return buttons[index];
}
static CGEventType buttonType(unsigned index, BOOL down) {
    if (index == 0) return down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
    if (index == 2) return down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
    return down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
}
static int64_t nextMouseEventNumber(int64_t number) {
    return number == INT64_MAX ? 1 : number + 1;
}

typedef struct {
    CGPoint position, clickPosition[5];
    BOOL keys[256], buttons[5], stopped;
    CGEventFlags flags;
    uint64_t lastTime, clickTime[5];
    unsigned clickCount[5];
    // Quartz pairs a press with its drag/up by event number. Constructing each
    // CGEvent independently does not establish that pairing. Keep a distinct
    // number per held button, including separate mouse and tablet sequences.
    int64_t nextMouseEventNumber, mouseEventNumber[5], penEventNumber[4];
    uint8_t repeatKey;
    uint64_t repeatDue, repeatInterval;
} PLANKMacInputState;

// Type7 uses normalized coordinates, not client pixels or raw tablet identity.
// Values match the shared pen payload contract (see protocol/macos-pen-input.md).
typedef struct {
    CGPoint position;
    BOOL near, down;
    uint8_t tool, buttons;
    double pressure;
    uint64_t clickTime;
    CGPoint clickPosition;
    unsigned clickCount;
} PLANKMacPenState;
static CGEventType penButtonKind(unsigned bit, BOOL down) {
    return bit == 1 ? (down ? kCGEventRightMouseDown : kCGEventRightMouseUp) :
        (down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp);
}
static unsigned penButtonNumber(unsigned bit) { return bit == 1 ? 2 : bit == 2 ? 1 : 3; }
static int penEventIndex(CGEventType kind, unsigned sideButtons) {
    switch (kind) {
        case kCGEventLeftMouseDown: case kCGEventLeftMouseDragged: case kCGEventLeftMouseUp: return 0;
        case kCGEventRightMouseDown: case kCGEventRightMouseDragged: case kCGEventRightMouseUp: return 1;
        case kCGEventOtherMouseDown: case kCGEventOtherMouseDragged: case kCGEventOtherMouseUp:
            return sideButtons & 2 ? 2 : 3;
        default: return -1; // Hover and proximity do not belong to a press.
    }
}

@implementation PLANKMacInputEvents {
    CGEventSourceRef _source;
    CGRect _bounds;
    CGSize _pixels;
    PLANKMacInputState _state;
    PLANKMacPenState _pen;
    uint64_t _doubleClickNS;
}
- (instancetype)init { return nil; }
- (instancetype)initWithSource:(CGEventSourceRef)source bounds:(CGRect)bounds
                        pixels:(CGSize)pixels initialPosition:(CGPoint)position
           doubleClickInterval:(NSTimeInterval)interval {
    if (!source || !isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
        !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
        !isfinite(CGRectGetMaxX(bounds)) || !isfinite(CGRectGetMaxY(bounds)) ||
        !isfinite(pixels.width) || !isfinite(pixels.height) ||
        bounds.size.width <= 0 || bounds.size.height <= 0 ||
        pixels.width < 2 || pixels.height < 2 || pixels.width > 65536 || pixels.height > 65536 ||
        floor(pixels.width) != pixels.width || floor(pixels.height) != pixels.height ||
        !isfinite(position.x) || !isfinite(position.y) ||
        !isfinite(interval) || interval <= 0 || interval > 10) return nil;
    self = [super init];
    if (self) {
        _source = (CGEventSourceRef)CFRetain(source); _bounds = bounds; _pixels = pixels;
        _state.position = [self clamp:position]; _doubleClickNS = (uint64_t)(interval * 1e9);
        // Caps Lock is a latch, not a held remote key. Preserve its initial state.
        _state.flags = CGEventSourceFlagsState(CGEventSourceGetSourceStateID(source)) & kCGEventFlagMaskAlphaShift;
    }
    return self;
}
- (void)dealloc { if (_source) CFRelease(_source); }
- (CGPoint)clamp:(CGPoint)p {
    return CGPointMake(fmax(_bounds.origin.x, fmin(p.x, CGRectGetMaxX(_bounds) - _bounds.size.width / _pixels.width)),
        fmax(_bounds.origin.y, fmin(p.y, CGRectGetMaxY(_bounds) - _bounds.size.height / _pixels.height)));
}
- (PLANKMacInputResult)createType:(uint8_t)type payload:(NSData *)payload
                           time:(uint64_t)time event:(CGEventRef *)output {
    if (!output) return PLANKMacInputMalformed;
    *output = NULL;
    if (_state.stopped) return PLANKMacInputStopped;
    if (!payload.length || payload.length > PLANK_TRANSPORT_INPUT_MAX_PAYLOAD_SIZE || time < _state.lastTime)
        return PLANKMacInputMalformed;
    const uint8_t *p = payload.bytes;
    CGEventRef event = NULL;
    switch (type) {
        case PLANK_TRANSPORT_INPUT_ABSOLUTE_MOUSE: {
            if (payload.length != 8) return PLANKMacInputMalformed;
            unsigned x = plank_transport_input_read_u16(p), y = plank_transport_input_read_u16(p + 2);
            unsigned mx = plank_transport_input_read_u16(p + 4), my = plank_transport_input_read_u16(p + 6);
            if (!mx || !my || x > mx || y > my) return PLANKMacInputMalformed;
            // Wire maxima are inclusive (Client referenceWidth/Height minus 1).
            // Map to the last physical pixel, expressed in global Quartz points.
            CGPoint target = CGPointMake(_bounds.origin.x + (double)x / mx *
                (_bounds.size.width - _bounds.size.width / _pixels.width),
                _bounds.origin.y + (double)y / my * (_bounds.size.height - _bounds.size.height / _pixels.height));
            CGEventType kind = kCGEventMouseMoved;
            unsigned index = 0;
            for (unsigned i = 0; i < 5; ++i) if (_state.buttons[i]) {
                index = i; kind = i == 0 ? kCGEventLeftMouseDragged :
                    i == 2 ? kCGEventRightMouseDragged : kCGEventOtherMouseDragged;
                break;
            }
            event = CGEventCreateMouseEvent(_source, kind, target, mouseButton(index));
            if (event) {
                if (_state.buttons[index]) {
                    CGEventSetIntegerValueField(event, kCGMouseEventNumber, _state.mouseEventNumber[index]);
                    CGEventSetIntegerValueField(event, kCGMouseEventClickState, _state.clickCount[index]);
                }
                _state.position = target;
            }
            break;
        }
        case PLANK_TRANSPORT_INPUT_MOUSE_BUTTON: {
            if (payload.length != 2 || p[0] < 1 || p[0] > 5 || p[1] > 1)
                return PLANKMacInputMalformed;
            unsigned index = p[0] - 1; BOOL down = p[1];
            if (_state.buttons[index] == down) return PLANKMacInputNoEvent;
            unsigned clicks = _state.clickCount[index];
            if (down) clicks = clicks && time - _state.clickTime[index] <= _doubleClickNS &&
                hypot(_state.position.x - _state.clickPosition[index].x, _state.position.y - _state.clickPosition[index].y) <= 4
                ? MIN(clicks + 1, 3u) : 1;
            event = CGEventCreateMouseEvent(_source, buttonType(index, down), _state.position, mouseButton(index));
            if (event) {
                if (down) {
                    _state.nextMouseEventNumber = nextMouseEventNumber(_state.nextMouseEventNumber);
                    _state.mouseEventNumber[index] = _state.nextMouseEventNumber;
                }
                CGEventSetIntegerValueField(event, kCGMouseEventNumber, _state.mouseEventNumber[index]);
                CGEventSetIntegerValueField(event, kCGMouseEventClickState, clicks);
                _state.buttons[index] = down;
                if (down) { _state.clickTime[index] = time; _state.clickPosition[index] = _state.position; _state.clickCount[index] = clicks; }
            }
            break;
        }
        case PLANK_TRANSPORT_INPUT_VERTICAL_SCROLL:
        case PLANK_TRANSPORT_INPUT_HORIZONTAL_SCROLL: {
            if (payload.length != 2) return PLANKMacInputMalformed;
            int amount = plank_transport_input_read_u16(p);
            if (amount >= 32768) amount -= 65536;
            if (!amount) return PLANKMacInputNoEvent;
            // 120 protocol units = one wheel notch/line. Fixed-point fields
            // preserve high-resolution sub-notch input instead of truncating it.
            BOOL horizontal = type == PLANK_TRANSPORT_INPUT_HORIZONTAL_SCROLL;
            double scale = self.scrollLinesPerNotch ? self.scrollLinesPerNotch() : 1;
            if (!isfinite(scale) || scale < 1 || scale > 8) scale = 1;
            double lines = amount / 120.0 * scale;
            event = CGEventCreateScrollWheelEvent(_source, kCGScrollEventUnitLine, 2, 0, 0);
            if (event) {
                CGEventSetLocation(event, _state.position);
                CGEventSetIntegerValueField(event, horizontal ? kCGScrollWheelEventDeltaAxis2 : kCGScrollWheelEventDeltaAxis1, (int64_t)lines);
                CGEventSetDoubleValueField(event, horizontal ? kCGScrollWheelEventFixedPtDeltaAxis2 : kCGScrollWheelEventFixedPtDeltaAxis1, lines);
                CGEventSetIntegerValueField(event, horizontal ? kCGScrollWheelEventPointDeltaAxis2 : kCGScrollWheelEventPointDeltaAxis1,
                    llround(lines * CGEventSourceGetPixelsPerLine(_source)));
            }
            break;
        }
        case PLANK_TRANSPORT_INPUT_KEYBOARD: {
            if (payload.length != 5 || p[2] > 1 || (p[3] & ~0x0f) || (p[4] & ~1))
                return PLANKMacInputMalformed;
            uint16_t wire = plank_transport_input_read_u16(p);
            if (wire & 0x7f00) return PLANKMacInputMalformed;
            // Non-normalized layout identities need explicit qualification; do
            // not silently reinterpret them as an unrelated ANSI physical key.
            if (p[4]) return PLANKMacInputUnsupported;
            uint8_t key = wire & 0xff; int code = keyCode(key); BOOL down = p[2];
            if (code < 0) return PLANKMacInputUnsupported;
            if (!down && !_state.keys[key]) return PLANKMacInputNoEvent;
            BOOL repeat = down && _state.keys[key];
            if (repeat && (modifier(key) || key == 0x14)) return PLANKMacInputNoEvent;
            CGEventFlags flags = wireFlags(p[3]) | (_state.flags & kCGEventFlagMaskAlphaShift);
            CGEventFlags bit = modifier(key);
            if (bit) {
                BOOL held = down;
                for (unsigned k = 0; k < 256; ++k) if (k != key && _state.keys[k] && modifier(k) == bit) held = YES;
                flags = held ? flags | bit : flags & ~bit;
            }
            if (key == 0x14 && down) flags ^= kCGEventFlagMaskAlphaShift;
            event = CGEventCreateKeyboardEvent(_source, (CGKeyCode)code, down);
            if (event) {
                if (bit || key == 0x14) CGEventSetType(event, kCGEventFlagsChanged);
                CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, repeat);
                _state.keys[key] = down; _state.flags = flags;
                if (!down && key == _state.repeatKey) _state.repeatDue = 0;
                if (down && !repeat && !bit && key != 0x14) {
                    _state.repeatDue = 0; // newest non-modifier key owns repetition
                    PLANKMacKeyRepeatTiming timing = self.keyRepeatTiming ? self.keyRepeatTiming() : (PLANKMacKeyRepeatTiming){0, 0};
                    // macOS Repeat Off uses an extremely long initial delay.
                    // Invalid/disabled values must not produce a busy timer.
                    if (isfinite(timing.delay) && isfinite(timing.interval) &&
                        timing.delay >= 0 && timing.delay <= 60 && timing.interval >= 0.001 && timing.interval <= 60 &&
                        time <= UINT64_MAX - 60 * 1000000000ULL) {
                        _state.repeatKey = key;
                        _state.repeatInterval = (uint64_t)(timing.interval * 1e9);
                        _state.repeatDue = time + (uint64_t)(timing.delay * 1e9);
                    }
                }
            }
            break;
        }
        default: return PLANKMacInputUnsupported; // Raw HID/text are not this component.
    }
    if (!event) { _state.stopped = YES; return PLANKMacInputStopped; }
    CGEventSetFlags(event, _state.flags); CGEventSetTimestamp(event, time);
    _state.lastTime = time; *output = event;
    return PLANKMacInputEvent;
}
- (PLANKMacInputResult)consumeType:(uint8_t)type payload:(NSData *)payload
                           time:(uint64_t)time accept:(BOOL (^)(CGEventRef))accept {
    if (!accept) return PLANKMacInputMalformed;
    if (type == PLANK_TRANSPORT_INPUT_PEN)
        return [self consumePen:payload time:time accept:accept];
    PLANKMacInputState previous = _state;
    CGEventRef event = NULL;
    PLANKMacInputResult result = [self createType:type payload:payload time:time event:&event];
    if (result != PLANKMacInputEvent) return result;
    BOOL accepted = accept(event);
    CFRelease(event);
    // A packet revoked between construction and delivery was never posted.
    // Roll back *all* state so cleanup cannot release an undelivered key/button.
    if (!accepted) { _state = previous; return PLANKMacInputDenied; }
    return PLANKMacInputEvent;
}

- (CGEventRef)penEvent:(PLANKMacPenState)pen kind:(CGEventType)kind {
    BOOL proximity = kind == kCGEventTabletProximity;
    CGMouseButton button = kind == kCGEventRightMouseDragged || kind == kCGEventRightMouseDown || kind == kCGEventRightMouseUp ?
        kCGMouseButtonRight : kind == kCGEventOtherMouseDragged ? (pen.buttons & 2 ? kCGMouseButtonCenter : 3) : kCGMouseButtonLeft;
    CGEventRef event = CGEventCreateMouseEvent(_source, proximity ? kCGEventMouseMoved : kind, pen.position, button);
    if (!event) return NULL;
    CGEventSetType(event, kind);
    if (kind == kCGEventTabletProximity) {
        CGEventSetIntegerValueField(event, kCGTabletProximityEventEnterProximity, pen.near);
        // Public Quartz pointing-device values: pen=1, eraser=3. Identity is
        // session-local synthetic, not a claimed physical Wacom model/serial.
        CGEventSetIntegerValueField(event, kCGTabletProximityEventPointerType, pen.tool == 2 ? 3 : 1);
        CGEventSetIntegerValueField(event, kCGTabletProximityEventDeviceID, 1);
        // pointerID is the tool index on the tablet, not the deviceID used to
        // match point events. We expose one tool, never a second concurrent pen.
        CGEventSetIntegerValueField(event, kCGTabletProximityEventPointerID, 0);
        CGEventSetIntegerValueField(event, kCGTabletProximityEventSystemTabletID, 1);
        // Applications discover support through proximity, not merely through
        // nonzero pressure on later point events. Advertise only fields that
        // this normalized mapper supplies; no tilt, rotation or vendor data.
        CGEventSetIntegerValueField(event, kCGTabletProximityEventCapabilityMask,
            NX_TABLET_CAPABILITY_DEVICEIDMASK | NX_TABLET_CAPABILITY_ABSXMASK |
            NX_TABLET_CAPABILITY_ABSYMASK | NX_TABLET_CAPABILITY_BUTTONSMASK |
            NX_TABLET_CAPABILITY_PRESSUREMASK);
    } else {
        CGEventSetIntegerValueField(event, kCGMouseEventSubtype, kCGEventMouseSubtypeTabletPoint);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, MAX(1u, pen.clickCount));
        CGEventSetIntegerValueField(event, kCGTabletEventDeviceID, 1);
        CGEventSetIntegerValueField(event, kCGTabletEventPointButtons, (pen.down ? 1 : 0) | (pen.buttons << 1));
        CGEventSetIntegerValueField(event, kCGTabletEventPointX, llround(pen.position.x));
        CGEventSetIntegerValueField(event, kCGTabletEventPointY, llround(pen.position.y));
        CGEventSetDoubleValueField(event, kCGMouseEventPressure, pen.down ? pen.pressure : 0);
        CGEventSetDoubleValueField(event, kCGTabletEventPointPressure, pen.down ? pen.pressure : 0);
    }
    CGEventSetFlags(event, _state.flags);
    return event;
}
- (BOOL)deliverPen:(PLANKMacPenState)next kind:(CGEventType)kind time:(uint64_t)time
           accept:(BOOL (^)(CGEventRef))accept {
    CGEventRef event = [self penEvent:next kind:kind];
    if (!event) { _state.stopped = YES; return NO; }
    CGEventSetTimestamp(event, time);
    unsigned changed = next.buttons ^ _pen.buttons;
    if (changed) CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, penButtonNumber(changed));
    int index = penEventIndex(kind, changed ? changed : next.buttons);
    BOOL down = kind == kCGEventLeftMouseDown || kind == kCGEventRightMouseDown || kind == kCGEventOtherMouseDown;
    int64_t number = index < 0 ? 0 : down ? nextMouseEventNumber(_state.nextMouseEventNumber) : _state.penEventNumber[index];
    if (index >= 0) CGEventSetIntegerValueField(event, kCGMouseEventNumber, number);
    BOOL delivered = accept(event);
    CFRelease(event);
    // Commit each accepted event. If authority disappears between proximity
    // and tip, retain only the state actually delivered, never a phantom down.
    if (delivered) {
        if (down) {
            _state.nextMouseEventNumber = number;
            _state.penEventNumber[index] = number;
        }
        _pen = next; _state.position = next.position; _state.lastTime = time;
    }
    return delivered;
}
- (PLANKMacInputResult)consumePen:(NSData *)payload time:(uint64_t)time
                         accept:(BOOL (^)(CGEventRef))accept {
    if (_state.stopped) return PLANKMacInputStopped;
    if (payload.length != PLANK_TRANSPORT_INPUT_PEN_SIZE || time < _state.lastTime)
        return PLANKMacInputMalformed;
    const uint8_t *p = payload.bytes;
    uint8_t action = p[0], tool = p[1];
    if (action > 7 || p[6] || p[7] || plank_transport_input_read_u32(p + 28))
        return PLANKMacInputMalformed;
    BOOL leaving = action == 4 || action == 6 || action == 7;
    double x = 0, y = 0, pressure = 0;
    if (!leaving) {
        if (tool < 1 || tool > 2 || (p[2] & ~7)) return PLANKMacInputMalformed;
        if (action != 5) {
            x = plank_transport_input_read_float(p + 8); y = plank_transport_input_read_float(p + 12);
            pressure = plank_transport_input_read_float(p + 16);
            double major = plank_transport_input_read_float(p + 20), minor = plank_transport_input_read_float(p + 24);
            unsigned rotation = plank_transport_input_read_u16(p + 4);
            if (!isfinite(x) || !isfinite(y) || !isfinite(pressure) || !isfinite(major) || !isfinite(minor) ||
                x < 0 || x > 1 || y < 0 || y > 1 || pressure < 0 || pressure > 1 ||
                major < 0 || major > 1 || minor < 0 || minor > 1 ||
                (p[3] > 90 && p[3] != 255) || (rotation > 359 && rotation != 65535))
                return PLANKMacInputMalformed;
        }
    }
    BOOL delivered = NO;
    if (leaving || (_pen.near && _pen.tool != tool)) {
        PLANKMacPenState next = _pen;
        for (unsigned bit = 1; bit <= 4; bit <<= 1) if (next.buttons & bit) {
            next.buttons &= ~bit;
            if (![self deliverPen:next kind:penButtonKind(bit, NO) time:time accept:accept])
                return _state.stopped ? PLANKMacInputStopped : PLANKMacInputDenied;
            delivered = YES;
        }
        if (next.down) {
            next.down = NO; next.pressure = 0; next.buttons = 0;
            if (![self deliverPen:next kind:kCGEventLeftMouseUp time:time accept:accept])
                return _state.stopped ? PLANKMacInputStopped : PLANKMacInputDenied;
            delivered = YES;
        }
        if (next.near) {
            next.near = NO; next.buttons = 0;
            if (![self deliverPen:next kind:kCGEventTabletProximity time:time accept:accept])
                return _state.stopped ? PLANKMacInputStopped : PLANKMacInputDenied;
            delivered = YES;
        }
        if (leaving) return delivered ? PLANKMacInputEvent : PLANKMacInputNoEvent;
    }
    if (action == 5 && !_pen.near) return PLANKMacInputNoEvent;
    PLANKMacPenState next = _pen;
    if (action != 5) {
        next.position = CGPointMake(_bounds.origin.x + x * (_bounds.size.width - _bounds.size.width / _pixels.width),
            _bounds.origin.y + y * (_bounds.size.height - _bounds.size.height / _pixels.height));
    }
    if (!next.near) {
        if (next.tool != tool) next.clickCount = 0;
        next.near = YES; next.tool = tool; next.down = NO; next.pressure = 0; next.buttons = 0;
        if (![self deliverPen:next kind:kCGEventTabletProximity time:time accept:accept])
            return _state.stopped ? PLANKMacInputStopped : PLANKMacInputDenied;
    }
    if (action != 5) { next.down = action == 1 || action == 3; next.pressure = next.down ? pressure : 0; }
    if (next.down && !_pen.down) {
        next.clickCount = next.clickCount && time - next.clickTime <= _doubleClickNS &&
            hypot(next.position.x - next.clickPosition.x, next.position.y - next.clickPosition.y) <= 4 ?
            MIN(next.clickCount + 1, 3u) : 1;
        next.clickTime = time; next.clickPosition = next.position;
    }
    CGEventType kind = next.down != _pen.down ? (next.down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp) :
        next.down ? kCGEventLeftMouseDragged : kCGEventMouseMoved;
    if (action != 5) {
        if (kind == kCGEventMouseMoved && next.buttons)
            kind = next.buttons & 1 ? kCGEventRightMouseDragged : kCGEventOtherMouseDragged;
        if (![self deliverPen:next kind:kind time:time accept:accept])
            return _state.stopped ? PLANKMacInputStopped : PLANKMacInputDenied;
        delivered = YES;
    }
    for (unsigned bit = 1; bit <= 4; bit <<= 1) if ((next.buttons ^ p[2]) & bit) {
        next.buttons ^= bit;
        if (![self deliverPen:next kind:penButtonKind(bit, (next.buttons & bit) != 0) time:time accept:accept])
            return _state.stopped ? PLANKMacInputStopped : PLANKMacInputDenied;
        delivered = YES;
    }
    return delivered ? PLANKMacInputEvent : PLANKMacInputNoEvent;
}
- (uint64_t)nextRepeatTime { return _state.stopped ? 0 : _state.repeatDue; }
- (PLANKMacInputResult)repeatAtTime:(uint64_t)time accept:(BOOL (^)(CGEventRef))accept {
    if (_state.stopped) return PLANKMacInputStopped;
    if (!accept || time < _state.lastTime) return PLANKMacInputMalformed;
    if (!_state.repeatDue || time < _state.repeatDue) return PLANKMacInputNoEvent;
    CGEventRef event = CGEventCreateKeyboardEvent(_source, (CGKeyCode)keyCode(_state.repeatKey), true);
    if (!event) { _state.stopped = YES; return PLANKMacInputStopped; }
    CGEventSetFlags(event, _state.flags);
    CGEventSetTimestamp(event, time);
    CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, 1);
    BOOL accepted = accept(event);
    CFRelease(event);
    if (!accepted) return PLANKMacInputDenied;
    _state.lastTime = time;
    // Never replay a backlog of repeats after a busy queue or sleep.
    _state.repeatDue = time <= UINT64_MAX - _state.repeatInterval ? time + _state.repeatInterval : 0;
    return PLANKMacInputEvent;
}
- (NSArray *)stopAndCopyReleaseEvents {
    NSMutableArray *events = [NSMutableArray array];
    // A construction failure also latches stop, but held state still needs a
    // best-effort release attempt. Clearing state makes repeated stop idempotent.
    _state.stopped = YES;
    _state.repeatDue = 0;
    for (unsigned bit = 1; bit <= 4; bit <<= 1) if (_pen.buttons & bit) {
        _pen.buttons &= ~bit;
        CGEventRef event = [self penEvent:_pen kind:penButtonKind(bit, NO)];
        if (event) {
            CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, penButtonNumber(bit));
            CGEventSetIntegerValueField(event, kCGMouseEventNumber,
                _state.penEventNumber[penEventIndex(penButtonKind(bit, NO), bit)]);
            [events addObject:CFBridgingRelease(event)];
        }
    }
    if (_pen.down) {
        _pen.down = NO; _pen.pressure = 0; _pen.buttons = 0;
        CGEventRef event = [self penEvent:_pen kind:kCGEventLeftMouseUp];
        if (event) {
            CGEventSetIntegerValueField(event, kCGMouseEventNumber, _state.penEventNumber[0]);
            [events addObject:CFBridgingRelease(event)];
        }
    }
    if (_pen.near) {
        _pen.near = NO; _pen.buttons = 0;
        CGEventRef event = [self penEvent:_pen kind:kCGEventTabletProximity];
        if (event) [events addObject:CFBridgingRelease(event)];
    }
    for (unsigned k = 0; k < 256; ++k) if (_state.keys[k]) {
        _state.keys[k] = NO;
        CGEventFlags bit = modifier(k);
        if (bit) {
            BOOL held = NO;
            for (unsigned other = 0; other < 256; ++other)
                if (_state.keys[other] && modifier(other) == bit) held = YES;
            if (!held) _state.flags &= ~bit;
        }
        CGEventRef event = CGEventCreateKeyboardEvent(_source, (CGKeyCode)keyCode(k), false);
        if (event) {
            if (bit || k == 0x14) CGEventSetType(event, kCGEventFlagsChanged);
            CGEventSetFlags(event, _state.flags); [events addObject:CFBridgingRelease(event)];
        }
    }
    _state.flags &= kCGEventFlagMaskAlphaShift;
    for (unsigned i = 0; i < 5; ++i) if (_state.buttons[i]) {
        _state.buttons[i] = NO;
        CGEventRef event = CGEventCreateMouseEvent(_source, buttonType(i, NO), _state.position, mouseButton(i));
        if (event) {
            CGEventSetIntegerValueField(event, kCGMouseEventNumber, _state.mouseEventNumber[i]);
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, _state.clickCount[i]);
            CGEventSetFlags(event, _state.flags); [events addObject:CFBridgingRelease(event)];
        }
    }
    return events;
}
@end
