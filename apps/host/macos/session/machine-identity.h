// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Certificate helpers share one issuance budget, not a fresh timeout for
// every subprocess. Leave time for XPC delivery before the one-shot link is
// retired. Ordinary unregistered peers still have their shorter idle expiry.
#define PLANK_MAC_IDENTITY_CRYPTO_NS (10ull * NSEC_PER_SEC)
#define PLANK_MAC_IDENTITY_REPLY_NS (12ull * NSEC_PER_SEC)
#define PLANK_MAC_IDENTITY_LINK_NS (15ull * NSEC_PER_SEC)

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
