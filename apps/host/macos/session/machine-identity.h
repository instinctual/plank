// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Called on a bounded background lane by the authenticated machine registry,
// never directly by a network request. The CSR contains no paths or extensions
// to copy. Only public certificate bytes leave the machine identity directory.
NSDictionary<NSString *, NSData *> *PLANKMacIssueWorkerIdentity(NSData *csr);

// Startup only, before the graphical worker registers or opens any listener.
// Uses the existing privileged Mach service, verifies its signing identity and
// kernel UID, and atomically replaces certificate files, never the user key.
// Returns the machine authority DER to send with the worker's TLS certificate.
NSData *PLANKMacAuthorizeDesktopIdentity(NSString *directory, const char *service,
                                       NSString *requirement);
