// Native lifecycle fixture: no Installer session, OS changes or real FileVault command.
#import "installer-preflight.m"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "preflight check failed at %d\n", __LINE__); exit(1); } checks++; } while (0)
static int checks;

@interface PLANKTestRequirementsPane : PLANKRequirementsPane
@property(nonatomic, copy) NSString *program;
@property(nonatomic, copy) NSArray<NSString *> *arguments;
@property(nonatomic) NSTimeInterval timeout;
@end
@implementation PLANKTestRequirementsPane
- (NSTask *)newStatusTask {
    NSTask *task = [super newStatusTask];
    task.executableURL = [NSURL fileURLWithPath:self.program];
    task.arguments = self.arguments ?: @[];
    return task;
}
- (NSTimeInterval)checkTimeout { return self.timeout > 0 ? self.timeout : 2.0; }
@end

static void pump(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    } while (deadline.timeIntervalSinceNow > 0);
}

static void awaitResult(PLANKRequirementsPane *pane) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (pane.checkState == PLANKFileVaultChecking && deadline.timeIntervalSinceNow > 0) pump(0.01);
    CHECK(pane.checkState != PLANKFileVaultChecking);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        CHECK(fileVaultResult(NSTaskTerminationReasonExit, 1) == PLANKFileVaultOff);
        CHECK(fileVaultResult(NSTaskTerminationReasonExit, 0) == PLANKFileVaultOn);
        CHECK(fileVaultResult(NSTaskTerminationReasonExit, 2) == PLANKFileVaultOn);
        CHECK(fileVaultResult(NSTaskTerminationReasonExit, 11) == PLANKFileVaultUnavailable);
        CHECK(fileVaultResult(NSTaskTerminationReasonUncaughtSignal, 1) == PLANKFileVaultUnavailable);

        PLANKRequirementsSection *section = [PLANKRequirementsSection new];
        PLANKRequirementsPane *production = (PLANKRequirementsPane *)section.firstPane;
        CHECK(production == section.firstPane);
        CHECK(production.contentView == production.contentView);
        NSTask *command = [production newStatusTask];
        CHECK([command.executableURL.path isEqualToString:@"/usr/bin/fdesetup"]);
        CHECK([command.arguments isEqualToArray:@[@"isactive"]]);

        PLANKTestRequirementsPane *pane = [[PLANKTestRequirementsPane alloc] initWithSection:section];
        pane.program = @"/usr/bin/false"; // Exit 1 means FileVault is off.
        [pane willEnterPane:InstallerDirectionForward];
        CHECK(!pane.nextEnabled);
        CHECK(![pane shouldExitPane:InstallerDirectionForward]);
        CHECK([pane shouldExitPane:InstallerDirectionBackward]);
        awaitResult(pane);
        CHECK(pane.checkState == PLANKFileVaultOff && pane.nextEnabled);
        CHECK([pane shouldExitPane:InstallerDirectionForward]);

        pane.program = @"/usr/bin/true";
        [pane checkAgain:nil];
        CHECK(!pane.nextEnabled);
        awaitResult(pane);
        CHECK(pane.checkState == PLANKFileVaultOn && !pane.nextEnabled);
        CHECK([pane.explanation.stringValue containsString:@"System Settings"]);

        pane.program = @"/nonexistent-plank-installer-fixture";
        [pane checkAgain:nil];
        awaitResult(pane);
        CHECK(pane.checkState == PLANKFileVaultUnavailable && !pane.nextEnabled);
        CHECK(pane.checkButton.enabled);

        pane.program = @"/bin/sleep";
        pane.arguments = @[@"30"];
        pane.timeout = 0.05;
        [pane checkAgain:nil];
        NSTask *slow = pane.statusTask;
        awaitResult(pane);
        CHECK(pane.checkState == PLANKFileVaultUnavailable && !pane.nextEnabled);
        pump(0.05);
        CHECK(!slow.running);

        // A cancelled check's eventual exit cannot override the newer result.
        pane.timeout = 2.0;
        [pane checkAgain:nil];
        NSTask *retired = pane.statusTask;
        pane.program = @"/usr/bin/false";
        pane.arguments = @[];
        [pane checkAgain:nil];
        awaitResult(pane);
        CHECK(pane.checkState == PLANKFileVaultOff && pane.nextEnabled);
        pump(0.05);
        CHECK(!retired.running && pane.checkState == PLANKFileVaultOff);

        pane.program = @"/bin/sleep";
        pane.arguments = @[@"30"];
        [pane checkAgain:nil];
        NSTask *closing = pane.statusTask;
        [pane willExitPane:InstallerDirectionBackward];
        pump(0.05);
        CHECK(!closing.running && pane.statusTask == nil);
        CHECK(pane.checkState == PLANKFileVaultChecking && !pane.nextEnabled);
        [pane checkAgain:nil];
        CHECK(pane.statusTask == nil);
        printf("macos_installer_preflight=pass checks=%d real_filevault_changes=0\n", checks);
    }
    return 0;
}
