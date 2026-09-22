// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Called on a bounded background lane by the authenticated machine registry,
// never directly by a network request. The CSR contains no paths or extensions
// to copy. The directory is trusted coordinator configuration, NEVER an IPC
// field. It must be owned by the caller and private. Only public certificate
// bytes leave it; production calls this in the root machine coordinator.
NSDictionary<NSString *, NSData *> *PLANKMacIssueWorkerIdentity(NSData *csr, NSString *directory);

// Startup only, before the graphical worker registers or opens any listener.
// Uses the existing privileged Mach service, verifies its signing identity and
// kernel UID, and atomically replaces certificate files, never the user key.
// Returns the machine authority DER to send with the worker's TLS certificate.
NSData *PLANKMacAuthorizeDesktopIdentity(NSString *directory, const char *service,
                                       NSString *requirement);
