// SPDX-License-Identifier: GPL-3.0-or-later
#import "permission-setup.h"
#import "audio-consent.h"
#import "../camera-device/camera-activation.h"
#import "../audio-device/output-format.h"
#import "../audio-device/microphone-selection.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

// Status controls are labels, not checkboxes: PLANK cannot grant OS permission.
@interface PLANKSetupRow : NSObject
@property(strong) NSTextField *status;
@property(strong) NSButton *action;
@end
@implementation PLANKSetupRow
@end

@interface PLANKPermissionSetup : NSWindowController <NSWindowDelegate>
@property(strong) NSMutableDictionary<NSString *, PLANKSetupRow *> *rows;
@property(strong) NSTextField *summary;
@property(strong) PLANKMacAudioConsent *audio;
@property BOOL closing, checkingCamera, activatingCamera, reconciledCamera;
@property PLANKCameraStatus cameraStatus;
- (instancetype)initWithVersion:(NSString *)version;
- (void)refresh;
- (void)requestPermissions;
@end

static NSTextField *label(NSString *text, CGFloat size, BOOL bold) {
    NSTextField *field = [NSTextField wrappingLabelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    return field;
}

@implementation PLANKPermissionSetup
- (instancetype)initWithVersion:(NSString *)version {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 650, 650)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:window];
    if (!self) return nil;
    _rows = [NSMutableDictionary dictionary];
    window.title = @"PLANK Host setup"; window.delegate = self; window.releasedWhenClosed = NO;
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading; stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor constant:-22]]];
    [stack addArrangedSubview:label(@"PLANK Host", 22, YES)];
    [stack addArrangedSubview:label([@"Version " stringByAppendingString:version], 11, NO)];
    _summary = label(@"Checking desktop permissions…", 13, YES);
    [stack addArrangedSubview:_summary];
    [stack addArrangedSubview:label(@"Desktop permissions", 13, YES)];
    [self addRows:@[
        @[@"screen", @"Screen recording", @"View the remote desktop.", @"Open Settings"],
        @[@"accessibility", @"Accessibility", @"Control the keyboard and pointer.", @"Open Settings"],
        @[@"events", @"Keyboard / mouse events", @"Send input to the desktop.", @"Open Settings"],
        @[@"audio", @"System audio", @"Approve audio recording in System Settings.", @"Open Settings"]]
        toStack:stack];
    [stack addArrangedSubview:label(@"Optional components", 13, YES)];
    [self addRows:@[
        @[@"output", @"PLANK Output", @"Stream application and alert sounds.", @""],
        @[@"microphone", @"PLANK Microphone", @"Receive the Client microphone.", @""],
        @[@"camera", @"PLANK Camera", @"Receive the Client webcam.", @"Enable Camera"]]
        toStack:stack];
    NSTextField *help = label(@"Allow permissions for PLANK Host, not the Client.\n"
        "Optional components do not block desktop video.\n"
        "This setup does not start a session or record application audio.", 12, NO);
    help.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:help];
    [help.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refresh)];
    NSButton *close = [NSButton buttonWithTitle:@"Close" target:window action:@selector(performClose:)];
    close.keyEquivalent = @"\r";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[refresh, close]];
    buttons.spacing = 12;
    [stack addArrangedSubview:buttons];
    // Fit actual text/control metrics rather than leaving an arbitrary blank area.
    [window.contentView layoutSubtreeIfNeeded];
    [window setContentSize:NSMakeSize(650, stack.fittingSize.height + 44)];
    [window center];
    return self;
}
- (void)addRows:(NSArray<NSArray<NSString *> *> *)specs toStack:(NSStackView *)stack {
    NSMutableArray *views = [NSMutableArray array];
    for (NSArray *spec in specs) {
        PLANKSetupRow *row = [PLANKSetupRow new];
        NSTextField *name = label(spec[1], 13, YES);
        NSTextField *detail = label(spec[2], 11, NO);
        detail.textColor = NSColor.secondaryLabelColor;
        NSStackView *description = [NSStackView stackViewWithViews:@[name, detail]];
        description.orientation = NSUserInterfaceLayoutOrientationVertical;
        description.alignment = NSLayoutAttributeLeading; description.spacing = 3;
        [name.widthAnchor constraintEqualToConstant:245].active = YES;
        [detail.widthAnchor constraintEqualToConstant:245].active = YES;
        row.status = label(@"— Checking", 12, NO);
        [row.status.widthAnchor constraintEqualToConstant:160].active = YES;
        row.action = [NSButton buttonWithTitle:spec[3] target:self action:@selector(rowAction:)];
        row.action.identifier = spec[0]; row.action.hidden = ![spec[3] length];
        row.action.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", spec[1], spec[3]];
        row.action.enabled = ![spec[0] isEqualToString:@"camera"];
        _rows[spec[0]] = row;
        [views addObject:@[description, row.status, [spec[3] length] ? row.action : NSGridCell.emptyContentView]];
    }
    NSGridView *grid = [NSGridView gridViewWithViews:views];
    grid.rowSpacing = 16; grid.columnSpacing = 12;
    grid.yPlacement = NSGridCellPlacementCenter;
    [grid columnAtIndex:0].width = 245;
    [grid columnAtIndex:1].width = 160;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementLeading;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
    [grid columnAtIndex:2].xPlacement = NSGridCellPlacementTrailing;
    [stack addArrangedSubview:grid];
    [grid.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}
- (void)setRow:(NSString *)key text:(NSString *)text verified:(BOOL)verified required:(BOOL)required {
    PLANKSetupRow *row = _rows[key];
    row.status.stringValue = [NSString stringWithFormat:@"%@ %@", verified ? @"✓" : required ? @"!" : @"—", text];
    row.status.textColor = verified ? NSColor.systemGreenColor : required ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    row.status.accessibilityLabel = text;
}
- (void)refresh {
    if (_closing) return;
    BOOL screen = CGPreflightScreenCaptureAccess(), access = AXIsProcessTrusted(), events = CGPreflightPostEventAccess();
    [self setRow:@"screen" text:screen ? @"Allowed" : @"Required" verified:screen required:!screen];
    [self setRow:@"accessibility" text:access ? @"Allowed" : @"Required" verified:access required:!access];
    [self setRow:@"events" text:events ? @"Allowed" : @"Required" verified:events required:!events];
    _summary.stringValue = screen && access && events ? @"Desktop permissions are ready" : @"Allow the required desktop permissions below";
    // An empty tap starting is not proof of TCC audio consent. Never show a
    // green check based on the tap API's return value or Screen Recording alone.
    if (!_audio) [self setRow:@"audio" text:@"Check in Settings" verified:NO required:NO];
    for (NSString *key in @[@"output", @"microphone"]) {
        NSString *uid = [key isEqualToString:@"output"] ? @PLANK_OUTPUT_DEVICE_UID : @PLANK_MIC_DEVICE_UID;
        BOOL available = PLANKMicDeviceForUID(uid) != kAudioObjectUnknown;
        [self setRow:key text:available ? @"Loaded" : @"Not loaded" verified:available required:NO];
        _rows[key].status.toolTip = @"If installed but unavailable, restart the Mac to load the audio component.";
    }
    if (!_checkingCamera && !_activatingCamera) {
        _checkingCamera = YES;
        _rows[@"camera"].action.enabled = NO;
        __weak typeof(self) weakSelf = self;
        PLANKMacCheckCameraExtension(^(PLANKCameraStatus state) {
            PLANKPermissionSetup *owner = weakSelf;
            if (!owner || owner.closing) return;
            owner.checkingCamera = NO;
            owner.cameraStatus = state;
            NSString *text = state == PLANKCameraEnabled ? @"Enabled" :
                state == PLANKCameraDisabled ? @"Not enabled" :
                state == PLANKCameraAwaitingApproval ? @"Approval needed" :
                state == PLANKCameraRemoving ? @"Removal pending" : @"Could not check";
            [owner setRow:@"camera" text:text verified:state == PLANKCameraEnabled required:NO];
            owner.rows[@"camera"].action.enabled = YES;
            NSString *action = state == PLANKCameraDisabled || state == PLANKCameraUnknown ? @"Enable Camera" : @"Open Settings";
            owner.rows[@"camera"].action.title = action;
            owner.rows[@"camera"].action.accessibilityLabel = [@"PLANK Camera: " stringByAppendingString:action];
            if (state == PLANKCameraEnabled && !owner.reconciledCamera) {
                owner.reconciledCamera = YES;
                [owner activateCamera]; // Keep an already-approved extension current after upgrade.
            }
        });
    }
    if (screen && access && events && !_audio) {
        _audio = [PLANKMacAudioConsent new];
        [self setRow:@"audio" text:@"Requesting consent…" verified:NO required:NO];
        __weak typeof(self) weakSelf = self;
        [_audio startWithCompletion:^(BOOL started) {
            PLANKPermissionSetup *owner = weakSelf;
            if (owner && !owner.closing)
                [owner setRow:@"audio" text:started ? @"Check in Settings" : @"Setup unavailable" verified:NO required:NO];
        }];
    }
}
- (void)requestPermissions {
    if (_closing) return;
    if (!CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    if (!AXIsProcessTrusted()) {
        NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
    if (!CGPreflightPostEventAccess()) CGRequestPostEventAccess();
    [self refresh];
}
- (void)activateCamera {
    if (_closing || _checkingCamera || _activatingCamera) return;
    _reconciledCamera = YES;
    _activatingCamera = YES;
    _rows[@"camera"].action.enabled = NO;
    __weak typeof(self) weakSelf = self;
    PLANKMacRequestCameraExtension(YES, ^(BOOL success) {
        (void)success;
        PLANKPermissionSetup *owner = weakSelf;
        if (!owner || owner.closing) return;
        owner.activatingCamera = NO;
        [owner refresh];
    });
}
- (void)rowAction:(NSButton *)sender {
    if (_closing) return;
    if ([sender.identifier isEqualToString:@"camera"]) {
        if (_cameraStatus == PLANKCameraDisabled || _cameraStatus == PLANKCameraUnknown) [self activateCamera];
        else if (![NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.LoginItems-Settings.extension"]])
            [self setRow:@"camera" text:@"Open Settings manually" verified:NO required:NO];
        return;
    }
    NSString *pane = [sender.identifier isEqualToString:@"screen"] || [sender.identifier isEqualToString:@"audio"] ?
        @"Privacy_ScreenCapture" : @"Privacy_Accessibility";
    NSURL *url = [NSURL URLWithString:[@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:pane]];
    if (![NSWorkspace.sharedWorkspace openURL:url]) {
        [self setRow:sender.identifier text:@"Open Settings manually" verified:NO required:NO];
    }
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    _closing = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (!_audio) { [NSApp terminate:nil]; return; }
    [_audio stopWithCompletion:^{ [NSApp terminate:nil]; }];
    // HAL may still be waiting for consent. Closing this setup-only process
    // must not hang indefinitely; OS teardown owns any remaining private tap.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
- (void)applicationBecameActive:(NSNotification *)notification { (void)notification; [self refresh]; }
@end

void PLANKMacShowPermissionSetup(NSString *version) {
    dispatch_assert_queue(dispatch_get_main_queue());
    static PLANKPermissionSetup *setup;
    if (setup) { [setup showWindow:nil]; return; }
    setup = [[PLANKPermissionSetup alloc] initWithVersion:version];
    [NSNotificationCenter.defaultCenter addObserver:setup selector:@selector(applicationBecameActive:)
        name:NSApplicationDidBecomeActiveNotification object:nil];
    [setup showWindow:nil]; [NSApp activate];
    [setup refresh];
    dispatch_async(dispatch_get_main_queue(), ^{ [setup requestPermissions]; });
}
