// A temporary Installer pane, never an installed helper or privileged service.
#import <AppKit/AppKit.h>
#import <InstallerPlugins/InstallerPlugins.h>

typedef NS_ENUM(NSInteger, PLANKFileVaultState) {
    PLANKFileVaultChecking,
    PLANKFileVaultOff,
    PLANKFileVaultOn,
    PLANKFileVaultUnavailable,
};

static PLANKFileVaultState fileVaultResult(NSTaskTerminationReason reason, int status) {
    if (reason != NSTaskTerminationReasonExit) return PLANKFileVaultUnavailable;
    // fdesetup isactive: 1 = off, 0 = on, 2 = on and busy.
    if (status == 1) return PLANKFileVaultOff;
    if (status == 0 || status == 2) return PLANKFileVaultOn;
    return PLANKFileVaultUnavailable;
}

static void cancelFileVaultTask(NSTask *task) {
    task.terminationHandler = nil;
    @try {
        if (task.running) [task terminate];
    } @catch (NSException *exception) {
        // The child may have exited between the running check and terminate.
        (void)exception;
    }
}

@interface PLANKRequirementsPane : InstallerPane
@property(nonatomic, strong) NSView *requirementsView;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *explanation;
@property(nonatomic, strong) NSButton *checkButton;
@property(nonatomic, strong) NSTask *statusTask;
@property(nonatomic) PLANKFileVaultState checkState;
@property(nonatomic) BOOL paneActive;
@end

@implementation PLANKRequirementsPane
- (NSString *)title { return @"PLANK Host Requirements"; }

- (NSView *)contentView {
    if (!_requirementsView) {
        _requirementsView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300)];
        NSTextField *heading = [NSTextField labelWithString:@"Check this Mac before installing"];
        heading.font = [NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];
        _statusLabel = [NSTextField labelWithString:@"Checking FileVault…"];
        _statusLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
        _explanation = [NSTextField wrappingLabelWithString:@"Checking this Mac’s disk-unlock settings."];
        _checkButton = [NSButton buttonWithTitle:@"Check Again" target:self action:@selector(checkAgain:)];
        NSStackView *stack = [NSStackView stackViewWithViews:@[heading, _statusLabel, _explanation, _checkButton]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 16;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_requirementsView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:_requirementsView.leadingAnchor constant:20],
            [stack.trailingAnchor constraintEqualToAnchor:_requirementsView.trailingAnchor constant:-20],
            [stack.topAnchor constraintEqualToAnchor:_requirementsView.topAnchor constant:20],
            [_explanation.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        ]];
        self.initialKeyView = _checkButton;
        self.firstKeyView = _checkButton;
        self.lastKeyView = _checkButton;
    }
    return _requirementsView;
}

- (void)showState:(PLANKFileVaultState)state {
    _checkState = state;
    self.nextEnabled = state == PLANKFileVaultOff;
    _checkButton.enabled = state != PLANKFileVaultChecking;
    switch (state) {
        case PLANKFileVaultChecking:
            _statusLabel.stringValue = @"Checking FileVault…";
            _explanation.stringValue = @"Checking this Mac’s disk-unlock settings.";
            break;
        case PLANKFileVaultOff:
            _statusLabel.stringValue = @"FileVault is off — ready to install";
            _explanation.stringValue = @"Click Continue to install PLANK Host.";
            break;
        case PLANKFileVaultOn:
            _statusLabel.stringValue = @"Turn off FileVault before installing";
            _explanation.stringValue = @"PLANK cannot provide remote access to the FileVault unlock screen after a restart.\n\nOpen System Settings > Privacy & Security > FileVault and turn FileVault off.\n\nWait for it to finish, then click Check Again. PLANK does not change your FileVault settings.";
            break;
        case PLANKFileVaultUnavailable:
            _statusLabel.stringValue = @"Unable to check FileVault";
            _explanation.stringValue = @"The system check did not complete successfully. Click Check Again to retry.\n\nIf it still fails, ask your administrator to verify FileVault in System Settings > Privacy & Security > FileVault before reopening this installer.";
            break;
    }
}

- (NSTask *)newStatusTask {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/fdesetup"];
    task.arguments = @[@"isactive"];
    task.environment = @{@"PATH": @"/usr/bin:/bin:/usr/sbin:/sbin", @"LANG": @"C", @"LC_ALL": @"C"};
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    return task;
}

- (NSTimeInterval)checkTimeout { return 5.0; }

- (void)checkAgain:(id)sender {
    (void)sender;
    if (!_paneActive) return;
    cancelFileVaultTask(_statusTask);
    [self showState:PLANKFileVaultChecking];
    NSTask *task = [self newStatusTask];
    _statusTask = task;
    __weak PLANKRequirementsPane *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        PLANKFileVaultState result = fileVaultResult(finished.terminationReason, finished.terminationStatus);
        dispatch_async(dispatch_get_main_queue(), ^{
            PLANKRequirementsPane *pane = weakSelf;
            if (!pane || !pane.paneActive || pane.statusTask != finished) return;
            finished.terminationHandler = nil;
            pane.statusTask = nil;
            [pane showState:result];
        });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        task.terminationHandler = nil;
        _statusTask = nil;
        [self showState:PLANKFileVaultUnavailable];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([self checkTimeout] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PLANKRequirementsPane *pane = weakSelf;
        if (!pane || !pane.paneActive || pane.statusTask != task) return;
        // Never block Installer waiting on an external process.
        pane.statusTask = nil;
        cancelFileVaultTask(task);
        [pane showState:PLANKFileVaultUnavailable];
    });
}

- (void)willEnterPane:(InstallerSectionDirection)direction {
    (void)direction;
    (void)self.contentView;
    _paneActive = YES;
    [self checkAgain:nil];
}

- (BOOL)shouldExitPane:(InstallerSectionDirection)direction {
    return direction == InstallerDirectionBackward || _checkState == PLANKFileVaultOff;
}

- (void)willExitPane:(InstallerSectionDirection)direction {
    (void)direction;
    _paneActive = NO;
    cancelFileVaultTask(_statusTask);
    _statusTask = nil;
}

- (void)dealloc { cancelFileVaultTask(_statusTask); }
@end

@interface PLANKRequirementsSection : InstallerSection
@property(nonatomic, strong) PLANKRequirementsPane *requirementsPane;
@end

@implementation PLANKRequirementsSection
- (InstallerPane *)firstPane {
    if (!_requirementsPane) _requirementsPane = [[PLANKRequirementsPane alloc] initWithSection:self];
    return _requirementsPane;
}
@end
