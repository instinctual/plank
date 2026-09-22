# PAM Authentication Protocol

## Security Boundary

PLANK replaces persistent GameStream pairing with authentication for
every new connection. The network-facing Sunshine process never links to PAM,
runs PAM modules, or stores a password. A root-owned
`plank-pam-broker` performs PAM operations through the dedicated
`plank-host` service and exposes only a Unix socket at
`/run/plank/pam/auth.sock`. The socket and its parent directory are
owned by root and use modes `0600` and `0700`, respectively.

The root supervisor connects to the fixed broker endpoint and delegates the
connected descriptor to its media worker through a private inherited
`SOCK_SEQPACKET` channel. The worker never opens the broker path directly;
there is no direct-connect fallback. Credentials flow between the worker and
broker over the delegated connection, not through the supervisor. The broker
accepts only root `AF_UNIX` connecting peers and validates their kernel-supplied
credentials before forking a conversation handler. That connecting UID is the
supervisor's, not the authenticated desktop user's.

The broker reads `security.allow_root_login` from the root-owned host config.
Root is denied when the option is absent or false. Enabling it still requires
the host's PAM, authselect, and SSSD policy, including FreeIPA HBAC, and does
not bypass active-desktop ownership. PLANK has no application-specific user allowlist. Prompt responses
must never appear in logs, process arguments, environment variables, URLs, or
crash reports.

## Broker Framing

Every message starts with the packed 20-byte header in
`src/auth/pam_broker_protocol.h`. Integer fields are little-endian. The header
carries magic `PLAP`, version `1`, message type, a nonzero 64-bit transaction
ID, and payload length. Payloads are capped at 64 KiB, individual strings at
4096 bytes, and lists at 64 entries.

The ordered lifecycle is:

1. Sunshine sends `begin` with length-prefixed username, remote-host label,
   and logical TTY strings.
2. The broker calls `pam_start()` and emits `challenge` messages containing
   every PAM prompt, error, and informational message with its original style.
3. Sunshine returns one `response` entry per message. Responses for
   informational messages are empty.
4. The broker calls `pam_authenticate()`, `pam_acct_mgmt()`,
   `pam_setcred(PAM_ESTABLISH_CRED)`, and `pam_open_session()` in order.
5. A `result` reports the failing phase and PAM status, or authenticated
   success. The socket remains open for the lifetime of a successful session.
6. `cancel`, EOF, or process death closes the PAM session, deletes credentials,
   and calls `pam_end()`.

Malformed, oversized, stale-transaction, or out-of-order messages terminate
the local connection. The local socket is not a client-facing API.

## HTTPS Authentication

The host refuses to start its network service unless the broker socket is
available. It has no PIN-pairing or persistent client-certificate path, requires
TLS 1.3, and exposes `POST /plank/auth/start`
and `POST /plank/auth/respond`. The first body contains `username`;
the second contains an opaque `conversation_id` and a `responses` array.
Replies are non-cacheable JSON with `challenge`, `authenticated`, or `denied`
state. Successful authentication returns a 256-bit random bearer token bound
to the client address. Application list, asset, launch, resume, and cancel
requests require that token.

The first launch transfers the open PAM session into the native QUIC stream lifetime.
Concurrent streams may share it. Releasing the last stream closes PAM and
invalidates the token; a later resume requires a new login. Pending
conversations expire after 120 seconds, and unclaimed tokens after 300 seconds.

## Execution bounds and cancellation (Linux Host)

PAM begin/respond operations run outside the authentication manager's state
mutex, on four dedicated workers rather than the HTTPS event loop. Admission
counts both running and queued work and has no backlog beyond those four
operations. The manager separately caps conversations and tokens at 32.
Canceled or expired in-flight conversations keep their capacity reservation
until the operation exits; duplicate concurrent responses are rejected. A late
PAM success cannot mint a token for a canceled or expired conversation.
Socket teardown and cancellation also happen outside the state mutex.

Each broker operation has one absolute 30-second monotonic deadline across
descriptor delegation, request writes and response header/body reads. Partial
traffic and interrupted system calls cannot restart that deadline. The private
descriptor handshake remains capped at three seconds, including draining an
already-submitted reply when canceled so it cannot be mistaken for the next
request. Cancellation while waiting for serialization does not poison the
shared channel.

An in-process monitor watches duplicate HTTPS sockets for peer disconnect,
without reading any TLS data. Client timeout/abort cancels only that request
(100 ms monitor interval and 25 ms broker-I/O cancellation checks). Worker
shutdown cancels admitted requests before joining them. The independent
30-second deadline still bounds an unresponsive backend if no disconnect is
observable. The socket is closed rather than synchronously writing a cancel
message during object destruction.

The broker parent watches caller EOF even when its PAM child is blocked inside
SSSD. Normal PAM cleanup gets two seconds, after which the parent kills a stuck
worker and reaps it without blocking later logins. Shutdown also bounds its
reaping wait; no userspace deadline can force a kernel uninterruptible task to
exit. Healthy, connected authenticated sessions have **no authentication
timeout**. The 120-second human-response timeout and 300-second unclaimed-token
expiry are separate. Revoking/expiring a claimed token does not end its live
stream's PAM ownership.

The framing, PAM service/account policy, TLS identity trust and Client protocol
are unchanged. These implementation bounds affect the Linux Host, not native
macOS authentication.

The isolated `tests/session/pam` CMake suite compiles the actual manager, client,
broker and HTTPS server against the pinned GoogleTest, Simple-Web-Server and
prepared Boost inputs. It tests slow/truncated peers, blocked writes, late
results, concurrent token/login operations, process cleanup, descriptor
lifetimes and a real TLS status/abort exchange. The Host package builder runs
this gate even with `BUILD_TESTS=OFF` for the shipped payload; no real credentials
or account-policy changes are involved.

## TLS and Network Policy

The Host package provisions its RSA-3072/SHA-256 certificate and DNS-only SAN.
The Client requires TLS 1.3 and a remembered machine public key before sending
credentials or bearer tokens. Explicit first connection uses automatic TOFU;
discovery does not populate trust and automatic recovery cannot replace it.
Linux presents its self-signed machine certificate; a macOS desktop presents a
server leaf directly signed by its machine authority. Changed-key confirmation
applies to exactly the displayed old/new identities, before a new authentication
conversation. See [Host identity trust](../docs/security/host-identity-trust.md)
for chain constraints, replacement behavior and first-use limitations.

This policy does not classify or restrict the network interface selected by
the operating system. Production
deployments must enforce their intended network boundary with interface-scoped
host firewall rules.
