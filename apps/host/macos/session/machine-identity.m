// SPDX-License-Identifier: GPL-3.0-or-later
#import "machine-identity.h"
#import <Security/Security.h>
#import <xpc/xpc.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL privateDirectory(NSString *path) {
    // Walk every component without following symlinks, including user homes.
    if (!path.isAbsolutePath) return NO;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    for (NSString *part in path.pathComponents) {
        if ([part isEqual:@"/"]) continue;
        if ([part isEqual:@"."] || [part isEqual:@".."]) { close(fd); return NO; }
        int next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = next;
        if (fd < 0) return NO;
    }
    struct stat st;
    BOOL valid = fd >= 0 && !fstat(fd, &st) && st.st_uid == geteuid() && (st.st_mode & 0777) == 0700;
    if (fd >= 0) close(fd);
    return valid;
}

static NSData *readPublicResult(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat st;
    if (fd < 0) return nil;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1 ||
        (st.st_mode & 0077) || st.st_size <= 0 || st.st_size > 16384) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t count = 0;
    while (count < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + count, data.length - count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        count += (size_t)n;
    }
    close(fd);
    return count == data.length ? data : nil;
}

static BOOL crypto(NSString *directory, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/openssl"];
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
    task.arguments = arguments;
    task.environment = @{@"PATH": @"/usr/bin:/bin"};
    task.standardInput = task.standardOutput = task.standardError = NSFileHandle.fileHandleWithNullDevice;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *ended) { (void)ended; dispatch_semaphore_signal(finished); };
    if (![task launchAndReturnError:NULL]) return NO;
    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC))) {
        // Only this exact crypto child. No shell or user-controlled arguments.
        kill(task.processIdentifier, SIGKILL);
        [task waitUntilExit];
        return NO;
    }
    return task.terminationStatus == 0;
}

static NSString *stageIn(NSString *directory) {
    if (!privateDirectory(directory)) return nil;
    NSString *path = [directory stringByAppendingPathComponent:[@".certificate-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    return mkdir(path.fileSystemRepresentation, 0700) == 0 ? path : nil;
}

static BOOL writeNew(NSData *data, NSString *path) {
    if (!data.length || data.length > 16384) return NO;
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t n = write(fd, (const char *)data.bytes + offset, data.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        offset += (size_t)n;
    }
    BOOL ok = offset == data.length && !fsync(fd);
    close(fd); return ok;
}

static void removeStage(NSString *stage) {
    // Exact private scratch directory created by this invocation. Never remove
    // installed identity files or follow an externally supplied directory.
    for (NSString *name in @[@"request.pem", @"public.pem", @"public.der", @"profile.cnf", @"cert.pem", @"cert.der"])
        unlink([stage stringByAppendingPathComponent:name].fileSystemRepresentation);
    rmdir(stage.fileSystemRepresentation);
}

static BOOL wordIs(xpc_object_t message, const char *name, uint64_t expected) {
    xpc_object_t value = xpc_dictionary_get_value(message, name);
    return value && xpc_get_type(value) == XPC_TYPE_UINT64 && xpc_uint64_get_value(value) == expected;
}

NSDictionary<NSString *, NSData *> *PLANKMacIssueWorkerIdentity(NSData *csr, NSString *directory) {
    if (getuid() != geteuid() || !csr.length || csr.length > 16384) return nil;
    NSString *stage = stageIn(directory);
    if (!stage) return nil;
    NSData *profile = [@"basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:plank-host\n" dataUsingEncoding:NSASCIIStringEncoding];
    BOOL ok = writeNew(csr, [stage stringByAppendingPathComponent:@"request.pem"]) &&
        writeNew(profile, [stage stringByAppendingPathComponent:@"profile.cnf"]);
    // Verify proof of possession and constrain the key. Never copy requested
    // extensions: the fixed DNS SAN and server-only usage are supplied here.
    if (ok) ok = crypto(stage, @[@"req", @"-in", @"request.pem", @"-verify", @"-noout"]) &&
        crypto(stage, @[@"req", @"-in", @"request.pem", @"-pubkey", @"-noout", @"-out", @"public.pem"]) &&
        crypto(stage, @[@"rsa", @"-pubin", @"-in", @"public.pem", @"-RSAPublicKey_out", @"-outform", @"DER", @"-out", @"public.der"]);
    NSString *publicPath = [stage stringByAppendingPathComponent:@"public.der"];
    if (ok) ok = chmod(publicPath.fileSystemRepresentation, 0600) == 0;
    NSData *publicBytes = ok ? readPublicResult(publicPath) : nil;
    NSDictionary *attributes = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic};
    SecKeyRef key = publicBytes ? SecKeyCreateWithData((__bridge CFDataRef)publicBytes, (__bridge CFDictionaryRef)attributes, NULL) : NULL;
    NSDictionary *keyAttributes = key ? CFBridgingRelease(SecKeyCopyAttributes(key)) : nil;
    unsigned bits = [keyAttributes[(__bridge id)kSecAttrKeySizeInBits] unsignedIntValue];
    ok = ok && (bits == 3072 || bits == 4096);
    if (key) CFRelease(key);
    NSString *serial = [@"0x" stringByAppendingString:[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
    if (ok) ok = crypto(stage, @[@"x509", @"-req", @"-in", @"request.pem", @"-CA", @"../cert.pem",
        @"-CAkey", @"../key.pem", @"-set_serial", serial, @"-days", @"365", @"-sha256",
        @"-extfile", @"profile.cnf", @"-out", @"cert.pem"]);
    if (ok) ok = crypto(stage, @[@"x509", @"-in", @"cert.pem", @"-outform", @"DER", @"-out", @"cert.der"]);
    for (NSString *name in @[@"cert.pem", @"cert.der"])
        if (ok) ok = chmod([stage stringByAppendingPathComponent:name].fileSystemRepresentation, 0600) == 0;
    NSData *pem = ok ? readPublicResult([stage stringByAppendingPathComponent:@"cert.pem"]) : nil;
    NSData *der = ok ? readPublicResult([stage stringByAppendingPathComponent:@"cert.der"]) : nil;
    NSData *authority = ok ? readPublicResult([directory stringByAppendingPathComponent:@"cert.der"]) : nil;
    removeStage(stage);
    return pem && der && authority ? @{@"certificate": pem, @"der": der, @"authority": authority} : nil;
}

NSData *PLANKMacAuthorizeDesktopIdentity(NSString *directory, const char *service, NSString *requirement) {
    if (!getuid() || getuid() != geteuid() || !service || !requirement.length) return nil;
    NSString *stage = stageIn(directory);
    if (!stage) return nil;
    // The key never leaves this account, not even in IPC. Generate only a CSR.
    BOOL ok = crypto(stage, @[@"req", @"-new", @"-key", @"../key.pem", @"-sha256", @"-subj", @"/CN=PLANK Host", @"-out", @"request.pem"]);
    NSString *requestPath = [stage stringByAppendingPathComponent:@"request.pem"];
    if (ok) ok = chmod(requestPath.fileSystemRepresentation, 0600) == 0;
    NSData *request = ok ? readPublicResult(requestPath) : nil;
    if (!request) { removeStage(stage); return nil; }
    dispatch_queue_t queue = dispatch_queue_create("la.instinctual.PLANK.Host.identity", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t peer = xpc_connection_create_mach_service(service, queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!peer) { removeStage(stage); return nil; }
    if (xpc_connection_set_peer_code_signing_requirement(peer, requirement.UTF8String)) {
        xpc_connection_cancel(peer); removeStage(stage); return nil;
    }
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) { (void)event; });
    xpc_connection_activate(peer);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(message, "version", 1);
    xpc_dictionary_set_uint64(message, "operation", 5);
    xpc_dictionary_set_data(message, "csr", request.bytes, request.length);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSDictionary *issued = nil;
    xpc_connection_send_message_with_reply(peer, message, queue, ^(xpc_object_t response) {
        if (xpc_get_type(response) == XPC_TYPE_DICTIONARY && xpc_connection_get_euid(peer) == 0 &&
            xpc_dictionary_get_count(response) == 5 &&
            wordIs(response, "version", 1) && wordIs(response, "status", 0)) {
            NSMutableDictionary *values = [NSMutableDictionary dictionary];
            for (NSString *name in @[@"certificate", @"der", @"authority"]) {
                size_t size = 0;
                const void *bytes = xpc_dictionary_get_data(response, name.UTF8String, &size);
                if (bytes && size && size <= 16384) values[name] = [NSData dataWithBytes:bytes length:size];
            }
            if (values.count == 3) issued = values;
        }
        dispatch_semaphore_signal(finished);
    });
    BOOL received = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC)) == 0;
    xpc_connection_cancel(peer);
    // Synchronize access with a possibly late response. No file writes occur
    // from the reply callback, so timing out cannot publish a stale identity.
    __block NSDictionary *result = nil;
    dispatch_sync(queue, ^{ if (received) result = issued; });
    NSData *authority = result[@"authority"];
    SecCertificateRef root = authority ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)authority) : NULL;
    SecCertificateRef leaf = result[@"der"] ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)result[@"der"]) : NULL;
    SecKeyRef publicKey = leaf ? SecCertificateCopyKey(leaf) : NULL;
    NSData *actualKey = publicKey ? CFBridgingRelease(SecKeyCopyExternalRepresentation(publicKey, NULL)) : nil;
    SecPolicyRef policy = SecPolicyCreateSSL(true, CFSTR("plank-host"));
    SecTrustRef trust = NULL;
    NSArray *certificates = root && leaf ? @[(__bridge id)leaf, (__bridge id)root] : nil;
    BOOL validChain = certificates && SecTrustCreateWithCertificates((__bridge CFArrayRef)certificates, policy, &trust) == errSecSuccess &&
        SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)@[(__bridge id)root]) == errSecSuccess &&
        SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess &&
        SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess && SecTrustEvaluateWithError(trust, NULL);
    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);
    // Check the returned leaf belongs to the private key that made this CSR.
    ok = result && validChain && crypto(stage, @[@"rsa", @"-in", @"../key.pem", @"-RSAPublicKey_out", @"-outform", @"DER", @"-out", @"public.der"]);
    NSString *publicPath = [stage stringByAppendingPathComponent:@"public.der"];
    if (ok) ok = !chmod(publicPath.fileSystemRepresentation, 0600) && [actualKey isEqual:readPublicResult(publicPath)];
    if (publicKey) CFRelease(publicKey);
    if (root) CFRelease(root);
    if (leaf) CFRelease(leaf);
    if (ok) ok = writeNew(result[@"certificate"], [stage stringByAppendingPathComponent:@"cert.pem"]) &&
        writeNew(result[@"der"], [stage stringByAppendingPathComponent:@"cert.der"]);
    // Both must succeed before a listener starts. An interrupted pair is
    // regenerated from the same key on the next startup, never re-trusted.
    for (NSString *name in @[@"cert.pem", @"cert.der"])
        if (ok) ok = rename([stage stringByAppendingPathComponent:name].fileSystemRepresentation,
                           [directory stringByAppendingPathComponent:name].fileSystemRepresentation) == 0;
    removeStage(stage);
    return ok ? authority : nil;
}
