# Mac service and graphical-agent ownership

Experimental macOS/SDK 27 implementation under `apps/host/macos/session`. The native
`host-main.m` executable now joins the production IPC boundary to HTTPS remote
authentication and the A/V/input owner through `host-runtime.m`. The executable
has no qualification timeout or synthetic verifier. Virtual displays and
development installation are implemented; the operator accepted the .62
reboot/login/logout and resolution/input-mapping cycle on September 8.
Broader release lifecycle qualification remains in `macos-host.plan`.
Qualification launchd jobs are temporary fixtures, not package inputs.

## Runnable Host assembly

Desktop audio is optional during session startup. ScreenCaptureKit readiness
enables the video/input session immediately; a Core Audio tap awaiting consent
or failing to start must not gate that callback or stop video/input. There is
no automatic consent grant and no switch to a different user's audio. Runtime
tap failure disables and cleans up audio for this session, preserving desktop
access. Pending/active/unavailable/cleanup status goes to the product log.

Pending tap cancellation is distinct from active IO drain: an atomic activation
gate prevents a consent request completed after disconnect from ever starting
IO. The session can finish teardown while that unstarted request returns from
HAL and destroys any partial resources. Active IO must still stop and destroy
before teardown completion. The worker allows at most one tap, including
deferred cleanup; a reconnect while old consent is outstanding remains usable
without audio (retry audio on a later connection). No root audio fallback or
TCC database access. The lifecycle test replaces only HAL setup/start/cleanup
and exercises the real asynchronous class; live consent/input still needs
operator qualification.

The Mac deployment is a single active-user workstation. Its desktop audio tap
also includes system alerts from the running `com.apple.systemsoundserverd`
process, validated with Apple's code-signing anchor and exact identifier.
This exception requires current console ownership; all other audio processes
still require matching effective/real user IDs. Standard users cannot inspect
that root service with proc_pidinfo on the qualified OS, so dynamic SecCode
validation is the authority, not a guessed PID, process name or HAL bundle ID.
The same tap mixes and mutes the selected application's and system-alert
streams, with no second audio path or additional Host privilege.

`plank-host --machine MACH_SERVICE` runs the root ownership coordinator.
`plank-host --desktop MACH_SERVICE` runs the current user's Aqua worker;
`plank-host --sign-in MACH_SERVICE` runs the root LoginWindow worker.
The machine coordinator observes the OS console-session key and requests
`launchctl kickstart` of the existing desktop job for each new user/audit
session, including on coordinator startup. This is necessary during first-user
Setup Assistant: macOS can defer RunAtLoad/KeepAlive agents in an on-demand-only
Aqua domain. An explicit demand starts the agent without skipping onboarding.
Registration races and admitted-worker exits share at most ten explicit start
attempts per console/audit session. Retries back off by 1, 2, 4, 8, then at most
16 seconds (95 seconds of delays across all ten attempts). Unchanged notifications
and duplicate exits do not replenish that budget. A successful `kickstart` is
only a start request, not listener readiness: a later kernel-observed desktop
process exit re-arms the remaining budget after its exact lease is released.
This recovers a transient control-port bind failure even when launchd defers
KeepAlive in an on-demand-only domain. A changed console/audit session discards
stale retry callbacks; an old user's exit cannot re-arm the current user. A
worker exit received before launchctl completion cannot be lost to a late success.
The request is asynchronous and its launchctl child is terminated after five
seconds if still pending. Only one delayed retry is pending at a time.
There is no `-k`, enable, job bootstrap, shell, new helper service or TCC change.
The existing worker still validates graphical ownership, signed coordinator
admission and capture/input permissions. Starting the job grants no remote
access. Root/LoginWindow, incomplete login records and stale session retries
do not select a desktop agent.

Control-listener failures log the configured port and numeric error domain/code
to the product log. Startup recovery does not enable shared-port binding, kill
another listener, change ports, reset permissions or reuse another user's
authentication. A persistent bind failure exhausts the bounded startup budget;
it must be diagnosed rather than hidden by an unlimited restart loop.

The explicit `--graphical MACH_SERVICE desktop|sign-in PRIVATE_DIRECTORY`
entry remains for isolated role-private qualification fixtures, not installed
startup. Both installed roles read the root-owned public configuration; neither
consults an old user `host.plist` or copies another role's private key.
Same-product signing and root machine-peer checks remain mandatory. The agent
opens HTTPS only after admission; each authentication/media/input authorization
uses the independent local scope bound to the machine's current generation.
No capture or input occurs merely because a listener starts.

The runtime owns the HTTPS server, token owner and at most one native stream.
It uses the existing HEVC Main10, stereo Opus and absolute keyboard/mouse
implementations, with embedded cursor. Shutdown closes new launch admission,
drains the stream (including authorized held-input release), then waits for the
HTTP authentication/reply lanes to drain. It does not block the graphical loop
on endpoint construction or substitute a fixed sleep for cleanup completion.

Native QUIC shutdown must keep its runtime alive after requesting connection
closure. `CommonServer.close()` queues the close packet; await the existing
Kyber `wait_idle()` with a one-second upper bound before dropping the runtime.
This is a shutdown-only drain, not media pacing or a new network timeout. The
loopback gate requires the peer's control receiver to report closure within
two seconds, including the local stop, without additional input, and preserves
already queued control messages before the terminal error. A passing loopback
is not a substitute for actual LoginWindow-to-Aqua timing.

Do not infer replacement trust from an unchanged workstation UUID. Graphical
roles have independent leaf keys but now share a machine signing authority;
the Client verifies that chain against its persistent machine-public-key pin
before authentication. This does not enable Linux's early worker-replacement
probe on macOS or change the existing reconnect timing. Reconnect still
requires fresh authentication and exact current graphical ownership.

Control GET requests no longer append the inherited dummy `uniqueid` and
random `uuid` query fields. The shared Client applies this to Linux and macOS;
real operation parameters and the bearer header are preserved. Mac discovery,
topology and app-list endpoints accept their exact paths only. The Host's
persistent `uniqueid` in the discovery response is still required and is not
the removed request field. On Linux, retained input uses an internal fixed
desktop key within the existing single graphical worker, never a query value.

The graphical agent owns its virtual display in-process, with no detached
display child. The machine coordinator waits for the exact graphical process's
kernel exit event before releasing its exclusive slot; an IPC retirement
acknowledgment is not enough. The short-lived account verification child
retains its separate bounded timeout and cannot capture or post input.

Sign-in and desktop advertise and select the same qualified display modes.
The sign-in agent bootstraps at 1920x1080 before discovery; an authenticated
`/plank/display` request selects the bookmark resolution before streaming.
The Client sends that same resolution again after a graphical-role transition.
Preparation verifies actual pixel and logical dimensions and fails explicitly
if they do not match; SCStream output scaling is not a display-mode substitute.
Both roles retain independent virtual-display identities and the same bounded
scope-checked transaction. This does not extend input or capture authority.

The experimental role-private startup directory is owned by that role's UID,
mode 0700. `host.conf`, `identity.plist`, `cert.der`, `key.der`, `cert.pem`, `key.pem`
must each be regular, non-symlink, mode-0600 files owned by the same UID. The INI
uses the production name/port schema; the identity plist contains only UUID.
Synthetic qualification listens on loopback; installed workers listen on all
interfaces. PEM and DER must
represent the same certificate and PKCS#1 RSA private key; the native Security
identity validates the key/certificate pair. This is developer startup wiring,
not the final administrator configurator. Never copy the machine service's
private key into a user-readable directory to make this work. Installed desktop
roles obtain a machine-signed server leaf through the existing coordinator
before opening a listener. LoginWindow retains the machine certificate. The
Client pins their common machine public key; the public workstation UUID is
not a cryptographic trust anchor. See [Host identity trust](../security/host-identity-trust.md).

## Development installation and reboot recovery

`install-macos-host-development.py` installs the machine coordinator as a
root LaunchDaemon and two root-owned agents in `/Library/LaunchAgents`: one
Aqua-only, one LoginWindow-only. Each Aqua process runs as its actual user.
It does not log out, reboot, disable FileVault or alter TCC. Launchd restarts
exited graphical jobs with a two-second throttle; each new graphical process must prove
its scope and acquire a fresh generation before listening. Restart policy
does not grant access or allow overlapping media owners.
The coordinator starts at boot, but deliberately does not gain automatic
crash-restart here: its in-memory old-agent retirement proof must not be lost
and replaced with an empty ownership registry while an old agent still drains.
Unattended coordinator crash recovery needs an independent old-process
retirement proof before enabling that additional restart policy.

The root sign-in identity is under `/Library/Application Support/PLANK/SignIn`,
directory 0700/files 0600. Only the public discovery values match the desktop
identity. Existing complete keys/configuration must survive reinstallation;
partial identities, symlinks or unexpected permissions fail closed. Sign-in
logs belong in `/Library/Logs/PLANK/host-sign-in.log`.

LoginWindow selects a 1920x1080 bootstrap canvas before discovery. It never
selects a desktop account or types an OS password automatically. A successful
PLANK authentication reports `desktop_stage=greeter`; the Client requests its
saved bookmark resolution in both sign-in and desktop. Scope changes revoke the old stream; the
Client must authenticate again. The desktop agent still runs as its OS user.

The system-wide Aqua worker prepares missing TLS files as its non-root user,
publishing a private directory atomically without replacing existing keys.
Configuration is `/etc/plank/host.conf`, root-owned0644 in a root-owned0755
directory. Workstation UUID is separate identity-only state in
`/Library/Application Support/PLANK/identity.plist`. The installer converts and
retires the old public plist, not the runtime. The separate SignIn directory remains0700.
Desktop logs are opened inside the signed app with the user's authority.
New-user and account-isolation qualification remain open despite the accepted
single-user LoginWindow input, logout/login and cold-boot test.
The existing desktop can be preserved while installing the next-login job;
installation itself does not prove the cold-boot gate.

Both install and uninstall wait for graphical process exit as well as launchd
deregistration before stopping the machine coordinator. A timeout fails closed,
not a forced process kill or a new coordinator over a still-draining worker.
Uninstall removes only verified product launch entries and moves the app into
a printed root-only recovery directory. User and system settings, keys, logs,
accounts and macOS consent are preserved; reinstall can reuse the same identity.

Opening the signed PLANK Host application requests its own Screen Recording
and input consent. Probe consent does not transfer across bundle IDs.
The permission window does not start a listener or a remote session.
`--check-permissions` instead performs non-prompting screen/input preflights in
the calling graphical context and emits JSON. It explicitly does not qualify
desktop audio-tap consent. Run the installed signed app in the actual user's
Aqua domain, not through plain SSH as a substitute. The development installer
now rejects changes to the installed Team ID/designated signing requirement
before changing state or stopping services. The multi-user provisioning and
OS-update qualification sequence is in `macos-provisioning.plan`.

## Trust boundary

`agent-registry.m` is the machine side. It installs the peer signing requirement
before activation; XPC checks it on every message. UID, PID and audit-session
ID come from XPC, never request fields. Supply an immutable, role-specific
designated requirement from protected product code, not a peer or environment.
Tests derive their own exact requirement; ad-hoc signing is not distribution
signing or the final installation policy.

The machine observer verifies graphical access for the peer audit session and
agreement with the current console account/phase. This selects a candidate;
it does not prove remote-user authorization or the agent's current on-console
permission. The graphical agent must independently validate its own scope,
permissions and geometry, with latched revocation on notifications.

`auth/graphical-authority.m` provides that local session check, replacing the
desktop-only observer. Its constructor requires an explicit desktop or sign-in
role; plain init and unknown roles are denied. Both require Security graphic
access, positive CoreGraphics on-console/UID/login state, and matching console
identity. Sign-in additionally requires actual root LoginWindow and
login-complete=false. Desktop requires the non-root account and membership UUID.
Neither an absent desktop nor root Background grants access. Notifications and
per-read checks latch revocation; no object can switch roles. Input/capture
consent and topology remain separate checks, not implied by this object.

Starting the screen saver or locking the same console is not logout: retain
the existing PLANK connection while macOS presents its own lock/unlock UI.
The distributed screen-lock notification no longer tears down the authority.
Session resignation (user switching), system sleep, loss of on-console graphic
access, account/audit-session replacement and explicit revocation remain
terminal. Unlock notifications never restore a revoked lease. This policy does
not suppress the saver, type credentials, bypass OS unlock or transfer authority
to another account. Synthetic lifecycle tests exercise the actual authority and
authentication lease against simulated OS state and process-local notifications;
live capture/input during lock/unlock remains a separate qualification gate.

macOS 27 initial boot uses a second, positively qualified sign-in representation:
the graphical UID resolves to the local `_windowserver` account (not a hardcoded
UID), username `unknown`, on-console true and login-done false. There is no named
console owner. Both OS session IDs in that record must match the agent's actual
Security/XPC audit session, and exactly one such active record must exist in the
system-owned console SessionInfo. The graphical agent additionally requires the
same current CGSession record and root real/effective UID with graphic access.
The machine coordinator checks the root signed peer's kernel-reported identity
against the same system snapshot. Missing, malformed, duplicate, completed or
foreign-audit-session records deny access. This is not a root Background fallback.

`agent-connection.m` verifies the machine's signing requirement and OS-reported
UID. Its trusted local-scope predicate must remain valid. Neither registration
nor its generation grants remote capture/input; those also require a verified
principal and current desktop/session authorization.

## Scope-bound account admission

`authenticationScope:` returns only the exact currently admitted lease's phase
and generation. A desktop account is resolved from its OS-reported UID through
membership services, not request fields. Sign-in requires the positively
identified root LoginWindow agent and has an empty desktop account. Unknown,
foreign, retired or lost leases yield no authority; scope is checked again after
directory resolution. This method belongs on the registry owner queue and is
an authentication-lane operation, not a per-frame/per-input directory lookup.

The existing authentication/token owner now accepts an explicit graphical
scope. Sign-in admits a verified non-root remote principal; a desktop admits
only its verified UID/UUID owner. Phase or generation changes invalidate pending
challenges, unclaimed tokens and active stream leases. Reusing a generation
across phases cannot preserve access. Fresh authentication is required after
replacement; no serialized opaque stream lease or inherited root authority.
The standalone HTTPS probe explicitly selects the desktop-only role.

When the auth lane synchronizes a snapshot onto the registry queue, registry
callbacks must not synchronously call back into that auth owner. Revoke local
agent authority before scheduling drain; avoid reverse queue/lock ordering.
This admission snapshot does not replace the graphical agent's own positive
session and permission checks at capture/input delivery. Those checks and real
resource cleanup still need wiring into the persistent service.

On the graphical side, compose the auth provider as
`[agent bindGraphicalScope:[authority snapshot]]`. This is the connection's sole
cross-queue method. It binds fresh local identity to the machine generation
without synchronously entering the IPC queue or invoking callbacks under its
short lock. A local generation/phase/account change remains terminal even though
the returned generation is the machine's. Its two-second freshness deadline
expires independently of the IPC queue; neither a late response nor a restored
local snapshot can renew expired admission. Revocation clears the view before
notifying its owner. Only valid service acknowledgments refresh it.

The A/V/input owner's native-QUIC lifecycle test exercises this composition:
service revocation, service loss, stalled IPC and local-generation replacement
stop input/media and the endpoint. The delayed-capture case cannot retire its
agent until the actual stream owner reports its capture/input/endpoint drain.
These tests use synthetic capture/input and a real native endpoint, not live
ScreenCaptureKit, real display retirement or an installed service.

## Typed private protocol

Exact XPC dictionary keys/types are required. Numbers are uint64, version is 1.
No passwords, images, input, paths, process IDs or shell commands are accepted.

| Operation | Additional fields | Meaning |
| --- | --- | --- |
| Register, 1 | phase: 1 LoginWindow, 2 desktop | Machine scope and kernel peer identity must agree. |
| Check, 2 | generation, sequence | Validate this connection's lease. |
| Retired, 3 | generation, sequence | Agent reports local cleanup complete. |
| Revoke, 4 | generation | Machine-to-agent notification. |
| Issue identity, 5 | csr (1–16384 public PEM bytes) | Short-lived desktop-only connection; code-signature and kernel/OS scope checked before signing and again before reply. |

Replies contain version/status and, on success only, generation. Status 0 is
success, 1 busy, 2 revoked/retired. Generation is a random nonzero uint64 bound
to the exact connection. Sequence starts at one and increases by exactly one.
Malformed, extra, unknown, replayed or one-way requests close the peer and revoke
any lease. Linux protocols and shared feature flags are unchanged.

Operation 5 does not acquire a graphical lease and accepts no UID, file path,
private key or requested extensions. Its success response has exactly
`version`, `status`, `certificate` (PEM), `der` and `authority` (DER); each public
certificate is bounded to 16384 bytes. Its link closes after the reply. There
is at most one signing operation on a separate serial lane, with bounded crypto
children; health and ownership checks stay on the coordinator queue. Failed
or late issuance cannot start a listener or write a certificate from a late
callback. This additive private operation has matching workers/coordinator
in the same package; it is not a negotiated network feature.

One exclusive agent slot, at most four admitted links, five seconds to register.
The graphical side permits one outstanding request, a two-second reply/freshness
deadline and approximately two health checks per second. Both use their owner's
serial queue, without an unbounded work queue. A 250-ms backup check
does not replace notification revocation or authorization at media/input delivery.

## Replacement ordering

Revoke first, drain media/input, retire the display owner, then acknowledge
retirement. The trusted machine controller independently verifies cleanup and
calls `completeRetirement` with the exact old lease object. Only that releases
the exclusive slot. Neither peer loss nor its acknowledgment proves that old
resources disappeared. Failure to prove cleanup remains blocked; no automatic
reboot or blind timeout-based grant. Late old callbacks cannot release a new slot.

XPC interruption is terminal for the graphical lease: never allow XPC's implicit
reconnection to renew authority. A late OK reply cannot revive a revoked agent.
Normal owners call `stop` explicitly; autorelease lifetime is not synchronous
shutdown. Deallocation also invalidates/cancels. Use autorelease draining on
long-lived serial work queues.

Outgoing create* connections must be activated before final release, even when
cancelled before registration; listener-delivered peers differ. Constructor
denial, never-started and early-local-denial tests cover this. Retirement replies
use a send barrier before cancellation so synchronous controller cleanup cannot
discard the acknowledgment.

## Qualification and next integration

The component suite uses real anonymous XPC with synthetic scope failures.
Native mode also verifies actual graphical/kernel identity. A separate harness
boots a temporary system Mach service and a different process in LoginWindow
or Aqua. A signed root Background peer falsely claiming graphical scope must
be rejected by the machine observer, before a real graphical agent is accepted.
It tests health, registry-bound authentication/stream-lease invalidation and
explicit empty-resource cleanup, not media or remote login. The synthetic
verifier is linked only into that harness; no real credentials or input are
involved. Exact results and pending contexts are in HANDOFF.

Next wire verified remote admission, fresh per-agent grants, real capture/input/
display drain and stable control availability into these components. Keep
capture/encoding out of the machine coordinator. Persistent installation,
login/logout continuity and ordinary Ubuntu Client wiring remain unqualified.
