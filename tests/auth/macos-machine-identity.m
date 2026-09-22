// SPDX-License-Identifier: GPL-3.0-or-later
// Actual system LibreSSL signing path, entirely inside a private fixture.
#import "machine-identity.h"
#import <Security/Security.h>
#include <sys/stat.h>
#include <unistd.h>

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

static NSData *read(NSString *directory, NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
    CHECK(data.length > 0);
    return data;
}

int main(void) { @autoreleasepool {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *directory = [[NSTemporaryDirectory() stringByResolvingSymlinksInPath]
        stringByAppendingPathComponent:[@"plank-machine-identity-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    CHECK(mkdir(directory.fileSystemRepresentation, 0700) == 0);
    run(directory, @[@"req", @"-new", @"-x509", @"-newkey", @"rsa:3072", @"-nodes", @"-days", @"2",
        @"-sha256", @"-subj", @"/CN=PLANK Host Machine", @"-addext", @"subjectAltName=DNS:plank-host",
        @"-addext", @"basicConstraints=critical,CA:TRUE,pathlen:0", @"-addext", @"keyUsage=critical,digitalSignature,keyCertSign",
        @"-keyout", @"key.pem", @"-out", @"cert.pem"]);
    run(directory, @[@"x509", @"-in", @"cert.pem", @"-outform", @"DER", @"-out", @"cert.der"]);
    CHECK(!chmod([directory stringByAppendingPathComponent:@"cert.der"].fileSystemRepresentation, 0600));
    NSData *machineKey = read(directory, @"key.pem"), *authority = read(directory, @"cert.der");
    for (unsigned worker = 0; worker < 2; ++worker) {
        run(directory, @[@"req", @"-new", @"-newkey", @"rsa:3072", @"-nodes", @"-sha256",
            @"-subj", @"/CN=PLANK Host", @"-addext", @"basicConstraints=critical,CA:TRUE",
            @"-keyout", @"worker.key", @"-out", @"worker.csr"]);
        NSDictionary *issued = PLANKMacIssueWorkerIdentity(read(directory, @"worker.csr"), directory);
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
        CHECK([read(directory, @"key.pem") isEqual:machineKey]);
        CHECK(!issued[@"key"] && !issued[@"path"]);
        NSArray *remaining = [files contentsOfDirectoryAtPath:directory error:NULL];
        for (NSString *name in remaining) CHECK(![name hasPrefix:@".certificate-"]);
    }
    CHECK(!PLANKMacIssueWorkerIdentity([@"not a request" dataUsingEncoding:NSUTF8StringEncoding], directory));
    CHECK(!PLANKMacIssueWorkerIdentity([NSMutableData dataWithLength:16385], directory));
    CHECK(!chmod(directory.fileSystemRepresentation, 0755));
    CHECK(!PLANKMacIssueWorkerIdentity(read(directory, @"worker.csr"), directory));
    CHECK(!chmod(directory.fileSystemRepresentation, 0700));
    NSString *link = [directory stringByAppendingPathComponent:@"alias"];
    CHECK(!symlink(directory.fileSystemRepresentation, link.fileSystemRepresentation));
    CHECK(!PLANKMacIssueWorkerIdentity(read(directory, @"worker.csr"), link));
    CHECK([files removeItemAtPath:directory error:NULL]);
    puts("macos_machine_identity=pass");
    return 0;
} }
