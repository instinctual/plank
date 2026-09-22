# Host identity trust

The Client automatically remembers a Host's public-key identity on the first
**explicit** connection. Discovery does not enroll Hosts. Credentials and
bearer tokens require TLS 1.3, a validated PLANK certificate profile and the
remembered identity before HTTP application data is sent. Redirects are not
followed. Each request gets a fresh TLS connection so connection reuse cannot
skip Qt's pre-send certificate check.

This is trust on first use (TOFU), not verified first-use identity. An attacker
already intercepting the first connection can still be trusted. A successful
first connection does not independently prove who operates the machine.
Administrator-provisioned trust would address that separate threat, but is
deliberately not required by this product workflow.

## Storage and replacement

Trust is per local Client account, scoped to the configured destination and
port. It is not indexed by an unauthenticated Host UUID or an advertised
alternate route. Pins live in `host-trust/identities.json` under Qt's application
data directory, separate from bookmarks and preferences. Deleting or recreating
a bookmark does **not** reset trust. Directory/files are private to that account;
updates are locked across processes and atomically saved. Corrupt, unreadable or
unwritable storage fails closed instead of silently starting over.

A changed key stops before credentials. The Client presents **Host identity
changed**, with **Cancel** selected and **Trust Replacement Host** as the explicit
alternative. Expandable details show old/new SHA-256 public-key fingerprints.
Approval replaces exactly those displayed keys atomically. If either changes
again, the connection stops; approval does not authorize an arbitrary next key.
Automatic reconnect cannot enroll or approve replacement. Password conversations
and bearer tokens stay bound to the identity that created them.

Trusting a replacement is appropriate only when its replacement/reinstallation
is expected. Cancelling leaves the previous identity intact. Reinstalling the
Host while retaining its machine private key does not require a reset. Removing
that key creates a genuinely new identity and requires Client confirmation.

## Host lifecycle

Linux retains its existing root-owned machine TLS key. Certificate renewal
preserves the key; a damaged existing key is not silently replaced.

macOS keeps the root LoginWindow identity as a machine signing authority. The
package provisions/renews its CA certificate without replacing its private key.
Desktop workers retain separate private keys in their own protected account
directories. Before opening a listener, a worker sends a bounded CSR over the
existing authenticated machine-coordinator XPC service. The coordinator checks
the caller's code signature, kernel identity and current desktop scope, signs
only a constrained server certificate, then rechecks scope before replying.
Only public certificate bytes cross IPC. Issuance is serialized on a separate
bounded lane, not the coordinator's health/ownership queue. No extra service,
network enrollment endpoint, global Keychain import or administrator action is
introduced.

HTTPS presents the desktop leaf and machine authority. The Client verifies the
signature/constraints and pins the authority's SubjectPublicKeyInfo SHA-256.
LoginWindow and every desktop user therefore represent the same machine, while
normal login/logout changes the worker key. QUIC retains its exact leaf pin,
learned through this trusted HTTPS connection. The machine private key is never
made readable by desktop users.

TLS key possession is not OS-account authentication, session ownership or input
authorization. Existing PAM/macOS account and session checks remain mandatory.
A compromised local desktop account can expose its worker private key and its
still-valid machine-signed certificate; this mechanism does not protect against
an already compromised Host. Certificates are renewed during package upgrades,
and worker certificates are reissued at worker startup. These are not indefinite
certificates: a continuously running worker still has a certificate expiry.

## Qualification

`HostTrustStoreTest` covers persistence, separate bookmark lifetime, competing
enrollment, exact replacement and storage failure. `HostTlsGuardTest` uses real
TLS sockets to assert rejected peers receive no HTTP credential bytes, including
forged chains and old conversations after replacement. The existing consent UI
suite covers the replacement dialog's responsive accept/cancel/Escape paths.
The NvHTTP integration fixture exercises 19 launch/authentication scenarios,
including a key swap between the username and password requests, and unknown
automatic recovery. It runs in the Linux Client package build. The macOS issuer
fixture signs distinct worker keys using the actual system crypto tool and
checks the resulting chains with both LibreSSL and Security.framework.
The HTTPS fixture also verifies the exact chain emitted by Network.framework
and performs authenticated control requests against that worker certificate.
Host package tests cover renewal without key rotation; macOS XPC tests cover
bounded issuance and scope rejection. Builds are not a substitute for live
login/logout, cross-user handoff and genuine Host replacement acceptance.
