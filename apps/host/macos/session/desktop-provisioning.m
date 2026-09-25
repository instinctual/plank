// SPDX-License-Identifier: GPL-3.0-or-later
#import "desktop-provisioning.h"
#import "host-configuration.h"
#include <fcntl.h>
#include <pwd.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

// Walk every component with openat: neither HOME/environment overrides nor
// symlinked intermediate directories select the destination of product writes.
static int openDirectory(NSString *path, BOOL create) {
    if (!path.isAbsolutePath) return -1;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    for (NSString *part in path.pathComponents) {
        if ([part isEqual:@"/"]) continue;
        if ([part isEqual:@"."] || [part isEqual:@".."] || !part.length) { close(fd); return -1; }
        if (create && mkdirat(fd, part.fileSystemRepresentation, 0700) && errno != EEXIST) {
            close(fd); return -1;
        }
        int next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = next;
        if (fd < 0) return -1;
    }
    return fd;
}

static BOOL ownedDirectory(int fd, uid_t owner, mode_t mode) {
    struct stat st;
    return fd >= 0 && !fstat(fd, &st) && st.st_uid == owner && (st.st_mode & 0777) == mode;
}

static BOOL completeIdentity(int fd) {
    if (!ownedDirectory(fd, geteuid(), 0700)) return NO;
    for (NSString *name in @[@"cert.pem", @"key.pem", @"cert.der", @"key.der"]) {
        // Validate metadata without retaining private-key copies in Foundation.
        int file = openat(fd, name.UTF8String, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        struct stat st;
        BOOL ok = file >= 0 && !fstat(file, &st) && S_ISREG(st.st_mode) &&
            st.st_uid == geteuid() && st.st_nlink == 1 && (st.st_mode & 0777) == 0600 &&
            st.st_size > 0 && st.st_size <= 32768;
        if (file >= 0) close(file);
        if (!ok) return NO;
    }
    return YES;
}

static BOOL openssl(NSString *stage, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/openssl"];
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:stage isDirectory:YES];
    task.environment = @{@"PATH": @"/usr/bin:/bin"};
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *ended) { (void)ended; dispatch_semaphore_signal(finished); };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"PLANK Host identity preparation could not launch crypto operation (code=%ld)", (long)error.code);
        return NO;
    }
    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC))) {
        [task terminate];
        // Only this exact freshly spawned crypto child, never a Host/service.
        if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC))) {
            kill(task.processIdentifier, SIGKILL);
            [task waitUntilExit];
        }
        return NO;
    }
    if (task.terminationStatus) NSLog(@"PLANK Host identity crypto operation %@ failed (status=%d)", arguments.firstObject, task.terminationStatus);
    return task.terminationStatus == 0;
}

BOOL PLANKMacPrepareDesktopIdentity(NSString *directory) {
    if (!getuid() || getuid() != geteuid()) return NO;
    int parent = openDirectory(directory.stringByDeletingLastPathComponent, YES);
    if (ownedDirectory(parent, geteuid(), 0755) && fchmod(parent, 0700)) { close(parent); return NO; }
    if (!ownedDirectory(parent, geteuid(), 0700)) { if (parent >= 0) close(parent); return NO; }
    const char *name = directory.lastPathComponent.fileSystemRepresentation;
    int existing = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (existing >= 0) {
        BOOL ok = completeIdentity(existing); close(existing); close(parent); return ok;
    }
    if (errno != ENOENT) { close(parent); return NO; }
    NSString *stageName = [@".identity-" stringByAppendingString:NSUUID.UUID.UUIDString];
    if (mkdirat(parent, stageName.UTF8String, 0700)) { close(parent); return NO; }
    NSString *stage = [directory.stringByDeletingLastPathComponent stringByAppendingPathComponent:stageName];
    BOOL ok = openssl(stage, @[@"req", @"-x509", @"-newkey", @"rsa:3072", @"-nodes", @"-sha256",
        @"-days", @"365", @"-subj", @"/CN=PLANK Host", @"-addext", @"subjectAltName=DNS:plank-host",
        @"-keyout", @"initial.pem", @"-out", @"cert.pem"]);
    if (ok) ok = openssl(stage, @[@"rsa", @"-in", @"initial.pem", @"-out", @"key.pem"]);
    if (ok) ok = openssl(stage, @[@"rsa", @"-in", @"key.pem", @"-outform", @"DER", @"-out", @"key.der"]);
    if (ok) ok = openssl(stage, @[@"x509", @"-in", @"cert.pem", @"-outform", @"DER", @"-out", @"cert.der"]);
    int staged = openat(parent, stageName.UTF8String, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (staged >= 0) {
        unlinkat(staged, "initial.pem", 0);
        for (NSString *file in @[@"cert.pem", @"key.pem", @"cert.der", @"key.der"]) {
            int fd = openat(staged, file.UTF8String, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            if (fd < 0 || fchmod(fd, 0600) || fsync(fd)) ok = NO;
            if (fd >= 0) close(fd);
        }
        ok = ok && completeIdentity(staged);
    } else ok = NO;
    // Publish all four files as one directory; never overwrite an existing key.
    if (ok) ok = !renameatx_np(parent, stageName.UTF8String, parent, name, RENAME_EXCL);
    if (!ok && staged >= 0) {
        for (NSString *file in @[@"cert.pem", @"key.pem", @"cert.der", @"key.der"])
            unlinkat(staged, file.UTF8String, 0);
        unlinkat(parent, stageName.UTF8String, AT_REMOVEDIR);
    }
    if (staged >= 0) close(staged);
    close(parent);
    return ok;
}

BOOL PLANKMacPrepareDesktop(NSString **directory, NSDictionary **configuration) {
    if (!getuid() || getuid() != geteuid()) return NO;
    struct passwd *account = getpwuid(getuid());
    if (!account || !account->pw_dir) return NO;
    NSString *home = [NSString stringWithUTF8String:account->pw_dir];
    // Logs are opened as the user, not by root launchd following a home path.
    int logs = openDirectory([home stringByAppendingPathComponent:@"Library/Logs/PLANK"], YES);
    if (!ownedDirectory(logs, geteuid(), 0700)) { if (logs >= 0) close(logs); return NO; }
    int log = openat(logs, "host-desktop.log", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
    close(logs);
    struct stat st;
    BOOL valid = log >= 0 && !fstat(log, &st) && S_ISREG(st.st_mode) && st.st_uid == geteuid() &&
        st.st_nlink == 1 && (st.st_mode & 0777) == 0600;
    if (!valid) { if (log >= 0) close(log); return NO; }
    if (dup2(log, STDOUT_FILENO) < 0 || dup2(log, STDERR_FILENO) < 0) { close(log); return NO; }
    close(log);
    *configuration = PLANKMacReadHostConfiguration(@"/private/etc/plank", @"/Library/Application Support/PLANK", 0, NO);
    if (!*configuration) return NO;
    *directory = [home stringByAppendingPathComponent:@"Library/Application Support/PLANK/Host"];
    return PLANKMacPrepareDesktopIdentity(*directory);
}
