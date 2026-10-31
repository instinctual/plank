#import <AppKit/AppKit.h>
#import <InstallerPlugins/InstallerPlugins.h>
#include <stdio.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        [NSApplication sharedApplication];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *error = nil;
        if (!bundle || ![bundle loadAndReturnError:&error]) {
            fprintf(stderr, "Requirements bundle could not load (%ld)\n", (long)error.code);
            return 1;
        }
        Class type = bundle.principalClass;
        if (![type isSubclassOfClass:[InstallerSection class]]) return 1;
        InstallerSection *section = [type new];
        InstallerPane *pane = section.firstPane;
        if (![pane isKindOfClass:[InstallerPane class]] || !pane.contentView ||
            ![pane.title isEqualToString:@"PLANK Host Requirements"] ||
            [pane shouldExitPane:InstallerDirectionForward]) return 1;
        puts("macos_installer_bundle_load=pass installer_ui=not-performed");
    }
    return 0;
}
