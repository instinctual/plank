# PLANK handoff

## Current task

Issue19 follow-up: macOS Host now resolves the OS hostname at startup when
`[general] host_name` is omitted, matching Linux. The template uses a commented
override; invalid/unavailable OS names fall back to `PLANK`. No DNS lookup,
per-poll account work, Client runtime or protocol change. The installer retires
only its exact old generated INI name block and the old plist placeholder,
preserving custom/edited blocks, other settings, UUID and TLS material.
Source version is now **1.1.017**; no 1.1.017 package exists yet. Portable
settings5 and development-installer17 checks pass. Native parser, upgrade and
provisioning validation is in progress; do not claim installed acceptance.
The user requested implementation, not merging or deployment. The completed
1.1.016 package below does not contain this hostname correction.

Issue20 follow-up: macOS Host now accepts `[security] publish_session_user`
(default false) and `[network] ping_timeout` (default 10000 ms, range 200–120000).
Both keys have full reference comments, including pre-auth disclosure, accepted
values, keepalives, QUIC peer/recovery limits and the separate Client wait policy.
Username metadata reuses the desktop provisioning account lookup; the existing
Client parser handles it. LoginWindow stays nameless. Native QUIC uses the configured
idle limit; its initial handshake remains bounded separately. Linux runtime is
unchanged; its stale ping documentation is corrected. Implementation is committed
and pushed at root `3838956ba6785b65d079481a8273ef19728890c4`, Client changelog
`86d1b343` (no Client runtime change). Portable assembly4, startup-permission8,
all timeout/keepalive boundary checks and launcher guards pass. Native SDK27
parser and12 isolated configuration/upgrade tests pass, as do discovery XML,
authentication525, graphical lifecycle457, private desktop provisioning, all9
permission/metadata fixtures and loopback TLS/control regression tests. Host
entry/runtime/provisioning and preview probe compile with warnings as errors.
The actual Ubuntu Qt6.10.2 Client parser/persistence tests pass; tested sources
and metadata vectors are blob-identical to this branch. An initial ad hoc Client
test lacked its common-C include input; rerunning with the verified pinned source
passed, without a dependency download or product change. These tests use synthetic
accounts/OS events and temporary files; installed graphical login/logout and
network-outage acceptance remain pending. The signed macOS Host candidate below
includes this follow-up. No installation, merge, release or issue closure was
performed. The user explicitly requested that this branch not be merged.

Branch `session-indicator` in `build/worktrees/session-indicator`, based on latest
main `5593932d5e8bc9fea2f52292fc0a5665b5c650a0` and Client
`b5c3a7a5ddd37e010155883054931be3010fc5a2`. Latest built version **1.1.016**;
candidate versions must include `-session-indicator`. Main and the unrelated
primary RK3576 worktree are untouched. No merge to main, deployment or Release.
Candidate packaging for all four products is now authorized. Use hosted builders
and protected macOS signing; publish only the feature branches needed by CI.
No deployment, main merge, GitHub Release or hardware acceptance is authorized
by this build request.

Current follow-up: permission timing audit. Client microphone and attached USB
Wacom permission requests move to the ordinary launcher; streaming only checks
grants. Microphone consent completes before bookmark UI construction, without
blocking the main loop or opening a recording device. CLI autoconnect is
non-prompting. Host interactive setup exercises system-audio consent with a
private empty process tap; it never changes output routing or captures app audio.
Existing screen/input and camera-extension requests stay in Host setup.
See [the audit and OS-controlled exceptions](docs/user/permissions.md). A new
Host account that has not run setup may still encounter Apple's first-use audio
consent during a session; no synthetic approval or TCC bypass is introduced.
Implementation is committed and pushed at root `8f8f9009`/`a141c2d1`, Client
`9568b28a92c8b5b3f4dbce1c62c5fc49a407d718`. SDK27 validation
on a clean verified-bundle worktree passes: actual Client main/raw-Wacom/mic
objects; Host entry/setup syntax with warnings as errors; fake Core Audio
partial-failure/reverse-cleanup lifecycle; fake AVFoundation grant/deny/existing
decision callbacks; real microphone worker with SDL dummy capture and denied/
undetermined consent. Existing keyboard capture27 and raw-Wacom11 Qt cases pass.
Eight timing guards, five keyboard wiring checks and all nine native Host
permission/package-metadata tests pass. The native tests never request actual
TCC consent, record audio, open a tablet or install a product. Component tests
ran on macOS27 using retained development libraries, not qualified distributable
macOS15 dependencies. Hosted Host linking and signed packaging now pass; live
consent UI remains untested. The signed 1.1.016 Host package includes this work;
the earlier 1.1.015 packages do not. No signed 1.1.016 Client installer was
requested or produced in this packaging follow-up. No live permission reset or
installed app change was performed. Next: verify Host empty-tap consent with an
operator present. For Client startup acceptance, first build a signed 1.1.016
Client candidate, then verify fresh allow/deny startup, reconnect without prompts
and tablet attached before launch. Do not reset existing TCC grants merely to
manufacture a fresh test without approval.

## Candidate builds

### Current macOS Host candidate: 1.1.016-session-indicator

Exact package source: root `34b19f38f9ecb2443d9e7b5c1267201975c20462`, Client
`86d1b3433f3e80ae3de874ef80cd066410dd4f28`, Linux Host
`aabaf34c171a7620b7467883e6f4948a3f2659b0`, Kymux
`3f7a9d8618978287186e5d6ce0eaa067743cb06c`. All feature commits are pushed;
main remains `5593932d5e8bc9fea2f52292fc0a5665b5c650a0`.

Protected hosted run `36111685826` passed native tests, signing, notarization,
stapling and Gatekeeper assessment. The 71-check package filesystem fixture
passed without installing PLANK or starting its services. Dependencies used
the qualified cache; this was not a clean dependency-bootstrap qualification.

Package: `artifacts/packages/candidates/1.1.016-session-indicator/macos/plank-host_1.1.016-session-indicator_arm64.pkg`

- Size: 6,858,860 bytes.
- SHA-256: `0ede82a1387796d6f991c05d59da0c35f7c73bd9315366a8050850fb26d338a1`.
- Download verified against the runner manifest and collected with exact source
  provenance, `manifest.json`, `SHA256SUMS` and a checksum sidecar.
- Not installed or published as a GitHub Release; hardware acceptance is pending.

Automatic push run `36111686759` also passed Linux Client and both unsigned
macOS product builds; its Linux Host job was still running at this checkpoint.
Privacy run `36111686784` and clipboard regression run `36111686774` passed.
Unsigned macOS build success is not a signed Client installation artifact.

### Prior four-product candidates: 1.1.015-session-indicator

Exact package source: root `812770480deca1b896f6f3b7e59df8129677a46e`, Client
`4038bddc5c970a25a74371c0134c96f895fcbedc`, Linux Host
`aabaf34c171a7620b7467883e6f4948a3f2659b0`, Kymux
`3f7a9d8618978287186e5d6ce0eaa067743cb06c`. Feature branches are pushed;
main remains `5593932d5e8bc9fea2f52292fc0a5665b5c650a0`.

Hosted run `36104720921` passed both Linux packages and both macOS product builds.
Signed Host run `36104720562` and signed Client run `36104723022` passed,
including notarization/stapling and Gatekeeper assessment. The Linux Host input
lifecycle gate also passed. The macOS root filesystem fixture passes
all71 checks; it neither installs PLANK nor starts product services.

Collected candidates belong under
`artifacts/packages/candidates/1.1.015-session-indicator/{linux,macos}/` with
`manifest.json`, `SHA256SUMS` and per-file checksum sidecars. Transfer checksums
and exact source provenance are verified independently for all four packages.
The finished RPM owns `/var/log/plank` as root:root0700; the DEB includes the
administrator policy and no Client service/autostart. macOS Client is now a
PKG installer: distribute that PKG directly. This build also generated a
redundant DMG containing the identical PKG; it is not in the handoff catalog.
The build script still produces that wrapper; remove it in the next packaging
cleanup rather than claim it has already been removed. Nothing is installed,
merged, tagged or published as a GitHub Release. Package gates are not hardware
or fresh/upgrade installation acceptance.

The first candidate pass exposed a stale Match Host text guard and shell error
propagation around the macOS native configuration helper. Both are fixed in
`8127704`, with a portable fail-closed regression and the passing native root
fixture. Earlier runs `36104286424`, `36104286273`, `36104288898` are superseded
and must not be used for installation.

## Implemented changes

Issue12 implementation checkpoints: root `00682c9b` and `6893445f`. macOS Host
now reads only `/etc/plank/host.conf`; workstation UUID is identity-only state in
Application Support, separate from TLS keys. The installer converts the prior
public plist once, preserves settings/UUID/keys, and retires the old file only
after the replacement app is installed. Runtime has no plist fallback.
The macOS Client now packages a signed PKG, installing the
app and default `/etc/plank/client.conf` without overwriting existing policy.
No Client service/autostart/helper is installed. Shared Client reference template
moved to `packaging/client/config/plank-client.conf`; Linux DEB paths/runtime are
unchanged. Both apps carry current reference templates in Resources.
See [macOS configuration](docs/user/macos-configuration.md).

Username implementation checkpoint: root `67f2837b0a3e53223276f3b3f25f24c9c9bfe1ba`,
Client `417ac6bcf9427d8364a4c0613159ee32cae2b1c9`, Linux Host
`aabaf34c171a7620b7467883e6f4948a3f2659b0`. Issue16's Match Host label checkpoint
is Client `b3b6bcada422728cb09e2a0ce583919ce2788ee7`. The 1.1.015 Client was
`4038bddc` (changelog update after `b97b4ed1623e700e23983720051def93635a817f`),
including issue15's toolbar notch offset removal. Dependency commits must be
pushed before root.

Integrates root PR13 (5830df9), Client PR8 (2bd72178) and Linux Host PR10
(8f49a7c1), with the targeted repairs in
[the plan](docs/development/plans/session-indicator.plan).
Also implements issue17's administrator-opt-in remembered sign-in username.
Issue16 renames Physical displays to Match Host in bookmark creation and editing;
the headless-host hint uses the same name. Saved layout values, option indices,
protocol and display behavior are unchanged. macOS layout choices are unchanged.
Issue15 removes the obsolete horizontal toolbar notch avoidance and its unused
helpers. Native fullscreen already excludes the camera area. Centered initial
placement and normal dragged-position preservation remain; fullscreen geometry,
reveal timing, pinning, input routing and Linux behavior are unchanged.
The newer native camera, stereo microphone, feature negotiation and Mac virtual
audio clock work remains in the ancestry, not replaced by the older PR pins.

## Behavior

- In Session means a local user desktop or a reserved/live remote stream,
  including a Mac login-screen stream. It is advisory, not an access gate.
- The same locally logged-in user can connect from home. Existing explicit
  remote takeover and different-user ownership protections are unchanged.
- Linux/macOS `security.publish_session_user` defaults false. Opting in publishes
  the sanitized desktop name before authentication; LoginWindow stays nameless.
- Linux reuses the already-resolved supervisor account, bound to the private
  `SC-SESSION-3` attachment record. Discovery reads local logind state and an
  atomic stream bit, never NSS or session cleanup. Both private-channel ends
  are installed by the same Host package.
- Mac discovery selects cached XML using an atomic stream-lease bit; no account,
  display, media or authentication lock is acquired by public status polling.
- Host-discovered Client metadata is transient. Invalid names are rejected, names without
  occupied status are ignored, and long names cannot hide the status label.
- Client `authentication.remember_username` defaults false in
  `/etc/plank/client.conf` on both platforms. When enabled, it remembers the
  last successfully authenticated username per bookmark, prefills the editable
  field and focuses the empty password field. It never submits automatically or
  persists passwords/tokens. Public session names are not login suggestions.
- Disabling the policy purges saved usernames from both primary and backup
  bookmark arrays at startup. Destination changes clear the name; nickname
  changes do not. See [the user guide](docs/user/remembered-usernames.md).

## Validation and next action

Passed:

- Linux production occupancy/private-record and existing session-policy tests;
  complete supervisor compilation with GCC 14/C++23 and warnings as errors.
- Production stream-owner test with stub media workers: pending launch,
  cancellation, successful/failed setup, slot removal, and nonblocking public
  occupancy while a media join holds the session lock.
- Ubuntu Qt 6.10.2 actual Client parser/bookmark tests, offscreen; QML syntax
  check of the changed bookmark page. This is not a visual UI acceptance test.
- SDK27 control/authentication component suite, including 525 authentication
  assertions, dynamic occupancy XML, lease revocation and expiry. Real loopback
  TLS synthetic-account suite and machine-authority certificate-chain test pass.
- Host-version discovery, diff whitespace and commit privacy checks.
- Username follow-up at root `67f2837`, Client `417ac6bc`: Ubuntu Qt6.10.2
  policy suite25 cases and authentication/dialog suite12 cases pass. Tests run
  the actual inline login QML with a stub model, checking focus, editing,
  Cancel, no automatic login and cleared fields. Production parser/persistence
  tests pass for opt-in/default-off, per-bookmark isolation, exact realm/Unicode
  names, no tokens, address edits, stale authentication destinations and cleanup
  of primary/orphaned backup entries. These tests are included in the existing
  Linux Client build gates. No end-to-end Host login was performed for this option.
- Issue16 at Client `b3b6bcad`: Ubuntu Qt6.10.2 hostchoices suite passes all five
  cases, including the actual create/edit layout dropdowns for both Linux
  capture sources and macOS. Both full QML files pass qmlformat syntax checks.
  No package build or installed visual acceptance was performed for this rename.
- Issue15 at Client `b97b4ed1`: Ubuntu Qt6.10.2 toolbar suite23 cases pass,
  including centered/dragged positions, narrow windows, scale changes and button
  ownership. Eight fullscreen checks pass, including compiled safe-area geometry
  and a guard against reintroducing the notch offset. Native macOS compilation
  and notched-laptop visual acceptance remain pending; no package was built.
- Issue12 at root `6893445f`: native SDK27 INI parser and12 filesystem/installer
  tests pass on a clean verified-bundle worktree. Covers defaults, invalid input,
  preserved custom policy, UUID/TLS retention, interrupted conversion, conflicts,
  symlink/hardlink/permission rejection and Host/Client coexistence. The real
  `pkgbuild`/`productbuild`/`pkgutil` synthetic Client payload roundtrip passes;
  it does not install an app or policy. Existing desktop provisioning test passes
  with the new reader; Host entry point compiles with warnings as errors.
  All9 Host permission tests pass on macOS, including synthetic PKG roundtrips.
  Portable development-installer17, build-path9, package-collection7 and target
  checks pass; launcher/shell/diff/privacy checks pass. Root-only installed-state
  fixture was not run: development Mac requires interactive sudo. No permissions,
  launchd jobs, active sessions, TCC settings or installed products were changed.

The earlier occupancy Mac and Ubuntu component tests used clean worktrees at
root `b0ec487` and Client `d990292e`. Subsequent Linux pending occupancy has its
own passing production-owner test at `b2e809b`. Username tests use the newer
root/Client checkpoint above; macOS-specific username UI acceptance is pending.
No live workstation, installed package or active session has been modified.

The stale `test-host-supervisor-package.sh` source guards are now reconciled:
the layout lambda captures validated request modes, and reconnect consults its
bounded policy gate before requests. The complete shell gate passes, with its
other assertions retained; no product display or reconnect code changed.

Next: manually test these candidates, including fresh/upgrade installation gates
on an authorized test Mac. Verify existing UUID, TLS keys,
custom ports/names and Client policy survive, including an interrupted upgrade.
Then verify installed local-to-remote access, login/logout, takeover, offline
clearing and long-name UI. Check centered toolbar reveal/drag and fullscreen/
windowed transitions on a notched Mac. Hardware/installed acceptance is pending.

## Preserved baseline

Main1.1.014 retains Linux Host5829bf7c, Clientb5c3a7a5 and
Kymux3f7a9d8618978287186e5d6ce0eaa067743cb06c. Client common-c remains
060f6179f88343327b44d915007f1fb4cede71f1; qmdnsengine remains
920c097ffa742e2968290f15d4dde6693aec02e5. No transport, decoder, capture,
encoding or input feature change is part of this task.

The operator accepted initial Mac audio-clock correction and confirmed distinct
physical stereo microphone channels. Long-duration duplex/camera lip sync,
concurrent camera readers and output restoration coverage remain as recorded in
[the native-media plan](docs/development/plans/native-media-forwarding.plan).
Earlier exact package provenance and reports remain in the immutable artifact
catalog and main5593932 HANDOFF history; do not relabel feature packages.
Private machine notes stay outside Git; read their local README before access.
