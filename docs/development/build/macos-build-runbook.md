# macOS development build notes

Status: experimental macOS Host; standard PKG qualification is in progress.
Authorized GitHub-hosted builders are documented in [github-builds.md](github-builds.md).
The local sequences below apply only when use of the dedicated development Mac
is authorized. Linux builder roles are unchanged.
Require Apple Silicon, macOS 27, SDK 27 and explicit deployment target 27.0.
Probe signing/installation remains documented in `probes/macos/README.md`.

Before updating Mac sources, inspect the canonical clone's `origin`: the
dedicated builder was seeded from a retained bootstrap Git bundle, not a live
GitHub remote. `fetch origin` in that clone does not retrieve newly published
commits. Transfer and SHA-256-verify a current Git bundle, fetch its explicit
ref with `--recurse-submodules=no`, then create the clean detached worktree at
the verified commit. Do not infer that a successful fetch means main is current.

## Click-through installer

Use `scripts/package/build-macos-host-pkg.sh CLEAN_SOURCE NEW_OUTPUT TRANSPORT_ARCHIVE`
on the dedicated Mac. Read `docs/development/plans/macos-installer.plan` for uncompleted live gates.
The destination Mac needs neither Python nor developer tools. The package owns
the app payload at `/Applications/PLANK Host.app` and three system launchd
entries. Bash pre/post-install scripts create administrator configuration,
private identity and administrator-readable system logs. Private state is not a
payload and survives uninstall.
There is no compiled installer helper or persistent installation service.
Prepare/validate persistent state and logs in preinstall, before worker shutdown.
The .82 real install found root-owned logs changed to directory0744/files0644;
the postinstall-only strict mode check stopped after replacing the app. The
installer validates existing logs before shutdown, preserves their contents,
and sets `/Library/Logs/PLANK` to root:admin mode0750 and its machine/sign-in
logs to root:admin mode0640. Administrators can read these logs without sudo;
only root can write, and other users have no access. Upgrades apply the same
policy to previously root-only logs. Foreign owners, links and objects writable
by non-root remain rejected. Do not use recursive chmod/chown or weaken
private-key checks. Per-user `~/Library/Logs/PLANK` remains0700/files0600.
The isolated filesystem test covers clean creation, permission drift, upgrade
from0700/0600, unchanged contents/private keys, and unsafe-object rejection.
All three launchd definitions must carry `AssociatedBundleIdentifiers` pointing
to `la.instinctual.PLANK.Host`. Otherwise Background App Activity falls back to
the signing certificate's publisher name rather than PLANK Host. Keep the
development installer consistent. Package tests check the association against
the app Info.plist; no certificate rename, TCC reset or global BTM reset is
needed. Verify the displayed grouping after an actual package upgrade.

Export `PLANK_BUILD_BRANCH`, `PLANK_MACOS_SIGNING_IDENTITY` (Developer ID
Application SHA-1), `PLANK_MACOS_INSTALLER_IDENTITY` (Developer ID Installer
SHA-1), `PLANK_MACOS_TEAM_ID`, and `PLANK_NOTARY_PROFILE` (Keychain profile name).
For local interactive signing, never supply a password in a command argument,
environment or repository file. Protected disposable GitHub signing uses the
narrow per-step secret/Apple-tool boundary documented in `github-builds.md`;
do not run that helper on an operator's Mac or shared runner.
The Mac App Store installer certificate is not the Developer ID Installer.
Use `notarytool store-credentials` interactively once; it requires an Apple
app-specific password generated through the Apple Account website, not the
ordinary Apple Account login password. Its purpose is builder authentication
to notarization, not end-user authentication or App Store publication.

Keep keychain unlock, signing and notarization in the same SSH TTY session.
The PKG runner calls the full Host build with `PLANK_MACOS_DISTRIBUTION=1`:
Developer ID, hardened runtime and secure timestamp, without Python development
scripts in the application. The shared lifecycle functions and uninstall entry
point are assembled into `Contents/Resources/uninstall.sh` before application
signing, so the script is covered by the app resource seal. Test the shell hooks;
build, sign, notarize, staple and assess the single receipt-backed Host package.
Do not generate a separate uninstall PKG. `macos_pkg_gate=pass` does not prove install,
permission continuity, reboot or streaming acceptance. No `installer -pkg`
invocation is part of the build. Do not publish a rejected/pending artifact.

The normal graphical workflow is to open the Host PKG, approve Installer, then
open PLANK Host in Applications for privacy setup. Uninstall with the installed
script (administrator authorization is required):

```bash
sudo "/Applications/PLANK Host.app/Contents/Resources/uninstall.sh"
```

It stops services and removes the app/startup entries while retaining settings,
identities and logs. It forgets the Host receipt and does not reset permissions
or reboot. The script is self-contained and parsed before it removes its own
app bundle; it does not source code from mutable configuration or user paths.
Reinstall the signed Host package to recover or restore the product.

Installer scripts only accept `/` as the target volume; uninstall accepts no
arguments and uses the running system. Both require macOS27/arm64. Installation
requires FileVault off; uninstall remains available if it was later enabled.
They verify existing app product/team/type and owned startup entries before
stopping services. It admits the explicitly planned same-team Apple Development
to Developer ID transition; that is not proof that TCC grants survive. Test the
transition with the user available for permissions. Do not widen the signed
worker-to-worker XPC requirement to compensate for a packaging/signing change.

There is no custom rollback database or growing set of old application copies.
On installation failure, inspect Installer Log and rerun the signed installer;
existing configuration and keys are not overwritten. Do not claim macOS Installer
provides automatic service rollback. `bash tests/packaging/macos-pkg-scripts.sh`
tests mocked launchd lifecycle without privileges; `--filesystem` additionally
requires root and creates/removes an isolated fixture under
`/Library/Application Support`, without touching product services or files.
These are developer qualification commands, not operator instructions.
For command-line signature requirements, `codesign -R` needs a leading `=` for
inline requirement text; otherwise it treats the expression as a filename.
After this validation-command error, recheck the already signed binary and
continue packaging; do not rebuild the Host or change its signing identity.
For non-installing GUI metadata validation, use
`installer -showChoicesXML -pkg ABSOLUTE_PACKAGE -target /`.
Omitting `-target /` returns failure even when the package is valid.

## Native Host executable and application

The non-posting pen construction fixture needs a WindowServer connection.
If the SSH build account differs from `/dev/console`'s owner,
`CGEventSourceCreate` may return NULL (`pen failure line28: source`), including
for an unchanged previously passing binary. Authenticate `sudo -v` in the build
TTY before starting; the runner uses `sudo -n launchctl asuser CONSOLE_UID`
only for this fixture. Compilation and signing remain unprivileged. It posts
no input and changes no TCC settings or services. Do not skip the test, change
the console login, or rebuild dependencies to work around the session boundary.

### Opt-in capture frame timing

Detailed ScreenCaptureKit/VideoToolbox frame tracing is disabled by default.
For an authorized diagnostic, set `PLANK_MACOS_FRAME_TIMING=1` in the capture
worker's process environment before starting it, then start a new stream.
Only the exact value `1` enables tracing; unset, empty, `0` and other values
leave it disabled. This is a runtime diagnostic, not a build option, Client
preference or encoder setting. An export in an SSH shell does not modify an
already-running launchd worker; configure the actual graphical worker's launch
environment, not the machine coordinator or account verifier. Do not interrupt
an active session to enable it without operator approval.

The setting is sampled once per capture session. Enabled traces retain at most
8,192 numeric records from the first 120 seconds, with no frame content. They
are dumped to the worker's existing product log only after capture callbacks
have drained. The existing `scripts/test/analyze-macos-frame-timing.py` consumes
that format. Remove the diagnostic environment setting and restart the worker
afterward; do not ship it enabled in a launchd definition.

Default operation allocates no detailed trace buffer, performs no trace-only
timestamp sampling and emits no frame-timing dump. Normal error logging and
the compact `PLANK capture summary` remain enabled. The Host build runs
`tests/video/macos-frame-timing.c` to check default-off/invalid values, explicit
opt-in, silent disabled output, bounded recording and unchanged dump format.

### Non-prompting permission qualification

Follow `macos-provisioning.plan`. The installed signed Host supports
`--check-permissions`; use `sudo python3 tests/auth/macos-permission-check.py
--uid ACTUAL_CONSOLE_UID` after the operator logs into the account under test.
The runner launches one temporary Aqua job, waits for a **numeric** launchd
exit code (the initial `(never exited)` value is not completion), prints the
JSON and removes the job. It cannot log a user in, capture, post input, request
consent or provision a missing desktop worker. Exit0 is screen/input preflight
readiness,3 is a negative result,2 is an app diagnostic error. Audio-tap consent
remains explicitly unverified. Plain SSH may report denial even when the same
UID's Aqua check passes; do not reset permissions on that evidence.

The development installer verifies the candidate and installed signatures and
requires matching Team IDs and designated requirements before any state write
or service stop. `codesign -d -r-` emits the requirement on stdout and diagnostics
on stderr; the parser accepts either stream but rejects ambiguity. A signer
transition is a provisioning decision, not a build repair. Do not bypass this
guard or switch to ad-hoc signing. Run
`python3 tests/auth/test-macos-development-install.py` for its failure cases.

### Assembly and install

The Host build runs the production Opus synthetic fixture, including signed
source-clock jumps and byte-identical PCM encoding. For audio adapter changes,
also run `build-macos-native-audio.sh` with the retained synthetic402-packet
fixture and current ABI archive; it verifies real QUIC delivery across marked
PTS epochs plus revocation. Neither test captures or plays audio. Live audible
playback and synchronization remain separate acceptance checks.

The Host build runs `macos-audio-tap-lifecycle.m` against the production tap
class with HAL prepare/activate/destroy overridden only in the test executable.
It requests no consent and opens no audio devices. Require pending cancellation,
late-consent suppression, one-tap reconnect bound, denied startup, active drain
and100 race checks. A pass is not live permission-dialog/input acceptance.
The signed product must still be tested from the fresh user's actual Aqua
session; do not substitute a plain SSH permission check or reset TCC.

The Host build also runs `macos-output-volume.m` (synthetic HAL reads) and
`macos-audio-recovery.m` (the actual capture audio controller with fake tap/
encoder boundaries). These check master/channel/mute/fixed-output policies,
failed reads, teardown before restart, retry limits, denied startup and stop
cancellation. They never open an audio device or request consent. The portable
ring test includes overflow recovery without overwriting unread blocks. A
passing build does not establish live output-volume behavior or the cause of a
reported audio interruption; check the product's reason/overrun/restart logs.

For system-alert source qualification, compile
`probes/macos/alert-audio-processes.c` with SDK/target27, warnings-as-errors,
`-Iapps/host/macos/media` and CoreAudio/AudioToolbox/CoreFoundation/Security frameworks.
Run `sudo python3 tests/audio/macos-alert-audio-processes.py ABSOLUTE_BINARY`:
the default is silent, non-capturing actual-console identity qualification.
`--play-alerts` explicitly emits three preferred alert sounds over12seconds
while reporting HAL output transitions. The probe has a20second hard limit,
and the fixture removes its temporary Aqua job. Never run this on the read-only
reference Mac. The actual Host's audible delivery and physical speaker muting
still require separate live acceptance.

The development installer now waits for both job deregistration and observed
process exit after `bootout`, before replacing code or restarting the machine
coordinator. It stops graphical jobs in existing OS-account GUI domains first.
Inspection errors are not absence. A 20-second drain timeout stops installation;
never force-kill a Host or retry bootstrap while its old process still drains.

System-wide candidates use one root-owned Aqua agent in `/Library/LaunchAgents`.
Install with `sudo python3 scripts/maintenance/install-macos-host-development.py --app APP`.
For the two explicitly provisioned development accounts, add
`--retire-user-agent operator --retire-user-agent permission-test-user` on the first
upgrade only. These old user jobs are renamed to `.plist.retired` with permanently
dropped user privileges; no home enumeration or private-key deletion occurs.
The shared public configuration is `/Library/Application Support/PLANK/host.plist`
(root/0644, parent0755); LoginWindow keys remain in `SignIn` (root/0700/0600).
Desktop keys and logs are created by the signed app as the actual user, never
by root launchd following a user-writable log path. This does not grant consent.

The signed app includes the development uninstall command:
`sudo python3 "/Applications/PLANK Host.app/Contents/Resources/uninstall-macos-host-development.py"`.
It drains the same jobs, removes only verified PLANK system launch entries,
and moves the app to a printed root-only recovery directory in `/Library/Caches`.
Configuration, identities and logs remain for reinstall; no TCC reset or user
account removal. This is Python3-based development tooling, not a notarized
production installer/uninstaller. The1.0.77 dedicated-Mac install/uninstall/
reinstall test passed. Repeat after lifecycle changes using
`tests/auth/macos-install-uninstall.py --source CLEAN_SOURCE --app SIGNED_APP
--sha256 EXECUTABLE_SHA256`; add explicit `--retire-user-agent USER` only when
upgrading a prior per-user development job. The operator must disconnect first.
The fixture records no private-key contents; it checks identity metadata,
configuration, logs, signatures, actual Aqua preflights and listener removal/
restoration. It deliberately does not log out, reboot or qualify live media.

For LoginWindow candidates, run
`python3 tests/auth/test-macos-development-install.py` and the Client's
`tests/desktopstage` suite. The development installer now registers a
LoginWindow-only agent as well as the designated user's Aqua agent. It never
logs out or reboots for testing. See `macos-session-lifecycle.md` for its
role-private identity files, restart policy and remaining live acceptance gates.
ABI-13 candidates must rebuild the transport archive; never link an ABI-12
archive to the larger stats header. Preserve accepted .57's
`PLANK_MACOS_SOURCE_FIRST=1` feature selection during that rebuild.

Use `scripts/build/build-macos-host.sh SOURCE EMPTY_OUTPUT RETAINED_TRANSPORT_ARCHIVE`
on the dedicated Mac. Set `PLANK_MACOS_HOST_VERSION` explicitly, for example
`1.0.64-macos-hevc444`. Use the base packaging version on main and append the
actual feature branch otherwise; do not keep the historical `macos-host`
qualifier on unrelated branches or main. Both build and development install
accept that shared semantic-version/branch shape. The full native Host links with SDK/target 27 and
warnings-as-errors; no probe main or synthetic verifier is linked. The default
uninstalled executable is ad-hoc signed for assembly checks. Supplying the
existing `PLANK_MACOS_SIGNING_IDENTITY` also builds Apple-signed `PLANK Host.app`
with its own `la.instinctual.PLANK.Host` identity. Unlock the signing keychain
in the same SSH TTY. No Rust rebuild, Linux package or persistent service install.

The signed Host bundle uses `branding/assets/plank-logo.png`, the same approved
artwork as the Client. `scripts/package/macos-app-icon.m` creates a transparent,
aspect-preserving macOS iconset using native CoreGraphics/ImageIO; `iconutil`
packs it as `Contents/Resources/plank.icns` before signing. Do not copy the
Client's dormant upstream macOS `moonlight.icns`. Verify the Info.plist icon
reference,10 standard variants (16–1024pixels), transparency and strict bundle
signature. ICNS unpacking may re-encode PNGs; different compressed file bytes
alone are not an image or packaging failure.

`sudo python3 tests/auth/macos-host-service.py SOURCE BINARY SHA256 DESKTOP_UID`
tests the real executable with temporary system/Aqua jobs, role-private keys,
TLS discovery, unauthenticated topology denial, graceful stop and replacement
on the same desktop. It does not require logout/login, credentials, TCC, capture
or OS input. Temporary shared executable/log parents must be under `/private/tmp`,
not root's inaccessible per-user TMPDIR; graphical logs must belong to the
graphical UID or launchd returns EX_CONFIG before the executable runs.
The fixture canonicalizes the RSA key to PKCS#1 PEM to match its DER; req's
default PKCS#8 PEM must not be mistaken for the same byte representation.
Generated keys and both jobs are removed on exit.
When testing an Apple-signed application executable, keep the whole app bundle
including its Info.plist; a bare extracted Mach-O fails strict signature checks.
The runner detects this case and copies/verifies the complete bundle.

The existing `build-macos-preview.sh` now links `host-runtime.m`; its HTTPS
qualification launcher no longer duplicates stream creation or invents a
one-second cleanup delay. Its synthetic launch/transport tests remain useful
automated coverage of the real runtime, not the next operator milestone.

## Machine/graphical-agent IPC qualification

Build `bash scripts/test/build-macos-agent-registry.sh SOURCE_ROOT EMPTY_OUTPUT`
on the dedicated Mac, SDK/target 27, warnings as errors. Include both modules
under `apps/host/macos/session`, authentication and graphical-authority sources/headers,
both agent tests, the service
plist and the two build/test scripts in the hash-verified source set. No Rust
rebuild, TCC permission or app replacement. The test executables are ad-hoc
signed to pin their exact code, not as a product distribution policy.

The build runs `agent-registry --synthetic`: 239 checks over real anonymous XPC
with synthetic scope observations. Require a clean process exit, including
autorelease teardown. A previous run printed passing assertions but trapped
when an inactive outgoing XPC object was released; that was a failure, now fixed.
Pending-peer expiry tests must cancel on XPC interruption, not silently reconnect.

To check actual graphical identity, run the uninstalled `agent-registry` binary
through the existing graphical runner with no explicit mode argument. Use root
for LoginWindow or the actual desktop user for Aqua. Default mode requires a
positive graphical scope; `--synthetic` does not.
Native mode includes seven admission-snapshot checks (254 total): phase,
generation, OS account, and nil/foreign/revoked lease denial.

For cross-process qualification, run as root on the dedicated Mac:

```bash
sudo bash scripts/test/test-macos-agent-service.sh SOURCE_ROOT \
  /absolute/output/agent-peer VERIFIED_SHA256 ALLOWED_DESKTOP_UID
```

Discover the UID; never assume 501. The runner hash-verifies a root-owned
temporary executable, boots a uniquely named system Mach service, proves
rejection of a signed Background peer, then launches the actual graphical agent.
Expected: `agent_service_cross_process_pass=1 persistent_install=0 media=0 input=0`.
Require `agent_service_admission=1 synthetic_verification=1` and
`agent_service_admission_revoked=1` too. The test links a synthetic verifier to
the production conversation/stream-lease owner; no account password is supplied.
Require `graphical_agent_bound_scope=1` for the graphical authority plus admission
view. The agent uses the production explicit-role authority, not the older
probe-only session helper. The control build also produces
`graphical-authority-test`: run it with no arguments through the graphical runner
(16 checks) and directly with `--background` from SSH (13 denial checks).
Root Background must deny local graphical authority too. No TCC or input involved.
An EXIT trap removes both exact jobs and all generated files. No persistent
installation, app replacement, capture, input, credentials or network listener.
See `macos-session-lifecycle.md` for what these tests do and do not prove.

## Native keyboard/mouse qualification

Use the dedicated Mac only. For the non-posting component tests:

```bash
bash "$source_root/scripts/test/build-macos-input.sh" "$source_root" \
  "$PLANK_WORK_ROOT/input-candidate" \
  "$PLANK_WORK_ROOT/transport-build-e451f24/release/libplank_transport.a"
```

Output must not exist; UDP 47494 must be unused. Reuse the retained ABI-12
transport archive (hash in HANDOFF), not a new Rust/dependency build. Expected:
1826 event checks and 129 native input checks/seven scenarios. Both suites post
zero OS events. Include **`protocol/plank-transport/include/plank_transport_input.h`**
in a standalone copied qualification source set; earlier audio sets did not need
that header. The input runner now checks for it before compilation. Standalone
copied inputs are not a clean release checkout; record their verified hashes.

For actual delivery, first have the operator unlock the desktop. A logged-in
console owner alone does **not** mean the screen is unlocked. Do not enter
credentials, change lock settings, or weaken the owned-window focus guard.
Build the focused signed test in the **same SSH TTY** as keychain unlock:

```bash
security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
# Enter the password interactively. Export the existing signing identity.
bash "$source_root/scripts/test/build-macos-input-delivery.sh" "$source_root" \
  "$PLANK_WORK_ROOT/input-delivery-candidate"
```

The current delivery app is Probe **56**, with separate `--input` and
`--login-pointer` modes, and is not the authenticated A/V app. The ordinary
owned-window input mode remains non-root/Aqua-only. Preserve/hash-verify the installed A/V app and its signed
backup before temporarily replacing it at the approved application path.
Verify installed ownership root/755, signature and executable hash, then run as
the actual desktop UID (never assume 501):

```bash
bash "$source_root/probes/macos/run-graphical-probe.sh" "gui/$(id -u)" \
  "/Applications/PLANK Host Probe.app/Contents/MacOS/plank-host-probe" \
  "$source_root/probes/macos/probe-agent.plist" --input
```

The expected base mask is 1023 with `position_match=1`, modifier down/up masks
255/255, Shift-key/click true, held=true, cleanup_received=7 and released=true,
result/exit zero. Focus denial
is a safety refusal, not proof the OS rejected input. Restore and hash-verify
the tested A/V app after the test; ensure the temporary agent is gone.
Request test-window activation from `NSApplicationDidFinishLaunchingNotification`,
not before `[NSApp run]`. Probe 51 still failed focus on an unlocked desktop;
moving that one activation to the launch notification produced two fresh Probe
52 passes with no mapper/source/permission changes. Do not replace the guard
with repeated activation attempts or inject input into another app.
The input test link retains the qualified `__CGPreLoginApp/__cgpreloginapp`
Mach-O marker. Carry that gate into any later app that incorporates input; the
current A/V/input Probe 54 includes it too. The marker does not bypass TCC
or qualify LoginWindow delivery. See `macos-input.md` for remaining gates.

### Operator-observed LoginWindow pointer

Probe 56 adds `probes/macos/login-pointer.m` and the existing
`session-boundary.h` to the input-delivery build. Copy/hash-check those plus the
updated build script, entry point and graphical runner. The source still uses
the unchanged production input mapper and private Quartz source. Require positive
LoginWindow identity and existing consent before creating input; recheck session,
display identity, point/pixel geometry and consent before every post. Background
SSH, including root, is not LoginWindow. Never weaken these predicates.

With the operator watching and the Mac actually **logged out**, temporarily
install the verified signed Probe 56 and run:

```bash
sudo bash "$source_root/probes/macos/run-graphical-probe.sh" loginwindow \
  "/Applications/PLANK Host Probe.app/Contents/MacOS/plank-host-probe" \
  "$source_root/probes/macos/probe-agent.plist" --login-pointer
```

It moves to approximately 25%/25%, then 75%/75%, then restores the original
position, with two seconds to observe each. No click, key, capture, login action
or permission request. A session/geometry change stops delivery; it will not
restore into a newly logged-in user's session. Expected: three observed matches,
restored=1, no_held_input=1, result=0. This is numerical event-position evidence;
ask the operator separately whether the cursor was visible. It does not prove
LoginWindow button/keyboard delivery or authenticated cross-session handoff.
Restore/signature/hash-check the retained A/V Probe 54 afterward. Probe 56's
new mode passed numerically on September 7; its unchanged `--input` path was
compiled but not rerun while the operator remained logged out.

## Embedded cursor qualification

Build `bash scripts/test/build-macos-embedded-cursor.sh SOURCE_ROOT EMPTY_OUTPUT`
on the dedicated Mac, in the same signing/keychain TTY. This produces **Probe
55**, accepting only `--cursor`, not the authenticated A/V entry point. Copy
and hash-check the new source, script and updated graphical runner together.
Temporarily install at the consented app path only after verifying the retained
Probe 54 backup; restore and hash-check that backup after the test.

Run the existing graphical runner in `gui/$(id -u)` with `--cursor`. LoginWindow
is refused. This test requires an unlocked desktop and existing capture/input
consent; it never prompts, logs in or changes TCC. It requests focus once after
AppKit launch, checks owned focus before movement and capture analysis, posts
motion only, and restores pointer/foreground app when still safe. The SCK filter
includes only its own test window; no audio, credentials, saved images, clicks
or keys. It stops after 18 seconds with a 30-second hard process deadline.

Expected: phases 0–4 each report match=1, completed=5 and result=0. The phases
prove cursor-disabled absence, custom shape/hotspot, changed position, changed
shape, and disabled absence again. Two matching samples are required per phase.
The changing gray test background forces fresh capture updates. Coordinates use
the actual display's point/pixel ratio; this is not a qualification of every
display configuration. The check inspects BGRA before encoding; it does not
measure cursor latency, HEVC decoded quality or ordinary Client presentation.
Two independent launches passed on September 7. Exact hashes are in HANDOFF.

## Isolated capture cadence (no transport)

`scripts/test/build-macos-capture-cadence.sh SOURCE EMPTY_OUTPUT` builds signed
Probe58 on the dedicated Mac, SDK/deployment27, with the existing signing
identity. No Host/Client/runtime library is linked. Preserve the current signed
`PLANK Host Probe.app`, temporarily install this probe at its consented path,
and restore/signature/hash-verify the original afterward. Keep the separate
installed `PLANK Host.app` untouched and require no active stream during tests.

Run through `probes/macos/run-graphical-probe.sh gui/UID ...` with
`--cadence-60` or `--cadence-native`. Both inspect the current main display at
its real pixel dimensions using the Host's xf20 full-range capture format,
SDR/sRGB and three surfaces. Only the minimum frame interval differs:1/60 or0.
No encoder, network, audio, pixel mapping, retained samples, focus/input events
or permission requests. Require existing capture consent. Count all
sample statuses, not just complete frames. Record numeric callback/PTS/status
rows in bounded memory; flush only after stop. Each run captures25seconds with
a35second process alarm and the runner's40second outer deadline. Alternate
both modes twice on the same unchanged moving desktop. This is capture cadence,
not proof of encoder, network, Client presentation or A/V-sync performance.

For continuous source updates independent of browser content, use
`--cadence-pattern-60` / `--cadence-pattern-native`. These temporarily cover the
current display with a nonactivating, input-transparent panel whose bar is
animated by Core Animation, not a CPU timer. The panel is hidden at completion
and disappears if the bounded probe exits. Do not assume a logged-in console
owner implies an unlocked desktop; verify scope and lock state before testing.
Report actual display geometry: restarting the Host can destroy its virtual
display and return the Mac to the1080p fallback. A probe of that fallback does
not qualify5120x2160 streaming. Discard the first2seconds of callback records
when comparing rates; use timestamp spans, not row-count divided by25 (sample
delivery can precede the asynchronous start acknowledgement).

## Transport qualification

The rejected .54/.55 submission-batching implementation, feature and extra
Quinn wrapper vendor tree have been removed. Historical source commits and
measurements remain in the sender-drain investigation; do not reuse their build
commands for a current candidate. The qualified source-first path below retains
ordinary single-datagram submission. The application datagram pacer is now
deleted, not merely bypassed.

For source-first FEC qualification, use `PLANK_MACOS_SOURCE_FIRST=1`.
This includes sender timing and enables source-first packet submission. The repair count and library's
repair encoder remain unchanged. The runner additionally checks byte-identical
source packets against the retained RaptorQ library, multi-block/sub-block
padding, recovery at 0/5/10/20% omitted sources, and preparation timing. The
timing test is synthetic CPU preparation, not a network/performance gate.
RaptorQ 2 changes repair IDs and the native QUIC protocol identifier; matching
Host and Client packages are required. See the native transport contract.

All Host builds use the shared sender policy: submit directly to Quinn and
floor the rate-derived window budget at 1 Gbps. This is
not an encoder bitrate, a measured link capacity, or a strict wire-rate cap;
Quinn still schedules transmission. Encoder settings, FEC and queue capacities
are unchanged by pacer removal. The `PLANK_MACOS_FAST_SEND` switch and
`macos-fast-send`/`linux-fast-send` Cargo features have been removed; there is
no alternate paced baseline. Linux and macOS use the same sender budget policy.
Check receiver loss as well as sender drain: immediate submission can move
drops downstream. A Linux source-first transport test does not qualify native
macOS capture, encoding, playback or package signing.

For the explicitly authorized sender-drain diagnostic only, set
`PLANK_MACOS_SENDER_TIMING=1` before `build-macos-transport.sh`. It selects the
compile-time `sender-timing` feature (off by default), retaining the current ABI
and wire/FEC policy. Build a separate verified archive; do not overwrite
the retained baseline archive. Numeric measurements are future-local, capped at
8192 frames/120seconds, and flushed only after worker join into existing stderr
product logging. No runtime preference, extra listener, Client change or live
per-frame log output. Normal feature-disabled builds remain the release default.
Run the feature's bounded-window/context-isolation tests plus both C loopbacks,
and check the feature-disabled build. See HANDOFF for exact diagnostic artifacts.

The first integration build reuses `protocol/plank-transport` and its exact
Kymux/Quinn sources, Cargo lockfile and Rust 1.89.0. No networking policy change
or macOS-specific transport replacement is implied. Passing this build is not
proof of an authenticated Client connection or media playback.

Use a canonical Git clone and clean worktree, not an archive or copied prepared
source tree. Only initialize `third_party/kyber-kymux` for this gate; neither the
Linux Host nor Client submodule is a transport build input. Seed private commits
using SHA-256-verified Git bundles; do not copy repository credentials to the Mac.
Keep the qualification script outside the clean worktree if it is not committed
yet, and record its hash separately from the source commit.
When cloning the root bundle, pass `--branch macos-host`: a branch-only bundle
does not necessarily carry a usable remote HEAD. Check the actual nested Git
commit against the root gitlink, not just directory presence or registration.

Dedicated-Mac path contract (operator account home is discovered on the Mac):

```bash
export PLANK_CANONICAL_ROOT="$HOME/dev/plank"
export PLANK_DEP_ROOT="$HOME/Library/Caches/plank-build"
export PLANK_WORK_ROOT="$PLANK_DEP_ROOT/work"
export PLANK_CARGO_ROOT="$PLANK_DEP_ROOT/cargo"
export PLANK_RUSTUP_ROOT="$PLANK_DEP_ROOT/rustup-1.89.0"
```

Bootstrap Rust once using the official `rustup-init` Apple Silicon binary and
its SHA-256 file, verifying the digest before execution. Use rustup 1.28.2,
`--profile minimal --default-toolchain 1.89.0 --no-modify-path -y` with the above
Cargo/Rustup directories. Do not edit shell startup files or install as root.
Official source/verification procedure:
[Rustup manual installation](https://rust-lang.github.io/rustup/installation/other.html).
Retain downloads, caches and exact build provenance; do not redownload them for
each build. Do not compile while collecting capture/encoder performance data.

### macOS 27 compiler-plugin loading failure

`can't find crate for tokio_macros` (or `thiserror_impl`/`serde_derive`) can mean
the dylib exists but dyld rejects its stripped LINKEDIT string pool. On the
dedicated Mac, direct dlopen confirmed `mis-aligned LINKEDIT string pool` despite
a valid code signature. This matches
[Rust issue 157750](https://github.com/rust-lang/rust/issues/157750).
The macOS runner sets `RUSTFLAGS=-C strip=none` (appended to any caller flags)
to keep compiler-plugin metadata intact. Do not lower the 27.0 deployment target,
disable signing/security, upgrade dependency versions or redownload caches to
hide this error. Revalidate whether this workaround is needed with a future
qualified toolchain; it does not change the shared Linux build.

Invoke `scripts/build/build-macos-transport.sh SOURCE_WORKTREE BUILD_DIRECTORY` with
the environment above. It runs locked release build and tests, requires the
pinned Rust version and prints the archive hash. It also compiles the shared
native C ABI loopback test with Apple frameworks and runs exact-fingerprint and
explicit certificate-approval/setup-promotion cases on loopback ports 47489/47490.
Ephemeral certificates/private keys and the loopback executable are removed on
exit. No non-loopback listener, product service or user-installable Host is
created. The test's internal token is synthetic, not a production credential.

The certificate fixture `probes/macos/loopback-cert.cnf` explicitly generates
X.509 v3; macOS LibreSSL otherwise generated v1, correctly rejected by Rustls.
Do not weaken certificate validation. The C test retains exact payload/counter
checks but waits up to two seconds for asynchronous sender completion: receiving
reconstructed media does not imply all repair symbols have finished sending.

For unpublished qualification inputs kept outside the clean worktree, set
`PLANK_MACOS_LOOPBACK_SOURCE` to the exact C test and
`PLANK_MACOS_LOOPBACK_CERT_CONFIG` to the fixture. Copy these alongside the runner
in the bootstrap directory and SHA-256-check all three against local files.
Do not claim the worktree commit includes these uncommitted test inputs.

First qualification on the dedicated Mac: root `e451f24e88ea67ebcd97d1984a39d10c0b4d23b2`,
Kymux `2ccf810609cb87fe6bdc7c0686195ab56e91465e`; release build passes,
16 enabled Rust tests pass, 2 integration/loss tests intentionally remain ignored.
Both C loopbacks pass, with about 30 ms sender-counter settling each. Two
unused Quinn telemetry warnings remain in the default-feature build. This is
not a packet-loss matrix, performance test, account-authentication test or
existing Client interoperability qualification. Exact hashes are in HANDOFF.

## Host-first audio qualification

The Host-first direction in `macos-host.plan` supersedes the older preview-first
order below. No new Client package is required for these component gates.

Use `scripts/test/build-macos-audio-probe.sh SOURCE_ROOT EMPTY_OUTPUT` on the dedicated
Mac with the existing signing identity. It builds the standalone **audio** entry
point at Probe build 46; it is not the HTTPS entry point of Probe 44 or the old
multi-mode CLI. Preserve the installed app before replacing it, verify signature
and installed executable SHA-256, and use the existing consented app location.
Unlock/sign within the same SSH TTY as described below; no keychain ACL change.

Run the installed probe in the existing user's Aqua domain:

```bash
bash probes/macos/run-graphical-probe.sh "gui/$(id -u)" \
  "/Applications/PLANK Host Probe.app/Contents/MacOS/plank-host-probe" \
  probes/macos/probe-agent.plist --audio
```

This explicitly plays a quiet two-second generated tone and captures system
audio for eight seconds. No microphone, recorded samples, display changes or
new listener. The runner removes its temporary job. Do not start this on an
unrelated user's session. SDK 27 requires AVAudioEngine's
`connect:to:format:error:` and AVAudioPlayerNode's `playAndReturnError:`; their
old counterparts cause deprecated-API errors with warnings-as-errors. Use the
modern APIs and check their errors, not warning suppression or old-OS paths.

For native delivery without live capture/playback, run:

```bash
bash scripts/test/build-macos-native-audio.sh SOURCE_ROOT EMPTY_OUTPUT \
  RETAINED_VERIFIED_LIBPLANK_TRANSPORT_ARCHIVE GENERATED_OPUS_FIXTURE
```

All arguments must be absolute. Generate the PAO1 fixture with `audio-encode.c`
as described in `macos-audio.md`; never use recorded user audio. The runner binds
loopback UDP 47493 only, uses ephemeral pinned TLS and test-only authentication,
checks exact packets/timestamps/revocation, and removes its private TLS material.
No Rust rebuild is needed: reuse the qualified native ABI-12 archive. These
copied/hash-verified standalone sources are not clean release-package snapshots.

The same runner also compiles the production `media/opus-encoder.m` and runs
`tests/audio/macos-opus-encoder.m`, producing `streaming.pao` (400 packets,
deliberately no stop-time EOF flush). Transfer/hash-check that synthetic fixture
on linux-client-builder and run `macos-opus-compatibility streaming.pao --measure-priming`.
This uses the unchanged system libopus decoder, not new Client functionality.

SDK-27 buffer-list qualification detail: pass exactly `sizeof(AudioBufferList)`
for interleaved stereo, and the two-buffer list size for planar stereo.
Passing the larger two-buffer capacity for interleaved PCM returned
`kCMSampleBufferError_ArrayTooSmall` even though the queried requirement was
only 24 bytes. Both formats now have a production-module test. Do not paper
over this with an unbounded allocation or assume all CoreMedia audio is planar.

## Historical first interactive preview boundary (superseded by Host first)

After this portability gate, implement in this order:

1. macOS account verification and session ownership behind a narrow privileged
   boundary; keep existing certificate approval and pre-session authorization.
2. Explicit ScreenCaptureKit/VideoToolbox capability tuples and synchronized
   Client profiles. Never label Apple HEVC Main10 4:2:0 as Linux NVENC 4:4:4.
3. Feed complete VideoToolbox Annex-B frames into the existing native transport;
   preserve timestamps, bounded submission, bitrate changes and keyframe recovery.
4. Wire keyboard/mouse and cursor handling, initially on an already logged-in
   desktop. This is a preview, not acceptance of the required login-screen flow.
5. Replace temporary probe orchestration with authenticated machine-service and
   graphical-agent lifecycle, then qualify LoginWindow → desktop → logout.

Audio, Wacom and notarized release packaging can follow the first interactive
preview. Authentication, exact-format negotiation and cleanup cannot be skipped
to obtain an earlier demo. Linux behavior must remain unchanged.

## Hardware encoder/native media qualification

Run `bash scripts/test/build-macos-native-video.sh SOURCE_ROOT EMPTY_OUTPUT ARCHIVE`
on the dedicated Mac. `ARCHIVE` is the exact retained, SHA-256-verified
`libplank_transport.a` from the transport gate; do not rebuild/download Rust for
Objective-C-only edits. Source inputs include `apps/host/macos/auth`, the new
`apps/host/macos/media`, `protocol/plank-transport/include/plank_transport.h`,
`tests/auth/macos-native-video.m` and `probes/macos/loopback-cert.cnf`.
Include and hash those explicitly when copying unpublished standalone inputs;
an older control-only staging directory does not contain the transport header.

The runner requires a free UDP 47491 and binds loopback only. It performs
hardware-required 1080p and 2160p synthetic HEVC tests through native QUIC,
including forced keyframe recovery. It creates and removes private ephemeral
TLS material, leaving the binary and synthetic first-frame HEVC files. It
does not request TCC, install an app or capture the desktop. The synthetic
account backend is linked only into the test executable. Preserve source,
archive and binary hashes separately; this is not a clean release build.

The optional fourth argument `--low-latency` adds specialized RTVC qualification
at3840x2160 and5120x2160. This is a paused experiment, not the .50 live encoder
configuration or a routine-build gate. See HANDOFF for the unpaced frame-drop
observation; the updated60Hz paced test has not yet been run. Do not enable
RTVC in the production Host merely because session creation succeeds.

Inspect the synthetic files with the pinned Client FFmpeg on linux-client-builder,
using its private `LD_LIBRARY_PATH`. Expect HEVC Main10, `yuv420p10le`, limited
range, BT.709 matrix/primaries and sRGB transfer. This is a component gate;
actual Client hardware decode and presentation still require a hardware target.

The native-video runner also compiles `preview-session.m`/`screen-capture.m`
and runs the synthetic-capture/input lifecycle suite on loopback UDP 47492.
Current expectation is 403 checks/15 scenarios. Include `apps/host/macos/session`
sources as well as the `apps/host/macos/input`
headers/sources, `tests/input/macos-fake-input.{h,m}`, `plank_transport_input.h`,
`plank_transport_control.h`, both media modules and
`tests/protocol/macos-preview-launch-v3.json` in standalone staged inputs.
This is not a new transport-library build. Each lifecycle test remains bounded.

The four added scenarios connect real anonymous XPC admission to the actual
authentication and native-stream owners: revoke, service loss, a stalled IPC
queue, and replacement of the local generation. Delayed capture drain must
precede agent retirement. Capture and input remain synthetic; no OS events are
posted. The fixture still constructs genuine Quartz event objects. While development-mac
is logged out, the ordinary SSH user cannot create a private CGEventSource; an
unchanged `input-events` binary then fails `source != NULL` too. Do not interpret
that as a media regression or alter the production input guard. Prefer running
as the logged-in development user. While logged out, the same synthetic build/
test command was qualified with operator-authorized sudo on the dedicated Mac;
all outputs stayed in a new explicit temporary directory, with no installation.
That root Background synthetic run is not proof of LoginWindow capture/input.

## Authenticated live preview qualification

`bash scripts/test/build-macos-preview.sh SOURCE_ROOT EMPTY_OUTPUT ARCHIVE` builds
the loopback synthetic launch server, native receiver, and a signed **PLANK Host
Probe.app** with real account verification and capture. It requires the existing
`PLANK_MACOS_SIGNING_IDENTITY` certificate fingerprint, SDK/minimum macOS 27
and the retained archive. This app entry point is the authenticated HTTPS probe,
not the older command-line chart/input probe. Preserve the previously installed
probe app before replacing it on the dedicated Mac. Do not install on the
read-only reference Mac or change TCC/keychain trust policy to make it work.

Current output is **Probe 54**, the authenticated combined audio/video/input
entry point. Its source list includes the native input adapters and public
Quartz device, linked with Carbon/ApplicationServices and the qualified pre-login
marker, alongside `native-audio.m`/`opus-encoder.m` and AudioToolbox. The fake
input device is linked only into the synthetic executable, never the signed
real-account app. The older standalone audio-only Probe 46 does not accept the
HTTPS runner's arguments; do not confuse installed app versions. Public product
discovery remains gated. The qualification launch's audio and input services
are true; its cursor remains embedded. Live receiver qualification sends no
mouse/key input, so it can validate A/V without acting on the desktop.

If signing fails with `errSecInternalComponent` despite a valid identity,
unlock the login keychain interactively and run signing/build **within the same
SSH TTY session**. A separate unlock-only SSH session may succeed, yet signing
in a later SSH session still lacks access. Never pass the keychain password in
arguments, environment or files, or change key ACL/partition policy as a shortcut.
After compilation has already passed, retry only codesign/verification in that
same unlocked session; no new dependency bootstrap or clean compilation is needed.

September 8 audio-tap probe: after the operator unlocked the keychain in the
desktop, SSH signing still failed, while the exact same codesign invocation in
a temporary `gui/<actual-UID>` Aqua launchd job passed. A valid certificate plus
`errSecInternalComponent`/`User interaction is not allowed` is not sufficient
evidence that the keychain itself is locked. For an already unlocked desktop,
signing in that authorized session is an alternative to another unlock prompt.
Use a uniquely named one-shot job, verify its exit code and the strict Apple
signature, and boot it out afterward. No key ACL/partition-policy changes or
credentials in its plist. This does not grant audio/screen-capture consent.

First run the synthetic endpoint (no capture even if TCC is granted):

```bash
python3 tests/auth/macos-https-auth.py \
  --server /absolute/preview-output/preview-synthetic \
  --config probes/macos/https-cert.cnf \
  --preview-receiver /absolute/preview-output/preview-receive
```

Then, from a TTY as the desktop user, run the signed app installed at its
consented location using `--aqua` and the same receiver/config. The runner asks
for the password without echo, boots a temporary Aqua job, approves its exact
TLS fixture and exchanges the transport secret only over TLS and receiver stdin.
TCP and UDP share the same ephemeral loopback port and leaf certificate. It
receives live HEVC in memory for three seconds, tests the existing bitrate
acknowledgement, and sends a native disconnect. No desktop image is written.
Finally it removes its exact Aqua job and temporary TLS material. Do not use
Screen Sharing to launch this test or modify login state.

The receiver now drains audio alongside video (bounded nonblocking batches),
checking 240-frame packet sizes, continuous millisecond PTS and a shared source
clock. `--preview-seconds 30` runs a bounded 30-second qualification; values
3–30 are accepted. This is not a Client playback or multi-hour sync soak.
Failure reporting copies only allowlisted stage/numeric capture diagnostics,
never the full Host stderr or credential-bearing requests. Do not compile while
collecting timing measurements. Keep unexplained stops in the qualification
record even if a later run passes.

A successful receiver checks framing, codec identifier, timestamps and clean
disconnect; it does **not** decode or present those live frames. The independent
synthetic bitstream tests remain the color/format evidence. Existing-Client
hardware decoding/presentation and longer live tests are still required.

## Native account-backend qualification

`scripts/test/build-macos-auth.sh SOURCE_ROOT EMPTY_OUTPUT_DIRECTORY` builds the
portable ownership test and a short-lived Open Directory verifier harness.
It also builds the private-channel and authentication-conversation tests.
It requires SDK/macOS 27 and sets a 27.0 deployment target. It does not install
anything, grant permissions, modify accounts or expose a network listener.
The harness and native backend compile with warnings as errors. Current
uncommitted files are qualification inputs only, not a release snapshot; record
their hashes when using the existing standalone-probe staging area on the Mac.

The build runs ownership, malformed-input/root-denial, private-channel and
conversation-state cases automatically. The latter two use synthetic verifier
implementations linked only into test executables; they never try bad passwords
against a real account. There are no product failure-injection switches. Tests
must retain their ad-hoc code signatures because the channel checks running
peer code identity. Do not disable code validation to run an unsigned test.
The separate `account-verification --verify-current-account` mode verifies only
the invoking non-root development account. Run over an actual terminal: it
uses `readpassphrase` with echo disabled and refuses a non-TTY credential source.
Never pass the password through arguments, environment, a file or a logged
command. The one-shot process disables core dumps and has a 20-second deadline.
It reports booleans, not the account identity or password. Success does not
grant desktop access. Do not automate wrong-password attempts against the
development account until its lockout policy is qualified.

Use `account-verification --verify-isolated-current-account` for the real
end-to-end private-channel test. It has the same TTY-only password input but
re-execs its verifier, sends credentials over the checked inherited socket,
requires a clean child exit and clears the parent's mutable secret. The worker
has a four-second deadline beneath the Client's five-second auth-request wait.
The outer interactive harness still allows 20 seconds for operator input.
The helper mode is internal; invoking it directly without its protected channel
must fail. Do not install a standalone public authentication socket.

The portable policy test is also registered in the root Linux qualification
CMake test suite. The macOS verifier itself is not a Linux package dependency.

## Native HTTPS/Aqua qualification

`scripts/test/build-macos-control.sh SOURCE_ROOT EMPTY_OUTPUT_DIRECTORY` first runs
the auth build/tests, then compiles the Network.framework adapter, HTTP parser,
live Aqua authority, a real qualification executable and a separate synthetic
test executable. All use SDK/minimum 27, warnings as errors and Apple frameworks.
The qualification flag is present only in `https-auth-synthetic`; it is not
linked into `https-auth` or a product binary. The normal executable dispatches
its private verifier argument before initializing any graphical/network code.

The runner also builds the native fixed-capture serializer/provider and verifies
`tests/protocol/fixed-capture-v13.json`. The encrypted synthetic and real Aqua
tests now exercise authorized topology, repeated geometry, and invalid/missing
Bearer rejection. The real query reads existing geometry only; it must never
start a stream, change a display or grant input as part of this control gate.
For Client validation on linux-client-builder, run the existing
`apps/client/tests/outputtopology/outputtopology.pro` suite with
`PLANK_REPO_ROOT` identifying both the Linux and fixed-capture JSON fixtures.
Keep `QT_QPA_PLATFORM=offscreen`. Unpublished standalone module/test inputs must
be SHA-256-verified separately; this is not a substitute for the required clean
worktree and full Client DEB/decoder gates before deploying a candidate.

The no-argument `https-auth` probe reports authority and immediately revokes it.
Over SSH it must print `active=0 revocation_pass=1`; use the existing temporary
graphical-probe runner in the user's `gui/UID` domain to verify `active=1` and
latched revocation. It does not request TCC, capture, input or display changes.

Run the synthetic encrypted exchange on the dedicated Mac:

```bash
python3 tests/auth/macos-https-auth.py \
  --server /absolute/control-output/https-auth-synthetic \
  --config probes/macos/https-cert.cnf
```

For real account verification in Aqua, run over an interactive SSH TTY as the
desktop user, never root:

```bash
python3 tests/auth/macos-https-auth.py --aqua \
  --server /absolute/control-output/https-auth \
  --config probes/macos/https-cert.cnf
```

The runner reads the password with terminal echo disabled, creates an ephemeral
loopback certificate/key in a mode-0700 directory, registers a unique one-shot
Aqua job, and submits the existing HTTPS start/respond exchange. It checks
live desktop ownership and replay denial. Finally it bootouts that exact job
and removes its own fixtures/output; no password/token enters files or arguments.
Do not rerun a failed real-password test blindly if failure could count against
the account's lockout policy. The listener is loopback-only, expires after 60
seconds, and does not expose any desktop/capture endpoint.

Known tool constraints, not product TLS failures:

- Xcode's bundled Python links LibreSSL 2.8.3 without TLS 1.3. Use the runner's
  OS `openssl s_client -tls1_3` path with certificate verification enabled;
  do not downgrade TLS or install an extra Python just to bypass that limitation.
- LibreSSL PKCS#12 fixtures failed Apple's importer (authentication/decode
  statuses). There is no importer workaround in the code: `SecCertificateCreateWithData`,
  `SecKeyCreateWithData` and `SecIdentityCreate` construct the identity directly
  in memory and verify that certificate/private key match. No keychain import.
- Use `https-cert.cnf`, which matches the product certificate's self-signed
  CA/key-signing attributes. Do not reuse the Rust transport's non-CA loopback
  fixture as an OpenSSL trust anchor; leave that separately qualified fixture
  unchanged. No trust-store change or insecure flag is needed.

The suite now also exercises public server discovery before and after
authentication. It is not Client UI approval, profile negotiation or video
playback. See `docs/architecture/macos-control-plane.md` for next integration steps.

## Existing Client discovery parser qualification

Run this only on linux-client-builder with Qt 6.10.2, not on the Mac or linux-host-builder. Reuse a
verified clean Client worktree at the root gitlink and its exact common-c
checkout. This is a small uninstalled parser harness, not a Client DEB build;
neither FFmpeg compilation nor a GUI/test session is required. The harness
compiles the real `NvHTTP`/`NvComputer` implementation and discards unrelated
unused operations at link time; it contains no replacement discovery parser.

```bash
source ~/.config/plank-builder/paths.env
# Set these to verified exact-commit worktrees, not inferred old candidates:
test -f "$PLANK_CLIENT_SOURCE/app/backend/nvhttp.cpp"
test -f "$PLANK_COMMON_SOURCE/src/Limelight.h"
discovery_build=$(mktemp -d "$PLANK_WORK_ROOT/macos-client-discovery.XXXXXX")
cd "$discovery_build"
qmake6 "$PLANK_SOURCE_ROOT/tests/protocol/macos-client-discovery.pro" \
  PLANK_CLIENT_SOURCE="$PLANK_CLIENT_SOURCE" \
  PLANK_COMMON_SOURCE="$PLANK_COMMON_SOURCE"
make -j4
QT_QPA_PLATFORM=offscreen ./macos-client-discovery \
  "$PLANK_SOURCE_ROOT/tests/protocol/macos-server-information.xml"
```

Record Client/common-c commits, harness/fixture hashes and output binary hash.
For unpublished qualification files, copy only the three test files into the
temporary test build directory and SHA-256-check them; use its `.pro` and XML
paths instead of pretending they belong to the clean source commit. The native
Mac metadata test consumes the same fixture. No builder package installation
or test-target deployment is part of this check. Remove the exact temporary
test build after its source checkpoint and qualification record are retained.

## Apple profile component qualification — linux-client-builder

Run the Client `tests/plankbitrate/plankbitrate.pro` and
`tests/applevideoprofile/applevideoprofile.pro` in separate shadow build
directories. The former uses Qt 6.10.2; the latter uses the retained private
FFmpeg. Set `PKG_CONFIG_PATH=$PLANK_CLIENT_FFMPEG_WORK/install/lib/pkgconfig`
before qmake, and `LD_LIBRARY_PATH=$PLANK_CLIENT_FFMPEG_WORK/install/lib` when
running the decoder test. Its `.pro` includes libswresample for private
libavcodec's transitive link requirement. Never link a distro FFmpeg instead.

The embedded fixtures are PLANK-owned VideoToolbox Main10 and RExt10 charts,
not user desktop content or generic HDR HEVC samples. The Client test README records provenance
and SHA-256. Passing proves software decode and strict format validation only;
hardware decode, renderer output and stream integration are separate gates.
Keep partial copied standalone qualification inputs explicitly identified;
full Client builds still require exact committed, clean worktrees and bundles.

The existing `macos-installed-client` integration harness takes explicit
`ADDRESS PORT USER WIDTHxHEIGHT ENCODING_MODE`, with the account password only
on stdin from a no-echo prompt. Both Apple modes use authenticated display
schema2. On GPU-less builders, append `--sample-keyframes` for format-only
qualification: receive/audio/control drain promptly; at most eight keyframes
and64MiB remain in memory and are decoded after disconnect. This is not a
real-time decoder, full reference-chain, or graphical presentation test.
The default synchronous full-frame software decode can fall behind a5K444
stream and overflow its receive queue; do not diagnose this test bottleneck as
an actual graphical Client transport regression. Static SCK content can
produce only one keyframe in15seconds; that validates format but not bitrate
response under motion. Keep failures and this limitation in the test record.

For `tests/outputtopology/outputtopology.pro`, set `PLANK_REPO_ROOT` to the exact
root source worktree when running its binary. Without that environment value,
the fixture-dependent tests fail to open JSON vectors; that is a runner error,
not a topology or compiler regression.

### Native optional services and typed preview launch

On linux-client-builder, import a verified unpublished **common-c bundle before Client,
then Client before root**, always using `--recurse-submodules=no`. Create clean
detached worktrees and run:

```bash
bash "$root_worktree/scripts/test/test-client-native-services.sh" \
  "$root_worktree" "$client_worktree" "$common_worktree" \
  "$PLANK_WORK_ROOT/native-services-candidate"
```

The output must not already exist. This compiles actual common-c Connection.c
with test-only device/network boundaries and the real Qt typed manifest parser.
It starts no service, media stream, input device or network listener. Current
expectation: 291 state-machine checks and 110 manifest checks. Full Client
link qualification remains separate; these are not hardware acceptance tests.
Do not run an old Client against a new common-c header/library: service flags
are an explicit internal struct contract, with no old-ABI inference.

For an uninstalled full-GUI startup diagnostic on linux-client-builder, keep isolated
XDG config/state/cache/runtime directories and use both
`QT_QPA_PLATFORM=offscreen` and `SDL_VIDEODRIVER=offscreen`. The SDL `dummy`
driver is not a substitute: both the unchanged 1.0.34 binary and the Mac-profile
build crash at `PlVkRenderer::initialize` when its Vulkan loader is unavailable.
The ordinary package `--version` check does not enter that renderer path.
Bound full-GUI probes with `timeout --kill-after=2s 8s` because the application's
SDL signal handler can consume SIGTERM without exiting its idle Qt main loop.
This diagnostic does not qualify compositor behavior, decoder hardware, visual
layout or session teardown; those need the actual hardware-test target.
