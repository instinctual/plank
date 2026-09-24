// SPDX-License-Identifier: GPL-3.0-or-later
// Real recovery journal and routing policy; HAL calls replaced by a fixture.
#import "../../apps/host/macos/audio-device/output-selection.m"
#include <assert.h>
#include <stdio.h>

@interface TestSelection : PLANKMacOutputSelection
@property unsigned writes;
@property int failIndex;
@property BOOL originalMissing, unavailable, incompatible, failRestore;
@end
static AudioObjectID selected[] = {10, 11};
@implementation TestSelection
- (AudioObjectID)deviceForUID:(NSString *)uid {
    if ([uid isEqual:@PLANK_OUTPUT_DEVICE_UID]) return 20;
    return [uid intValue];
}
- (NSString *)uidForDevice:(AudioObjectID)device {
    return device == 20 ? @PLANK_OUTPUT_DEVICE_UID : device ? [@(device) stringValue] : nil;
}
- (AudioObjectID)current:(unsigned)index { return _unavailable ? 0 : selected[index]; }
- (BOOL)setCurrent:(AudioObjectID)device index:(unsigned)index {
    if ((int)index == _failIndex || (_failRestore && device != 20)) return NO;
    selected[index] = device; _writes++; return YES;
}
- (BOOL)compatible:(AudioObjectID)device { return device == 20 && !_incompatible; }
- (BOOL)usable:(AudioObjectID)device { return device && !(_originalMissing && (device == 10 || device == 11)); }
- (AudioObjectID)builtInFallback { return 40; }
@end
static TestSelection *make(NSString *path) {
    TestSelection *selection = [[TestSelection alloc] initWithDirectory:path]; selection.failIndex = -1; return selection;
}
int main(void) { @autoreleasepool {
    char pattern[] = "/tmp/plank-output-selection.XXXXXX";
    assert(mkdtemp(pattern));
    NSString *path = @(pattern), *journal = [path stringByAppendingPathComponent:@"output-route.plist"];
    TestSelection *owner = make(path);
    assert([owner recover]);
    assert([owner select] && selected[0] == 20 && selected[1] == 20);
    struct stat st; assert(!lstat(journal.fileSystemRepresentation, &st) && (st.st_mode & 0777) == 0600);
    assert([owner restore] && selected[0] == 10 && selected[1] == 11);
    assert(access(journal.fileSystemRepresentation, F_OK));
    assert([owner restore] && owner.writes == 4);
    // Only restore defaults still owned by this route. Independent alert override.
    assert([owner select]); selected[1] = 30;
    assert([owner restore] && selected[0] == 10 && selected[1] == 30);
    selected[1] = 11;
    // Crash recovery uses stable UIDs from disk, not the old object's memory.
    assert([owner select]); owner = nil; owner = make(path);
    assert([owner recover] && selected[0] == 10 && selected[1] == 11);
    assert([owner select]); owner.originalMissing = YES;
    assert([owner restore] && selected[0] == 40 && selected[1] == 40);
    owner.originalMissing = NO; selected[0] = 10; selected[1] = 11;
    // Failed second switch rolls back the first; retained failure is retryable.
    owner.failIndex = 1; assert(![owner select]);
    assert(selected[0] == 10 && selected[1] == 11); owner.failIndex = -1;
    assert([owner select]); owner.failRestore = YES;
    assert(![owner restore] && !access(journal.fileSystemRepresentation, F_OK));
    owner.failRestore = NO; assert([owner recover]);
    assert([owner select]); owner.unavailable = YES; assert(![owner restore]);
    owner.unavailable = NO; assert([owner restore]);
    owner.incompatible = YES; assert(![owner select] && selected[0] == 10); owner.incompatible = NO;
    // A user-selected PLANK device is not ours to undo.
    selected[0] = 20; assert([owner select]); assert([owner restore] && selected[0] == 20 && selected[1] == 11);
    selected[0] = 10;
    // Unsafe or corrupted journals must prevent routing changes.
    assert(symlink("/dev/null", journal.fileSystemRepresentation) == 0);
    unsigned writes = owner.writes;
    assert(![owner select] && owner.writes == writes); unlink(journal.fileSystemRepresentation);
    NSDictionary *invalid = @{@"output": @PLANK_OUTPUT_DEVICE_UID};
    NSData *bytes = [NSPropertyListSerialization dataWithPropertyList:invalid format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    assert([bytes writeToFile:journal options:0 error:NULL]); chmod(journal.fileSystemRepresentation, 0600);
    assert(![owner recover] && owner.writes == writes); unlink(journal.fileSystemRepresentation);
    chmod(path.fileSystemRepresentation, 0755); assert(![owner select] && owner.writes == writes);
    chmod(path.fileSystemRepresentation, 0700); assert([owner select]); assert([owner restore]);
    assert(rmdir(pattern) == 0);
    puts("output_selection_restore_override_crash_unplug_partial_failure_journal_security=pass");
} }
