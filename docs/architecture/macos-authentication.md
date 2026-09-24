# macOS account authentication boundary

Status: native verifier, supervised private channel and Client-shaped
authentication conversation tested, including loopback HTTPS in a live Aqua
session. These are not an installable Host or an existing-Client stream.
See `docs/architecture/macos-control-plane.md` for the new native interface and remaining gates.

## Existing wire contract

Inspection of the actual current root baseline and fork gitlinks confirms that
the Client authenticates through HTTPS `/plank/auth/start` and `/respond`, then
uses native QUIC setup for stream launch. The setup header contains reserved
PAM/server-info operation IDs, but their existence does not prove that current
Client/Host account authentication uses them. Keep the working contract for
this platform port; do not silently add another transport migration. Password
prompt styles in this exchange need not imply that macOS internally uses PAM.

## Native verification

`ODNode` selects the authentication search node; `ODRecord` resolves the user.
`verifyPassword:error:` verifies the secret and, per SDK 27's header, evaluates
record and node authentication/password policies. Do not call a duplicate policy
check and treat its earlier result as authoritative. No manual password hashes,
directory writes, macOS PAM-service edits or account-policy overrides are used.

The record must have one strictly parsed numeric UID and one UUID, and the UUID
must match `mbr_uid_to_uuid`. Root is denied in this initial macOS backend.
The membership identity is checked again after verification. This does not
authorize a desktop; a session-generation check remains mandatory separately.

The internal function accepts a UTF-8 name of at most 255 bytes and a mutable
UTF-8 password of at most 4096 bytes. Empty values, embedded NULs, invalid UTF-8
and malformed identity fail closed. Failure clears the output identity; every
return wipes the caller's password data. No username, UUID, password or detailed
Open Directory exception is emitted by this module.

Open Directory/Foundation may create internal secret copies. Do not claim
complete process-memory erasure: the intended helper is short lived with core
dumps disabled. Framework-managed copies are not claimed to be securely erased.

## Supervised private channel

`account-channel.m` re-execs the calling executable with one fixed internal
worker argument. Both sides use Security.framework to validate the running
peer against their own code's designated requirement. The worker additionally
requires an inherited Unix stream socket, matching effective/real credentials,
same-UID peer and a kernel-reported peer PID equal to its parent. It has no
named socket, listening port, setuid mode or direct-connect fallback.

The parent validates the child's running code before sending credentials; the
child validates its parent before reading them. Qualification uses the linker's
ad-hoc signature (exact-image requirement). Shipping Developer ID signing,
product-specific designated requirements and protected installation ownership
still require deployment qualification. This does not protect against a fully
compromised same-identity process or root.

`posix_spawn` explicitly retains only the channel and `/dev/null` standard
streams, with an empty environment, a reset signal mask and no unrelated file
descriptors. The worker disables core dumps. The caller must already have
disabled core dumps before accepting credentials; otherwise the API fails
closed. The worker cannot be substituted with a caller-selected helper path.

One transaction carries a versioned, length-bounded username/password request,
followed by EOF. Trailing requests, partial frames, bad versions and oversized
lengths fail without authentication. The reply contains only status and verified
UID/UUID, not a desktop grant. Secrets do not enter command arguments,
environment, files or diagnostic output. Mutable buffers are cleared on normal
and error returns; process exit bounds framework-copy lifetime.

The parent admits one attempt at a time with a two-second minimum start
interval. A four-second monotonic transaction deadline and independent child
alarm bound stalls, leaving a margin under the existing Client's five-second
HTTPS-auth timeout. Failure kills/reaps the exact child; clean replies require
a clean child exit. The containing service must own child reaping (do not
install an indiscriminate SIGCHLD reaper or ignore SIGCHLD). Calls belong on a
background authentication queue, never the GUI/network event loop. Future
network request admission must also be bounded; a process-local throttle is
not a distributed denial-of-service defense.

## Authentication conversation

`authentication-session.m` emits the existing `challenge`/style-1-password and
`authenticated`/`session_token` JSON shapes without assuming PAM internally.
It obtains graphical snapshots only from an injected **trusted session-owner**
provider, not from Client JSON. Password verification invokes the isolated
channel. Pending conversations expire after 120 seconds and are consumed
before verification; a response cannot replay. Random 256-bit conversation IDs
and tokens are bound to canonical IP bytes supplied by the accepted connection.
There is a hard cap of 16 pending conversations and 16 unclaimed tokens.

Unclaimed tokens expire after 300 seconds. Every authorization rechecks phase,
generation and, for a desktop, UID/UUID. Expiry, logout/replacement and explicit
revocation remove authority. Sign-in is an explicit, positively verified
LoginWindow scope with no desktop account; an absent/error/zero-initialized
snapshot cannot authorize it. Only a verified non-root remote account may
attach there. No token or stream lease can cross into a desktop, including the
same account and even an erroneously reused generation. A new authenticated
connection must match that desktop's owner. This is not an automatic macOS login.
No account/credential/token values are logged.

This state class does not implement HTTP itself. The new Network.framework
adapter supplies TLS 1.3, bounded HTTP/JSON input, non-cacheable replies and
actual connection-derived peer addresses. Live graphical-session snapshots are
now connected and qualified for the already-logged-in desktop case. The stream
lease below now connects to the experimental HTTP launch and native stream owner.

## One-use stream claim

After validating capture/profile/geometry, `claimToken:peer:` atomically consumes
the peer-bound HTTP token and returns one opaque process-local lease. It creates
an independent random 256-bit transport credential; the HTTP token cannot be
replayed as a launch or used for subsequent topology queries. Only one pending
or active lease exists. A second claim fails instead of implicitly taking over.

The coordinator must activate the exact lease only after its credential-bound
native QUIC endpoint reports READY. Pending activation expires after 15 seconds.
Active authorization has no five-minute expiration: it lasts until explicit
disconnect/revocation or loss/replacement of the authenticated desktop. Every
check revalidates trusted phase/UID/UUID/generation. Revocation clears the lease's
credential and record and cannot be undone by restoring an old desktop snapshot.
Ending a foreign or stale lease cannot terminate another stream.

Password verification runs outside the session-state lock. A revocation epoch
prevents an in-flight verifier from minting a new token after `revokeAll`.
Only one verifier runs concurrently. `performWithStreamLease:action:` orders a
bounded native-media enqueue against revocation under the short state lock;
encoding, socket waits and other blocking operations must remain outside it.
Frames already enqueued or in flight before revocation cannot be recalled.

The lease does not itself own a transport, timer or capture session. The new
preview coordinator stops capture and its endpoint on disconnect, desktop loss,
topology replacement or failed activation, including while no frame arrives.
It now also owns native keyboard/mouse delivery and its stop/drain lifetime.
Synthetic lifecycle and short live Aqua loopback
tests now exercise that boundary; user-facing takeover and complete machine
service lifecycle are not qualified by those tests.

## Desktop authority

Trusted snapshots before and after verification must identify the same active
desktop and nonzero authority generation. Both UID and UUID must match the
verified identity. Generation must change on revocation/replacement, even if
the OS recycles a security-session ID or the same user logs in again. The
network client never chooses that generation. Live capture/input still requires
continuous revocation handling after attachment.

`graphical-authority.m` requires an explicit role and positive OS evidence for
that role. The existing HTTPS probe still explicitly selects non-root Aqua;
it never infers LoginWindow from the absence of a desktop or unlocks a session.
The new registry `authenticationScope:` obtains a separate sign-in/desktop
snapshot from the exact admitted XPC lease, after machine scope validation.
See `macos-session-lifecycle.md`: the graphical owner must independently check
its own session, permissions and media/input scope. Current HTTPS/A/V probe
orchestration still uses the desktop provider, not the machine registry. A
synthetic verifier tests registry-bound admission and revocation in a separate
service/agent harness; it is never linked into the real verification backend.
The local scope can now be bound to fresh machine admission using
`bindGraphicalScope:` without synchronizing the media/auth caller onto the IPC
queue. Service expiry and local identity changes latch revocation even if that
queue stalls. The native A/V/input lifecycle suite exercises that composition.

Local graphical evidence is refreshed every500ms on a dedicated serial observer.
Authorization reads that evidence under a short lock, without calling
WindowServer, SystemConfiguration or membership services on the media/input
queue. Those synchronous calls previously ran for every audio packet, camera
check and input event; live thread samples and audio-ring overruns showed this
queue could stall under application startup and simultaneous camera use.

Observation age is limited to1 second, measured from the beginning of the OS read.
Expiry permanently revokes the local authority, including when a late successful
read returns before any foreground caller noticed the expired deadline. OS
failure or changed account/session also revokes it. Resignation and sleep
notifications revoke immediately without waiting for an outstanding OS call;
lock/unlock retains the existing same-console policy. Unannounced OS changes
are normally detected on the next500ms check; the1-second expiry bounds stalled
observation. The machine coordinator's independent250ms ownership checks and
admission deadline are unchanged. Machine admission, token/lease ownership,
permissions and display generation remain independently checked. The lifecycle
fixture covers healthy500ms cadence, a blocked observer, concurrent reads, notification revocation,
expiry and late replies; installed audio/input recovery needs a separate test.

## Qualification and limits

- Twenty-seven pure phase/ownership/identity cases and 119 synthetic conversation/
  lease checks pass on the dedicated Mac. LoginWindow-to-desktop, reverse-phase,
  same-phase replacement, root and stale-token denial are explicit cases.
- Seven malformed-input/root-denial cases pass on the Mac and verify caller
  password buffers are cleared and failure output contains no identity.
- One real development-account password verification passes without root;
  UID matches the invoking account and the mutable password buffer is cleared.
- The same real account passes through the mutually checked, short-lived
  private channel under the four-second deadline; no desktop is granted.
- Sixteen synthetic private-channel cases pass, covering successful reply,
  rate/concurrency rejection, crash, timeout, malformed/truncated/trailing
  requests, peer-code mismatch and direct invocation without the channel.
  Child assertions verify core-dump suppression, no inherited unrelated FD or
  test environment variable; the final gate verifies no unreaped children.
- Ninety-three synthetic conversation/lease assertions pass: Client-shaped JSON,
  address binding, replay/expiry, wrong owner, generation change before/during
  verification, revoked/expired tokens, inactive desktop, bounded pending
  state and password clearing, one-use claims, activation deadline, active
  lifetime beyond token expiry, foreign-lease rejection, revoke/enqueue ordering,
  and revocation while the verifier is blocked. These tests do not call Open Directory.
- No actual incorrect password was submitted for the real account, avoiding an
  unqualified lockout policy. Locked/expired/disabled/remote-directory account
  behavior remains untested. API documentation is not a substitute for those
  eventual service acceptance tests.
- Real verification also passes through the authentication-only HTTPS listener
  in Aqua, with live owner checks and replay denial. This is a temporary loopback
  qualification, not a non-loopback service or existing-Client test.
- No account modification, GUI login, capture/input grant, TCC/keychain/trust
  change or product installation occurred.

Sources: [Apple ODRecord](https://developer.apple.com/documentation/opendirectory/odrecord)
and the OpenDirectory `ODRecord.h` supplied with SDK 27. Exact probe hashes and
machine-independent result provenance are in HANDOFF.
