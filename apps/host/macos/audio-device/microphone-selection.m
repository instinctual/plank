// SPDX-License-Identifier: GPL-3.0-or-later
#import "microphone-selection.h"
@implementation PLANKMacMicrophoneSelection {
    NSString *_previous;
    BOOL _owned;
}
- (BOOL)select {
    if (_owned) return YES;
    AudioObjectID device = PLANKMicDeviceForUID(@PLANK_MIC_DEVICE_UID);
    if (!device) return NO;
    AudioObjectID current = PLANKMicDefaultInput();
    if (current == device) return YES;
    _previous = PLANKMicDeviceUID(current);
    // No physical input existed: removing the virtual driver will return the
    // system to no input. Never select an arbitrary fallback device.
    if (!PLANKMicSetDefaultInput(device)) { _previous = nil; return NO; }
    _owned = YES; return YES;
}
- (void)restore {
    if (!_owned) return;
    _owned = NO;
    if ([PLANKMicDeviceUID(PLANKMicDefaultInput()) isEqual:@PLANK_MIC_DEVICE_UID] && _previous) {
        AudioObjectID previous = PLANKMicDeviceForUID(_previous);
        if (previous && !PLANKMicSetDefaultInput(previous))
            NSLog(@"PLANK microphone previous input could not be restored");
    }
    _previous = nil;
}
- (void)dealloc { [self restore]; }
@end
