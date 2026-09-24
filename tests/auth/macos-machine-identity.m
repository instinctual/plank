// SPDX-License-Identifier: GPL-3.0-or-later
// Actual system LibreSSL signing path, entirely inside a private fixture.
// Include the implementation to exercise its private bounded process runner
// without adding a production executable override or a test-only public API.
#import "../../apps/host/macos/session/machine-identity.m"
#import <Security/Security.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "machine identity failed at line %d\n", __LINE__); exit(1); } } while (0)

static void run(NSString *directory, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/openssl"];
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory];
    task.arguments = arguments;
    task.standardInput = task.standardOutput = task.standardError = NSFileHandle.fileHandleWithNullDevice;
    CHECK([task launchAndReturnError:NULL]);
    [task waitUntilExit];
    CHECK(task.terminationStatus == 0);
}

static NSData *fixtureRead(NSString *directory, NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
    CHECK(data.length > 0);
    return data;
}

static NSTask *delayedTask(NSString *executable, NSString *delay) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[@"--delay", delay];
    task.standardInput = task.standardOutput = task.standardError = NSFileHandle.fileHandleWithNullDevice;
    return task;
}

static void deadlineTests(NSString *executable) {
    CHECK(PLANK_MAC_IDENTITY_CRYPTO_NS < PLANK_MAC_IDENTITY_REPLY_NS);
    CHECK(PLANK_MAC_IDENTITY_REPLY_NS < PLANK_MAC_IDENTITY_LINK_NS);
    // Reproduce cold-start latency beyond the former one-second helper cap.
    NSTask *slow = delayedTask(executable, @"1200000");
    CHECK(runCryptoTask(slow, clock_gettime_nsec_np(CLOCK_MONOTONIC) + PLANK_MAC_IDENTITY_CRYPTO_NS));
    CHECK(!slow.running && slow.terminationStatus == 0);

    // Successive children share the same absolute deadline; the second must
    // not obtain a fresh budget. A timed-out child is killed and reaped.
    uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    uint64_t deadline = start + 2 * NSEC_PER_SEC;
    CHECK(runCryptoTask(delayedTask(executable, @"1200000"), deadline));
    NSTask *stalled = delayedTask(executable, @"10000000");
    CHECK(!runCryptoTask(stalled, deadline));
    CHECK(!stalled.running && stalled.terminationReason == NSTaskTerminationReasonUncaughtSignal);
    CHECK(stalled.terminationStatus == SIGKILL);
    CHECK(kill(stalled.processIdentifier, 0) == -1 && errno == ESRCH);
    CHECK(clock_gettime_nsec_np(CLOCK_MONOTONIC) - start < 4 * NSEC_PER_SEC);

    NSTask *expired = delayedTask(executable, @"0");
    CHECK(!runCryptoTask(expired, clock_gettime_nsec_np(CLOCK_MONOTONIC)));
    CHECK(expired.processIdentifier == 0);
    // A helper error must remain a rejection, even with ample time remaining.
    NSTask *failure = delayedTask(executable, @"0");
    failure.arguments = @[@"--fail"];
    CHECK(!runCryptoTask(failure, clock_gettime_nsec_np(CLOCK_MONOTONIC) + PLANK_MAC_IDENTITY_CRYPTO_NS));
    CHECK(failure.terminationStatus == 7);
    puts("macos_identity_deadlines=pass");
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc == 3 && !strcmp(argv[1], "--delay")) { usleep((useconds_t)strtoul(argv[2], NULL, 10)); return 0; }
    if (argc == 2 && !strcmp(argv[1], "--fail")) return 7;
    CHECK(argc == 1);
    deadlineTests([NSString stringWithUTF8String:argv[0]]);
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *directory = [[NSTemporaryDirectory() stringByResolvingSymlinksInPath]
        stringByAppendingPathComponent:[@"plank-machine-identity-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    CHECK(mkdir(directory.fileSystemRepresentation, 0700) == 0);
    // Foundation can retain the /var alias for the runner's temporary path.
    // Exercise the production no-symlink walk with an actual canonical path.
    char *canonical = realpath(directory.fileSystemRepresentation, NULL);
    CHECK(canonical);
    directory = [NSString stringWithUTF8String:canonical];
    free(canonical);
    run(directory, @[@"req", @"-new", @"-x509", @"-newkey", @"rsa:3072", @"-nodes", @"-days", @"2",
        @"-sha256", @"-subj", @"/CN=PLANK Host Machine", @"-addext", @"subjectAltName=DNS:plank-host",
        @"-addext", @"basicConstraints=critical,CA:TRUE,pathlen:0", @"-addext", @"keyUsage=critical,digitalSignature,keyCertSign",
        @"-keyout", @"key.pem", @"-out", @"cert.pem"]);
    run(directory, @[@"x509", @"-in", @"cert.pem", @"-outform", @"DER", @"-out", @"cert.der"]);
    CHECK(!chmod([directory stringByAppendingPathComponent:@"cert.der"].fileSystemRepresentation, 0600));
    NSData *machineKey = fixtureRead(directory, @"key.pem"), *authority = fixtureRead(directory, @"cert.der");
    for (unsigned worker = 0; worker < 2; ++worker) {
        run(directory, @[@"req", @"-new", @"-newkey", @"rsa:3072", @"-nodes", @"-sha256",
            @"-subj", @"/CN=PLANK Host", @"-addext", @"basicConstraints=critical,CA:TRUE",
            @"-keyout", @"worker.key", @"-out", @"worker.csr"]);
        NSDictionary *issued = PLANKMacIssueWorkerIdentity(fixtureRead(directory, @"worker.csr"), directory);
        CHECK(issued.count == 3 && [issued[@"authority"] isEqual:authority]);
        CHECK([issued[@"certificate"] writeToFile:[directory stringByAppendingPathComponent:@"worker.pem"] atomically:YES]);
        run(directory, @[@"verify", @"-purpose", @"sslserver", @"-CAfile", @"cert.pem", @"worker.pem"]);
        SecCertificateRef root = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)authority);
        SecCertificateRef leaf = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)issued[@"der"]);
        CHECK(root && leaf);
        SecPolicyRef policy = SecPolicyCreateSSL(true, CFSTR("plank-host"));
        SecTrustRef trust = NULL;
        CHECK(SecTrustCreateWithCertificates((__bridge CFArrayRef)@[(__bridge id)leaf, (__bridge id)root], policy, &trust) == errSecSuccess);
        CHECK(SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)@[(__bridge id)root]) == errSecSuccess);
        CHECK(SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess);
        CHECK(SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess);
        CHECK(SecTrustEvaluateWithError(trust, NULL));
        CFRelease(trust); CFRelease(policy); CFRelease(root); CFRelease(leaf);
        CHECK([fixtureRead(directory, @"key.pem") isEqual:machineKey]);
        CHECK(!issued[@"key"] && !issued[@"path"]);
        NSArray *remaining = [files contentsOfDirectoryAtPath:directory error:NULL];
        for (NSString *name in remaining) CHECK(![name hasPrefix:@".certificate-"]);
    }
    CHECK(!PLANKMacIssueWorkerIdentity([@"not a request" dataUsingEncoding:NSUTF8StringEncoding], directory));
    CHECK(!PLANKMacIssueWorkerIdentity([NSMutableData dataWithLength:16385], directory));
    CHECK(!chmod(directory.fileSystemRepresentation, 0755));
    CHECK(!PLANKMacIssueWorkerIdentity(fixtureRead(directory, @"worker.csr"), directory));
    CHECK(!chmod(directory.fileSystemRepresentation, 0700));
    NSString *link = [directory stringByAppendingPathComponent:@"alias"];
    CHECK(!symlink(directory.fileSystemRepresentation, link.fileSystemRepresentation));
    CHECK(!PLANKMacIssueWorkerIdentity(fixtureRead(directory, @"worker.csr"), link));
    CHECK([files removeItemAtPath:directory error:NULL]);
    puts("macos_machine_identity=pass");
    return 0;
} }
