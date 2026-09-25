// SPDX-License-Identifier: GPL-3.0-or-later
// Experimental native Host entry point. No fixture verifier, expiry alarm or
// loopback-only replacement server. Installation/signing remains a release gate.
#import "host-runtime.h"
#import "../audio-device/microphone-broker.h"
#import "../audio-device/output-broker.h"
#import "../audio-device/output-route.h"
#import "../camera-device/camera-broker.h"
#import "../camera-device/camera-signing.h"
#import "../camera-device/camera-activation.h"
#import "agent-connection.h"
#import "graphical-authority.h"
#import "fixed-capture.h"
#import "desktop-display.h"
#import "screen-capture.h"
#include "permission-status.h"
#import "desktop-provisioning.h"
#import "host-configuration.h"
#import "machine-identity.h"
#import "desktop-start.h"
#import "audio-consent.h"
#import <AppKit/AppKit.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdatomic.h>
#include <time.h>

#ifndef PLANK_MACOS_HOST_VERSION
#error Build must supply an explicit branch-qualified Host version
#endif

static void finishPermissionSetup(NSApplication *app) {
    PLANKMacAudioConsent *audio = [PLANKMacAudioConsent new];
    [audio startWithCompletion:^(BOOL started) {
        if (!started) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"PLANK Host system audio setup";
            alert.informativeText = @"System audio permission setup could not start. Check PLANK Host in "
                "System Settings → Privacy & Security → Screen & System Audio Recording, then reopen PLANK Host. "
                "Screen and input permissions remain enabled.";
            [alert addButtonWithTitle:@"Continue"]; [app activate]; [alert runModal];
        }
        PLANKMacShowCameraSetup(^{
            [audio stopWithCompletion:^{ [app terminate:nil]; }];
        });
    }];
}

static int startupFailure(const char *stage) {
    fprintf(stderr, "PLANK Host startup rejected: %s\n", stage);
    return 2;
}

// Run the installed signed app in the target graphical session. SSH/root
// Background results are not evidence of another user's graphical consent.
// No requests, capture, audio tap, input, listener or persistent state here.
static int checkPermissions(void) {
    [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyProhibited];
    PLANKMacGraphicalAuthority *authority = [[PLANKMacGraphicalAuthority alloc]
        initWithPhase:geteuid() == 0 ? PLANKMacScopeSignIn : PLANKMacScopeDesktop];
    BOOL graphical = plank_macos_graphical_identity_valid([authority snapshot]);
    BOOL screen = CGPreflightScreenCaptureAccess();
    BOOL post = CGPreflightPostEventAccess();
    BOOL accessibility = AXIsProcessTrusted();
    // Check the context again after preflights; a transition invalidates this
    // sample. The running stream still performs its own authorization checks.
    graphical = graphical && plank_macos_graphical_identity_valid([authority snapshot]);
    BOOL ready = plank_macos_screen_input_ready(graphical, screen, post, accessibility);
    NSDictionary *report = @{@"schema_version": @1, @"version": @PLANK_MACOS_HOST_VERSION,
        @"uid": @(geteuid()), @"graphical_context_valid": @(graphical),
        @"screen_capture": @(screen), @"post_event": @(post), @"accessibility": @(accessibility),
        @"screen_input_ready": @(ready), @"audio_tap_permission": @"not-checked"};
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
    [authority revoke];
    if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length || putchar('\n') == EOF) return 2;
    return ready ? 0 : 3;
}

// Read only a bounded regular file inside the already-open role-private
// directory. No symlink-following, shared machine key, framework keychain
// import, password argument or network-selected file path.
static NSMutableData *readPrivate(int directory, const char *name) {
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat st;
    if (fd < 0) return nil;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
        (st.st_mode & 0777) != 0600 || st.st_size <= 0 || st.st_size > 32768) {
        close(fd); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t count = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += (size_t)count;
    }
    char extra;
    BOOL exact = offset == data.length && read(fd, &extra, 1) == 0;
    close(fd);
    if (!exact) { [data resetBytesInRange:NSMakeRange(0, data.length)]; return nil; }
    return data;
}

static BOOL samePEM(NSData *pem, NSData *der, NSString *label) {
    NSString *text = [[NSString alloc] initWithData:pem encoding:NSASCIIStringEncoding];
    NSArray *lines = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if (lines.count < 3 || ![lines.firstObject isEqual:[NSString stringWithFormat:@"-----BEGIN %@-----", label]] ||
        ![lines.lastObject isEqual:[NSString stringWithFormat:@"-----END %@-----", label]]) return NO;
    NSString *body = [[lines subarrayWithRange:NSMakeRange(1, lines.count - 2)] componentsJoinedByString:@""];
    NSMutableData *decoded = [[[NSData alloc] initWithBase64EncodedString:body options:0] mutableCopy];
    BOOL equal = decoded && [decoded isEqual:der];
    [decoded resetBytesInRange:NSMakeRange(0, decoded.length)];
    return equal;
}

static void signals(void (^stop)(void)) {
    // Retained for the lifetime of this executable; never synchronous cleanup
    // from a POSIX signal handler.
    static NSMutableArray *sources;
    sources = [NSMutableArray array];
    for (NSNumber *value in @[@(SIGTERM), @(SIGINT)]) {
        signal(value.intValue, SIG_IGN);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
            value.unsignedIntValue, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, stop);
        [sources addObject:source]; dispatch_resume(source);
    }
}

static int machine(const char *service) {
    if (getuid() != 0) return 2;
    NSString *requirement = PLANKMacOwnSigningRequirement();
    __block __weak PLANKMacAgentRegistry *weakRegistry;
    __block dispatch_source_t exitWatch = nil;
    PLANKMacDesktopStart *desktopStart = [PLANKMacDesktopStart new];
    PLANKMacAgentRegistry *registry = [[PLANKMacAgentRegistry alloc]
        initWithQueue:dispatch_get_main_queue() requirement:requirement
        scope:^PLANKMacAgentPhase(PLANKMacAgentPeer peer) { return PLANKMacObserveAgentScope(peer); }
        event:^(PLANKMacAgentLease *lease, PLANKMacAgentEvent event) {
            if (event != PLANKMacAgentAttached) return;
            // Display, capture and input belong to this graphical process (no
            // detached display child). An XPC retirement ACK alone cannot release
            // ownership; wait for its exact kernel-observed process exit.
            exitWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, lease.peer.pid,
                DISPATCH_PROC_EXIT, dispatch_get_main_queue());
            if (!exitWatch) { [weakRegistry revoke]; return; }
            dispatch_source_set_event_handler(exitWatch, ^{
                [weakRegistry revoke];
                BOOL removed = [weakRegistry completeRetirement:lease];
                dispatch_source_cancel(exitWatch); exitWatch = nil;
                NSLog(@"PLANK Host graphical process exited; ownership released=%d", removed);
                if (removed && lease.phase == PLANKMacAgentDesktop)
                    [desktopStart desktopProcessExitedForUID:lease.peer.uid audit:lease.peer.auditSession];
            });
            dispatch_resume(exitWatch);
        }];
    if (!registry) return 2;
    registry.issueIdentity = ^NSDictionary<NSString *, NSData *> *(NSData *csr) {
        return PLANKMacIssueWorkerIdentity(csr, @"/Library/Application Support/PLANK/SignIn");
    };
    weakRegistry = registry;
    PLANKMacMicrophoneBroker *microphone = [[PLANKMacMicrophoneBroker alloc]
        initWithQueue:dispatch_get_main_queue() requirement:requirement
        authorize:^BOOL(PLANKMacAgentPeer peer, uint64_t generation) {
            return [weakRegistry admitsDesktopPeer:peer generation:generation];
        }];
    if (![microphone start]) { [registry stop]; return startupFailure("microphone-broker"); }
    PLANKMacOutputBroker *output = [[PLANKMacOutputBroker alloc]
        initWithQueue:dispatch_get_main_queue() requirement:requirement
        authorize:^BOOL(PLANKMacAgentPeer peer, uint64_t generation) {
            return [weakRegistry admitsDesktopPeer:peer generation:generation];
        }];
    if (![output start]) NSLog(@"PLANK Output automatic selection unavailable; manual output selection remains available");
    PLANKMacCameraBroker *camera = [[PLANKMacCameraBroker alloc]
        initWithQueue:dispatch_get_main_queue() requirement:requirement
        extensionRequirement:PLANKCameraPeerRequirement(@"la.instinctual.PLANK.Host.Camera")
        authorize:^BOOL(PLANKMacAgentPeer peer, uint64_t generation) {
            return [weakRegistry admitsDesktopPeer:peer generation:generation];
        }];
    if (![camera start]) NSLog(@"PLANK camera broker unavailable; other Host services remain available");
    xpc_connection_t listener = xpc_connection_create_mach_service(service, dispatch_get_main_queue(),
        XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) { [output stopWithCompletion:nil]; [camera stop]; [microphone stop]; [registry stop]; return 2; }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) [registry accept:peer];
    });
    xpc_connection_activate(listener);
    if (![desktopStart start]) {
        [output stopWithCompletion:nil]; [camera stop]; [microphone stop]; [registry stop]; xpc_connection_cancel(listener);
        return startupFailure("desktop-start-observer");
    }
    signals(^{
        [camera stop]; [microphone stop]; [desktopStart stop]; [registry stop]; xpc_connection_cancel(listener);
        [output stopWithCompletion:^{ exit(0); }];
        // Preserve the journal if HAL stalls; the next coordinator retries it.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
    });
    NSLog(@"PLANK Host machine coordinator started");
    [[NSRunLoop mainRunLoop] run]; return 0;
}

static int graphical(const char *service, NSString *role, NSString *directory, BOOL systemProvisioning) {
    NSApplication *application = NSApplication.sharedApplication;
    [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
    PLANKMacGraphicalPhase phase = [role isEqual:@"desktop"] ? PLANKMacScopeDesktop :
        [role isEqual:@"sign-in"] ? PLANKMacScopeSignIn : PLANKMacScopeUnavailable;
    PLANKMacGraphicalAuthority *authority = [[PLANKMacGraphicalAuthority alloc] initWithPhase:phase];
    PLANKMacGraphicalIdentity initial = [authority snapshot];
    if (!plank_macos_graphical_identity_valid(initial)) return startupFailure("graphical-scope");
    NSDictionary *publicConfiguration = nil;
    NSString *desktopAccountName = nil;
    NSData *authorityDER = nil;
    if (systemProvisioning) {
        if (phase == PLANKMacScopeDesktop) {
            if (!PLANKMacPrepareDesktop(&directory, &publicConfiguration, &desktopAccountName)) return startupFailure("desktop-provisioning");
            authorityDER = PLANKMacAuthorizeDesktopIdentity(directory, service, PLANKMacOwnSigningRequirement());
            if (!authorityDER) return startupFailure("machine-identity");
        } else {
            publicConfiguration = PLANKMacReadHostConfiguration(@"/private/etc/plank", @"/Library/Application Support/PLANK", 0, NO);
            if (!publicConfiguration) return startupFailure("machine-configuration");
        }
        if (!plank_macos_same_graphical_scope(initial, [authority snapshot])) return startupFailure("provisioning-scope-changed");
    }
    if (!directory.isAbsolutePath) return startupFailure("configuration-path");
    int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0) return startupFailure("configuration-directory");
    if (fstat(fd, &st) || st.st_uid != geteuid() || (st.st_mode & 0777) != 0700) {
        close(fd); return startupFailure("configuration-permissions");
    }
    NSMutableData *certificateBytes = readPrivate(fd, "cert.der"), *keyBytes = readPrivate(fd, "key.der");
    NSMutableData *certificatePEM = readPrivate(fd, "cert.pem"), *keyPEM = readPrivate(fd, "key.pem");
    close(fd);
    NSDictionary *config = publicConfiguration ?: PLANKMacReadHostConfiguration(directory, directory, geteuid(), YES);
    if (![config isKindOfClass:NSDictionary.class] || config.count != 6 ||
        ![config[@"Address"] isKindOfClass:NSString.class] || ![config[@"Name"] isKindOfClass:NSString.class] ||
        ![config[@"UUID"] isKindOfClass:NSString.class] || ![config[@"Port"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)config[@"Port"]) == CFBooleanGetTypeID() ||
        [config[@"Port"] doubleValue] != [config[@"Port"] unsignedShortValue] ||
        [config[@"Port"] unsignedShortValue] == 0) return startupFailure("configuration-values");
    if (!samePEM(certificatePEM, certificateBytes, @"CERTIFICATE")) return startupFailure("certificate-files");
    if (!samePEM(keyPEM, keyBytes, @"RSA PRIVATE KEY")) return startupFailure("private-key-files");
    SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateBytes);
    NSDictionary *attributes = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate};
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)keyBytes, (__bridge CFDictionaryRef)attributes, NULL);
    [keyBytes resetBytesInRange:NSMakeRange(0, keyBytes.length)];
    [keyPEM resetBytesInRange:NSMakeRange(0, keyPEM.length)];
    SecIdentityRef identity = certificate && key ? SecIdentityCreate(NULL, certificate, key) : NULL;
    if (certificate) CFRelease(certificate);
    if (key) CFRelease(key);
    if (!identity) return startupFailure("tls-identity");
    PLANKMacServerInformation *information = [[PLANKMacServerInformation alloc] initWithName:config[@"Name"]
        workstationUUID:[[NSUUID alloc] initWithUUIDString:config[@"UUID"]] version:@PLANK_MACOS_HOST_VERSION
        streaming:YES occupied:(phase == PLANKMacScopeDesktop)
        sessionUser:[config[@"PublishSessionUser"] boolValue] ? desktopAccountName : nil];
    PLANKMacFixedCapture *capture = [PLANKMacFixedCapture new];
    PLANKMacDesktopDisplay *desktopDisplay = phase == PLANKMacScopeSignIn ?
        [[PLANKMacDesktopDisplay alloc] initForSignIn] : [PLANKMacDesktopDisplay new];
    __block PLANKMacHostRuntime *runtime;
    __block __weak PLANKMacAgentConnection *weakAgent;
    __block BOOL stopping = NO;
    void (^stop)(void) = ^{
        if (stopping) return;
        stopping = YES;
        [runtime stopWithCompletion:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakAgent retire];
                // Retirement acknowledgement can be unavailable if the machine
                // service died. Drained process exit is still the cleanup proof.
                NSLog(@"PLANK Host control, video, audio and input drained");
                exit(0);
            });
        }];
    };
    xpc_connection_t peer = xpc_connection_create_mach_service(service, dispatch_get_main_queue(),
        XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    PLANKMacAgentConnection *agent = [[PLANKMacAgentConnection alloc] initWithPeer:peer
        queue:dispatch_get_main_queue() requirement:PLANKMacOwnSigningRequirement() serverUID:0
        phase:phase == PLANKMacScopeDesktop ? PLANKMacAgentDesktop : PLANKMacAgentLoginWindow
        valid:^BOOL { return plank_macos_same_graphical_scope(initial, [authority snapshot]); }
        event:^(PLANKMacAgentConnectionState state, uint64_t generation) {
            (void)generation;
            if (state == PLANKMacAgentReady && !stopping) {
                void (^listen)(void) = ^{
                    if (stopping) return;
                    if (![runtime startOnPort:[config[@"Port"] unsignedShortValue] ready:^(uint16_t port) {
                        NSLog(@"PLANK Host listening on %@:%u (TLS control/native QUIC; scope=%@)",
                            config[@"Address"], port, role);
                    } failed:^{ dispatch_async(dispatch_get_main_queue(), stop); }]) stop();
                };
                if (phase == PLANKMacScopeSignIn) {
                    // Establish a usable headless login display before discovery
                    // and topology queries. This grants no capture or input.
                    [desktopDisplay prepareWidth:1920 height:1080 valid:^BOOL {
                        return !stopping && plank_macos_graphical_identity_valid(
                            [weakAgent bindGraphicalScope:[authority snapshot]]);
                    } completion:^(BOOL ready) {
                        if (!ready) { stop(); return; }
                        capture.selectedDisplay = desktopDisplay.displayID;
                        listen();
                    }];
                } else listen();
            } else if (state == PLANKMacAgentRetiring || state == PLANKMacAgentDisconnected || state == PLANKMacAgentFinished) stop();
        }];
    weakAgent = agent;
    runtime = [[PLANKMacHostRuntime alloc] initWithIdentity:identity authority:authorityDER information:information
        snapshot:^{ return [weakAgent bindGraphicalScope:[authority snapshot]]; }
        topology:^{ return [capture snapshot]; } address:config[@"Address"]
        idleTimeoutMilliseconds:[config[@"PingTimeoutMs"] unsignedIntValue]
        certificate:[directory stringByAppendingPathComponent:@"cert.pem"]
        privateKey:[directory stringByAppendingPathComponent:@"key.pem"]
        capture:^id<PLANKMacPreviewCapture> {
            // Root LoginWindow retains its existing session-scoped SCK path;
            // never construct a global root Core Audio tap.
            PLANKMacScreenCapture *capture = [[PLANKMacScreenCapture alloc] initWithDesktopAudioTap:phase == PLANKMacScopeDesktop];
            if (phase == PLANKMacScopeDesktop) capture.outputRoute = ^PLANKMacOutputRoute *(dispatch_queue_t queue) {
                PLANKMacGraphicalIdentity scope = [weakAgent bindGraphicalScope:[authority snapshot]];
                if (!plank_macos_graphical_identity_valid(scope)) return nil;
                return [[PLANKMacOutputRoute alloc] initWithQueue:queue generation:scope.generation
                    requirement:PLANKMacOwnSigningRequirement() valid:^BOOL {
                        PLANKMacGraphicalIdentity current = [weakAgent bindGraphicalScope:[authority snapshot]];
                        return plank_macos_graphical_identity_valid(current) && current.generation == scope.generation &&
                            plank_macos_same_graphical_scope(scope, current);
                    }];
            };
            return capture;
        }
        input:^id<PLANKMacInputDevice> { return [PLANKMacQuartzInput new]; }];
    runtime.prepareDisplay = ^BOOL(unsigned width, unsigned height, unsigned scale, NSString *encodingMode, BOOL (^valid)(void)) {
        if (!PLANKMacDesktopModeSupported(width, height)) return NO;
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block atomic_bool cancelled = false, ready = false;
        dispatch_async(dispatch_get_main_queue(), ^{
            [desktopDisplay prepareWidth:width height:height scale:scale
                valid:^BOOL { return !atomic_load(&cancelled) && valid(); }
                completion:^(BOOL success) {
                    if (success && !atomic_load(&cancelled) && valid()) {
                        capture.selectedDisplay = desktopDisplay.displayID;
                        capture.encodingMode = encodingMode;
                        atomic_store(&ready, true);
                    }
                    dispatch_semaphore_signal(finished);
                }];
        });
        // Only the bounded authentication lane waits, never the graphical or
        // network event loops. A timeout revokes pending mutation, not authority.
        BOOL completed = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 7*NSEC_PER_SEC)) == 0;
        atomic_store(&cancelled, true);
        return completed && atomic_load(&ready);
    };
    runtime.recoverDisplay = ^BOOL(BOOL (^authorized)(void)) {
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block atomic_bool cancelled = false, ready = false;
        // Leave room inside the existing five-second HTTPS deadline. Never
        // wait on the graphical or network queue, or retry indefinitely.
        uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 3 * NSEC_PER_SEC;
        BOOL (^valid)(void) = ^BOOL {
            return !atomic_load(&cancelled) && clock_gettime_nsec_np(CLOCK_MONOTONIC) < deadline && authorized();
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            // Zero/zero is first-use capture of the current desktop, before
            // bookmark preparation creates our virtual display. It may need
            // waking too. A nonzero selection must still be our owned output.
            if (!valid() || capture.selectedDisplay != desktopDisplay.displayID) {
                dispatch_semaphore_signal(finished); return;
            }
            [desktopDisplay recoverWithValidity:valid completion:^(BOOL success) {
                if (success && valid()) atomic_store(&ready, true);
                dispatch_semaphore_signal(finished);
            }];
        });
        BOOL completed = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 3500*NSEC_PER_MSEC)) == 0;
        atomic_store(&cancelled, true);
        return completed && atomic_load(&ready);
    };
    CFRelease(identity);
    if (!agent || !runtime || ![agent start]) return startupFailure("runtime-admission");
    signals(stop);
    // Quartz display reconfiguration also needs AppKit's event processing.
    // A bare Foundation run loop services our timers but leaves an observed
    // virtual display offline. Keep the graphical agent headless, not eventless.
    [application run]; return 0;
}

int main(int argc, const char **argv) {
    struct rlimit noCore = {0, 0};
    if (setrlimit(RLIMIT_CORE, &noCore) || getuid() != geteuid()) return 2;
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], PLANK_MAC_ACCOUNT_WORKER_ARGUMENT)) return PLANKMacAccountWorkerMain();
        if (argc == 2 && !strcmp(argv[1], "--version")) {
            puts("PLANK Host " PLANK_MACOS_HOST_VERSION); return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--check-permissions")) return checkPermissions();
        if (argc == 2 && (!strcmp(argv[1], "--enable-camera") || !strcmp(argv[1], "--disable-camera"))) {
            NSApplication *app = NSApplication.sharedApplication;
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
            BOOL enable = !strcmp(argv[1], "--enable-camera");
            dispatch_async(dispatch_get_main_queue(), ^{
                PLANKMacRequestCameraExtension(enable, ^(BOOL success) { (void)success; [app terminate:nil]; });
            });
            [app run]; return 0;
        }
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--request-permissions"))) {
            NSApplication *app = NSApplication.sharedApplication;
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL screen = CGPreflightScreenCaptureAccess();
                BOOL input = AXIsProcessTrusted();
                BOOL post = CGPreflightPostEventAccess();
                if (screen && input && post) {
                    finishPermissionSetup(app);
                    return;
                }
                if (!screen) screen = CGRequestScreenCaptureAccess();
                if (!input) {
                    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
                    input = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
                }
                if (!post) post = CGRequestPostEventAccess();
                // A permission request may complete before returning. Do not
                // show stale setup instructions after permission was granted.
                screen = CGPreflightScreenCaptureAccess();
                input = AXIsProcessTrusted();
                post = CGPreflightPostEventAccess();
                if (screen && input && post) {
                    finishPermissionSetup(app);
                    return;
                }
                NSAlert *alert = [NSAlert new];
                alert.messageText = @"PLANK Host permission required";
                alert.informativeText = [NSString stringWithFormat:
                    @"Version %s\n\nScreen & System Audio Recording: %@\nAccessibility: %@\nKeyboard/Mouse Event Posting: %@\n\n"
                     "Enable PLANK Host in System Settings → Privacy & Security. These permissions belong to "
                     "PLANK Host, separately from PLANK Host Probe. Reopen this app after enabling them. "
                     "System audio consent is requested here once screen and input access are enabled. "
                     "This permission window does not start a remote session.",
                    PLANK_MACOS_HOST_VERSION, screen ? @"Allowed" : @"Required", input ? @"Allowed" : @"Required",
                    post ? @"Allowed" : @"Required"];
                [alert addButtonWithTitle:@"Close"];
                [app activate]; [alert runModal]; [app terminate:nil];
            });
            [app run]; return 0;
        }
        if (argc == 3 && !strcmp(argv[1], "--machine")) return machine(argv[2]);
        if (argc == 3 && !strcmp(argv[1], "--desktop")) return graphical(argv[2], @"desktop", nil, YES);
        if (argc == 3 && !strcmp(argv[1], "--sign-in"))
            return graphical(argv[2], @"sign-in", @"/Library/Application Support/PLANK/SignIn", YES);
        if (argc == 5 && !strcmp(argv[1], "--graphical"))
            return graphical(argv[2], [NSString stringWithUTF8String:argv[3]], [NSString stringWithUTF8String:argv[4]], NO);
        fprintf(stderr, "Usage: plank-host --enable-camera | --disable-camera | --check-permissions | --request-permissions | --machine MACH_SERVICE | --graphical MACH_SERVICE desktop|sign-in PRIVATE_DIRECTORY\n");
        return 2;
    }
}
