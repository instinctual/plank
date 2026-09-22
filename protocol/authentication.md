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
