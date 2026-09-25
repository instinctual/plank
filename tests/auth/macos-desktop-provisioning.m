// SPDX-License-Identifier: GPL-3.0-or-later
// Non-root filesystem/crypto qualification; no account, launchd, TCC or GUI work.
#import "desktop-provisioning.h"
#import "host-configuration.h"
#import <Security/Security.h>
#include <sys/stat.h>
#include <unistd.h>
#include <assert.h>

int main(void) {
    @autoreleasepool {
        assert(getuid() && getuid() == geteuid());
        umask(077);
        char *canonical = realpath(NSTemporaryDirectory().fileSystemRepresentation, NULL);
        assert(canonical);
        NSString *root = [[NSString stringWithUTF8String:canonical]
            stringByAppendingPathComponent:[@"plank-provisioning-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        free(canonical);
        NSFileManager *fm = NSFileManager.defaultManager;
        assert([fm createDirectoryAtPath:root withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL]);
        NSString *first = [root stringByAppendingPathComponent:@"one/Host"];
        NSString *second = [root stringByAppendingPathComponent:@"two/Host"];
        assert(PLANKMacPrepareDesktopIdentity(first));
        NSData *key = [NSData dataWithContentsOfFile:[first stringByAppendingPathComponent:@"key.der"]];
        assert(key.length);
        assert(PLANKMacPrepareDesktopIdentity(first));
        assert([key isEqual:[NSData dataWithContentsOfFile:[first stringByAppendingPathComponent:@"key.der"]]]);
        assert(PLANKMacPrepareDesktopIdentity(second));
        assert(![key isEqual:[NSData dataWithContentsOfFile:[second stringByAppendingPathComponent:@"key.der"]]]);
        NSData *cert = [NSData dataWithContentsOfFile:[first stringByAppendingPathComponent:@"cert.der"]];
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)cert);
        NSDictionary *attributes = @{(__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeRSA,
            (__bridge id)kSecAttrKeyClass:(__bridge id)kSecAttrKeyClassPrivate};
        SecKeyRef private = SecKeyCreateWithData((__bridge CFDataRef)key, (__bridge CFDictionaryRef)attributes, NULL);
        SecIdentityRef identity = certificate && private ? SecIdentityCreate(NULL, certificate, private) : NULL;
        assert(identity); CFRelease(identity); CFRelease(private); CFRelease(certificate);
        assert(!PLANKMacPrepareDesktopIdentity([root stringByAppendingPathComponent:@"one"])); // Partial directory.
        NSString *link = [root stringByAppendingPathComponent:@"link"];
        assert(!symlink(first.fileSystemRepresentation, link.fileSystemRepresentation));
        assert(!PLANKMacPrepareDesktopIdentity(link));
        assert(!PLANKMacPrepareDesktopIdentity([link stringByAppendingPathComponent:@"nested/Host"]));
        NSString *keyPath = [first stringByAppendingPathComponent:@"key.der"];
        assert(!chmod(keyPath.fileSystemRepresentation, 0644));
        assert(!PLANKMacPrepareDesktopIdentity(first));
        assert(!chmod(keyPath.fileSystemRepresentation, 0600));
        NSString *public = [root stringByAppendingPathComponent:@"public"];
        assert([fm createDirectoryAtPath:public withIntermediateDirectories:NO attributes:nil error:NULL]);
        assert(!chmod(public.fileSystemRepresentation, 0755));
        NSString *path = [public stringByAppendingPathComponent:@"identity.plist"];
        NSMutableDictionary *config = [@{@"UUID":NSUUID.UUID.UUIDString} mutableCopy];
        NSString *ini = [public stringByAppendingPathComponent:@"host.conf"];
        assert([@"[network]\nport = 28989\n" writeToFile:ini atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        assert(!chmod(ini.fileSystemRepresentation, 0644));
        void (^write)(void) = ^{
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:config format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
            assert([data writeToFile:path atomically:YES]); assert(!chmod(path.fileSystemRepresentation, 0644));
        };
        write();
        NSDictionary *automatic = PLANKMacReadHostConfiguration(public, public, getuid(), NO);
        assert(automatic);
        char hostname[256] = {0};
        assert(!gethostname(hostname, sizeof(hostname)));
        assert([automatic[@"Name"] isEqual:[NSString stringWithUTF8String:hostname]]);
        assert([automatic[@"UUID"] isEqual:config[@"UUID"]]);
        assert(!PLANKMacReadHostConfiguration(public, public, 0, NO));
        config[@"UUID"] = @"invalid"; write();
        assert(!PLANKMacReadHostConfiguration(public, public, getuid(), NO));
        config[@"UUID"] = NSUUID.UUID.UUIDString; write();
        assert(!chmod(path.fileSystemRepresentation, 0666));
        assert(!PLANKMacReadHostConfiguration(public, public, getuid(), NO));
        assert([fm removeItemAtPath:path error:NULL]);
        assert(!symlink(keyPath.fileSystemRepresentation, path.fileSystemRepresentation));
        assert(!PLANKMacReadHostConfiguration(public, public, getuid(), NO));
        assert([fm removeItemAtPath:root error:NULL]);
        puts("desktop_provisioning_pass=1 distinct_keys=1 preserve_keys=1 unsafe_paths_denied=1 permissions_unchanged=1");
    }
    return 0;
}
