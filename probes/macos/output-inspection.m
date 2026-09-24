// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only installed-device inspection. No capture, routing, journal reads,
// permission requests or audio-service changes.
#import "../../apps/host/macos/audio-device/output-selection.h"
#import "../../apps/host/macos/audio-device/output-broker.h"
#include <sys/stat.h>
@interface PLANKMacOutputSelection (Inspection)
- (AudioObjectID)deviceForUID:(NSString *)uid;
- (BOOL)compatible:(AudioObjectID)device;
- (AudioObjectID)current:(unsigned)index;
@end
int main(void) { @autoreleasepool {
    PLANKMacOutputSelection *selection = [[PLANKMacOutputSelection alloc]
        initWithDirectory:@PLANK_OUTPUT_ROUTING_DIRECTORY];
    AudioObjectID device = [selection deviceForUID:@PLANK_OUTPUT_DEVICE_UID];
    struct stat metadata;
    BOOL privateDirectory = !lstat(PLANK_OUTPUT_ROUTING_DIRECTORY, &metadata) &&
        S_ISDIR(metadata.st_mode) && metadata.st_uid == 0 && (metadata.st_mode & 0777) == 0700;
    printf("output_present=%d format_compatible=%d default_playback=%d default_alerts=%d private_routing_directory=%d\n",
        device != 0, [selection compatible:device], device && [selection current:0] == device,
        device && [selection current:1] == device, privateDirectory);
} }
