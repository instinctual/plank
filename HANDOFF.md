# PLANK handoff

## Current state

Current candidate work is `macos-app-icons`, based on main
`9d2875297c96f54803723b4f69076e1c0d9f0232`, in the retained
`build/worktrees/macos-session-takeover` worktree. The operator authorized commit,
push and signed hosted macOS Host/Client candidates for the permission panels
and uninstall follow-ups below. Source version is **1.1.019**; the visible and
package version is **1.1.019-macos-app-icons**. No merge, Release or installation
is authorized by this candidate step.
Signed Host source is `e0d11026f23a2dbb243eafd6f48943edad9eddc0`;
run `36177470498` passed all package/signing/notarization/stapling/Gatekeeper
and cleanup gates. Its checksum-verified PKG is collected below.
Client run `36177473821` compiled and passed tests but failed the payload-path
gate before notarization: the uninstaller's inline Directory Services account
lookup resembled a home-directory path. This was a script-literal false positive,
not a private build path. Separating the account lookup resolves it without
weakening the scanner. The early uninstall fixture and build-path suite now
exercise that shipped script. Signed Client retry `36178693716` uses root
`0a7e10397fc5e5c89aa4ce2a8a63814862e26f06`; Host code and all dependency pins
are unchanged by that Client-only packaging correction. The retry passed full
build/tests, payload path/target checks, offscreen launch/version, signing,
notarization/stapling, Gatekeeper and signing cleanup. Its PKG is collected;
the redundant generated DMG wrapper was not copied into the canonical catalog.
Both signed jobs restored and verified exact dependency caches.
Automatic four-product run `36177430110` passed Ubuntu and both unsigned Macs;
its remaining Linux Host job was superseded/cancelled by the correction push.
Replacement automatic run `36178693950` passed Ubuntu and both unsigned Mac
jobs; Linux Host is still in progress. Do not claim all-platform completion.
Privacy `36177429921` and clipboard `36177430038` passed.
Local CI policy/cache/signing fixtures62,
permission timing9, keyboard guards5, build-path10, portable Host uninstall24,
Client uninstall2 groups, version and whitespace gates pass. Native-only
configuration tests correctly skip on the Linux orchestration machine; their
dedicated-Mac results below and hosted reruns are separate.
Client implementation is committed and pushed at
`c684014752b511de489d6406e8bafb005bef5123`; other dependency pins are unchanged.
The primary worktree's unrelated RK3576 changes must remain untouched.

The operator likes the installed 1.1.019 Host setup window. Their screenshot
confirms the aligned layout and green verified permission/device rows, but they
questioned System Audio's **Check in Settings** despite its OS switch being on.
That row deliberately does not infer audio consent from an empty tap starting.
It is an unverified status, not denial. No follow-up UI change has been made;
discuss a reliable audio-only permission query or clearer **Not verified** text
before displaying an unsupported green Allowed status. Installed Client visual
acceptance and actual uninstall/purge tests remain outstanding.

## Previous icon checkpoint

The operator approved the
second generated Host/Client icon pair. Both approved PNGs are retained
unchanged in `branding/assets/plank-{host,client}-macos.png`: open landscape
for Host, monitor-framed landscape for Client. The original artwork/PXD and
Linux icons are unchanged. No media, authentication, input or protocol changes.

Implementation checkpoint: root `d8f9372fe88464e4efb322b967c8a2dd44a87622`,
Client `944cf2b0ff32a7ca5c318d38eaaa3ecc0317f2a0` (changelog only).
Linux Host, common-C, qmdnsengine and Kymux pins remain as listed below.
Checkpoint version is **1.1.018**. The Client base build now generates its ICNS
before either development or distribution packaging; Host selects its own
artwork. The native converter adds no new padding or circular mask. See
`docs/user/branding.md` for sources and generation brief.

Native SDK27 validation passed from a clean verified-bundle worktree: all9 icon
tests (approved-source hashes, product selection, ten representations per icon,
ICNS compile/extract roundtrip and controlled conversion failures), all17
development-installer cases, all9 permission/package fixtures and all6
Client-target cases. These compile and check real icon assets and isolated
synthetic bundles, not the full applications. No GUI or installed app was
started, and no active session, permission or service was changed.
Portable build-path9, repository layout, release-version contract, shell syntax,
privacy hooks and whitespace checks also pass. The source PNG/PXD and Linux
runtime icon are unchanged. Client and root commits are now pushed on
`macos-app-icons`; build source is root
`399de64846319ef6f8104642f5c88a2e01861b66`. No merge, deployment or Release.
The primary worktree's unrelated RK3576 work remains untouched.

Signed hosted Host run `36116628031` passed, including notarization/stapling,
Gatekeeper, package and temporary-signing cleanup gates. Its 1.1.018 candidate
is collected and checksum-verified in the canonical package catalog. Client
signed run `36116628204` also passed its build/tests, dependency/target checks,
offscreen launch/version, signing, notarization/stapling, Gatekeeper and cleanup.
Its PKG is collected with verified source/SHA-256; the redundant DMG wrapper is
not copied into the local catalog. Both signed jobs restored exact dependency
caches. Automatic all-product run
`36116578450` passed all four products, including Linux Host. Privacy `36116578586`
and clipboard `36116578547` passed. These gates do not prove installed icon
acceptance.

At the operator's request, closed resolved root issues12,15,16,17,19,20 with
merged implementation/test references. Closed Client PR8 as already integrated:
both original commits' stable patch IDs match the retained Client cherry-picks
`fddac42b` and `b6bbcee4`, followed by `d990292e`. Root PR13 and Linux Host PR10
were already merged/closed. Root issues14 (cold-boot connection) and18 (audio
sync), Client PR7, Linux Host PR6, Kymux PR2 and build-deps PR3/4/5 remain open;
this bookkeeping does not qualify or merge those separate changes.

## 1.1.019: automatic camera uninstall

The operator requested automatic camera removal through the existing Host
uninstaller. Local changes on `macos-app-icons` invoke the signed installed Host
in the active console user's GUI domain to submit a SystemExtensions deactivation
request. The command reports completed/restart-required/failure exit statuses;
there is no PLANK modal alert blocking its two-minute timeout. The script verifies
that camera registration is gone before stopping services or removing drivers
and the app. Missing desktop, cancellation, timeout, inspection failure or
restart-required keeps the Host intact. A restart, when macOS requires one, is
manual, followed by the same uninstall command. No direct OS extension deletion,
SIP/TCC changes, reboot automation or new persistent helper.

Portable uninstall fixtures (24 checks), permission timing8, camera-profile1 and
package metadata checks pass. Dedicated SDK27/arm64 validation passed native
uninstall fixtures30, camera setup/removal callbacks with ASan/UBSan, shared-memory
and protocol tests, camera lifecycle, production camera/Host-main compilation
with warnings-as-errors, permission/package9 and Host timing4. These are isolated
fixtures, not a real uninstall: no installed app, service, extension, permission
or active session was changed. Live signed-app deactivation/approval remains an
installed test gate. The existing 1.1.018 packages do **not** contain this follow-up;
it is included in the signed 1.1.019 Host candidate, not merged.

## 1.1.019: Client uninstall

The operator approved a lightweight Client uninstaller and optional data cleanup.
The signed distribution Client will include `Contents/Resources/uninstall.sh`.
Normal uninstall verifies the Client signature, requires all Client instances to
be closed, and removes only the exact Client app and package receipt. `--purge`
requires typed confirmation and also removes `client.conf` plus the invoking
sudo user's preferences/bookmarks, Host trust store, caches, logs and saved
window state. User cleanup drops root privileges, validates exact paths and
rejects symlinks; no other home directories are enumerated. Host files, shared
directories and TCC grants are untouched. There is no service/helper or reboot.

Portable lifecycle guards pass. Native SDK27 tests passed isolated data removal,
idempotency, leaf/parent symlink rejection and Host/other-user preservation.
The actual Qt6.10.2 preferences/data/cache paths match the cleanup list; this
read-only path test is now a Client build gate. The new fixture uses the same
`arm_acle.h` include required by the other SDK27 Qt fixtures. All16 native
configuration/installer tests pass, including the PKG roundtrip which verifies
the embedded executable script. Signing occurs after embedding the script.
No installed Client, actual user data or privacy permissions were changed.
Both uninstall follow-ups are included in the signed1.1.019 candidates;
installed uninstall acceptance remains.

## 1.1.019: permission status UI

The operator approved replacing the paragraph-heavy Host alerts with a status
window and adding a smaller Client review panel. Local changes on the same branch
give Host setup aligned feature/status/action rows, separate desktop permissions
from optional devices, and put each guidance sentence on its own line. OS-verified
permissions get checkmarks; missing required access has an explicit warning.
Audio devices report loaded/not loaded; camera inspection distinguishes approval,
removal, enabled and unknown states. Successful empty audio-tap startup is never
presented as proven audio consent. Existing automatic camera-version reconciliation
is retained, but first activation remains explicit. Close is bounded even if HAL
is still waiting for consent; no background worker gains permission-request UI.

The macOS Client's Configuration/Input Settings opens a compact permission panel
for Accessibility, Microphone and supported USB Wacom Input Monitoring. Normal
startup consent timing is unchanged; there is no additional all-ready popup.
Settings return/manual Refresh updates the panel without continuous polling.
Actions reject active sessions. Status is read-only; no checkbox can claim to grant
OS permission. Linux UI/runtime and forwarding policies are unchanged.

Native SDK27 Host view/production compilation and ASan/UBSan camera-status,
activation/removal callbacks pass. Native Qt6.10.2 tests exercise the actual Client
model and QML panel with simulated permission boundaries, including denied/unknown/
granted states, missing tablets, active-stream rejection and destroyed-object
callbacks. Changed Client main, backend, moc, raw-Wacom and QML resources compile
through the real application qmake project. The Client panel was rendered offscreen;
Host view geometry was checked with synthetic data. Actual Apple permission dialogs
and installed visual acceptance remain untested. Existing uninstall/configuration
fixtures pass; no installed app, service, permission, capture or session changed.

All three follow-ups are included in the signed 1.1.019 candidates, not in1.1.018
installers. Next: finish installed acceptance and clarify the audio status above.
Do not relabel
existing packages or claim a full application/package build from component tests.

## Previous mainline integration

The operator authorized commit, push and merge of the complete
`session-indicator` work. Integration is a conflict-free fast-forward of
root `3b200b5d44f276ec4c5e4f72966c5aa2ac0e0fe2` onto
main, following the companion repositories in dependency order:

- Client main: `9cb38c3a32f26279af50d1a3d2e6c76f3e5838fb`.
- Linux Host main: `aabaf34c171a7620b7467883e6f4948a3f2659b0`.
- Kymux unchanged: `3f7a9d8618978287186e5d6ce0eaa067743cb06c`.
- Client common-C unchanged: `060f6179f88343327b44d915007f1fb4cede71f1`.
- qmdnsengine unchanged: `920c097ffa742e2968290f15d4dde6693aec02e5`.

The integration used `build/worktrees/macos-session-takeover` (now the icon branch).
The primary worktree contains unrelated RK3576 work; leave it untouched.
Feature branches are retained; branch deletion was not requested.
Main's version is **1.1.017**. No signed 1.1.017 installer has been produced, deployed,
tagged or published as a GitHub Release. Existing feature candidates retain
their original names and provenance; rebuild from main rather than relabel them.

## Integrated behavior

- Advisory In Session covers local desktops and pending/live remote streams.
  It does not prevent the same locally logged-in user connecting remotely.
  Explicit takeover and different-user ownership protections are unchanged.
- Linux and macOS `[security] publish_session_user` default false. Enabling it
  publishes a sanitized desktop short name before authentication; locked desktops
  retain it, while LoginWindow remains nameless. Discovery uses cached metadata/
  atomic occupancy, without new account lookups, auth locks or teardown work.
- Client `[authentication] remember_username` defaults false. It saves only
  the last successful username per bookmark, never passwords/tokens; no automatic
  submission or use of discovery names as login suggestions. Disabling policy
  purges primary and backup settings; destination edits clear saved names.
- Bookmark Physical displays is now Match Host. Saved values, layout behavior
  and protocol are unchanged. Obsolete Mac toolbar notch-offset logic is removed;
  centered placement, manual positioning, input and fullscreen behavior remain.
- macOS Host reads `/etc/plank/host.conf`. UUID is identity-only
  `/Library/Application Support/PLANK/identity.plist`; TLS material stays separate.
  The installer converts the prior plist once, preserving custom policy and
  identity, and retires it only after installing the replacement app. Runtime
  has no plist fallback.
- macOS Client uses a PKG installer and root-owned `/etc/plank/client.conf`.
  It remains interactive, without service, helper or autostart. Linux paths
  remain unchanged; the shared Client reference template is in
  `packaging/client/config/plank-client.conf`.
- macOS `[network] ping_timeout` defaults 10000 ms, accepts 200–120000, and
  rejects invalid values. It sets QUIC inactivity tolerance, not input idle or
  buffering. Keepalives, peer/recovery limits and the separate initial handshake
  and Client Wait/Disconnect policy are documented. Linux runtime is unchanged;
  only its stale timeout comments were corrected.
- Issue19: omitted macOS `[general] host_name` now uses local OS
  `gethostname()` at startup, matching Linux, with `PLANK` as the unusable-name
  fallback. The installer retires only its exact old generated INI name block
  and old plist placeholder. Edited/custom blocks, other settings, UUID and TLS
  are preserved. There is no DNS lookup, watcher or per-poll hostname query.

Permission timing: ordinary Mac Client GUI startup requests microphone and
attached qualified USB Wacom consent before constructing the bookmark UI.
Session entry checks grants only; CLI autoconnect does not prompt. Host
interactive setup exercises system-audio consent using a private empty tap,
without recording application audio or changing output routing. Screen/input
and camera-extension requests stay in setup. New Host users who have not run
setup can still encounter OS first-use audio consent during a session; OS
revocation/local-network prompts remain OS-controlled. Do not reset TCC grants
without approval or claim automatic system-wide consent.

See [configuration](docs/user/macos-configuration.md),
[permissions](docs/user/permissions.md),
[remembered usernames](docs/user/remembered-usernames.md), and
[the integration plan](docs/development/plans/session-indicator.plan).

## Validation

Latest implementation checkpoint:
root `4642fe4716f15a54f96994e501b603cfc390850b`, Client `9cb38c3a`.
Subsequent commits record validation/integration, without runtime changes.

Passed on clean verified-source worktrees:

- Native SDK27 hostname parser, including ASan/UBSan, changed OS names,
  lookup failure, malformed/unterminated results, length bounds and custom names.
- All16 native configuration/upgrade fixtures: generated-block retirement,
  custom/edited name retention, exact preservation of other settings,
  interrupted/retried installation, invalid identity and unsafe-file rejection.
- Actual local OS hostname and desktop identity provisioning; no OS rename.
- Mac authentication525, account-policy27, account-channel19, HTTP215, cached
  discovery XML/control tests, graphical lifecycle457 and synthetic TLS chain/
  authentication checks across the relevant implementation checkpoints.
- Permission/package-metadata9 fixtures, including real synthetic PKG roundtrips.
  Hosted 1.1.016 packaging also passed its root-only71 filesystem checks.
- Portable Host-settings5, development-installer17 and CI62 tests.
- Earlier Ubuntu Qt6.10.2 actual parser/persistence, username-policy25,
  authentication-dialog12, hostchoices5 and toolbar23 checks; eight fullscreen
  source/geometry guards. SDK27 Client startup/main/raw-Wacom/microphone objects,
  synthetic consent lifecycle/denial, keyboard27 and Wacom11 cases.
- Linux advisory occupancy/private-record, production stream owner with stub
  workers, session policy, supervisor compilation and reconciled package guards.
- Diff whitespace and commit privacy gates.

The hostname follow-up changes no Client runtime or Linux code. Native tests
never alter installed apps, permissions, real OS hostnames, accounts or active
sessions. Synthetic tests are not installed or hardware acceptance.
No remote test process remains running. Exact earlier validation checkpoints
are preserved in this file's Git history.

## Available candidates (not mainline rebuilds)

Catalog: `artifacts/packages/candidates/`. Checksums and exact root/gitlink
provenance live in each version's `manifest.json`, `SHA256SUMS` and sidecars.

### 1.1.019-macos-app-icons

Signed/notarized Host from root `e0d11026f23a2dbb243eafd6f48943edad9eddc0`,
Client pin `c684014752b511de489d6406e8bafb005bef5123`, other pins unchanged.
Package: `1.1.019-macos-app-icons/macos/plank-host_1.1.019-macos-app-icons_arm64.pkg`.
SHA-256: `366eb7cdd59e36dbb362c8753456a046cc9c93a850be335b6145fd8b60ddabc9`
(6,990,659 bytes). SDK27, macOS27 minimum. No installation performed.
Client from root `0a7e10397fc5e5c89aa4ce2a8a63814862e26f06`, with the same
dependency pins and a Client-uninstaller-only packaging correction:
`1.1.019-macos-app-icons/macos/plank-client_1.1.019-macos-app-icons_arm64.pkg`.
SHA-256: `900cde876ee9e820451cf53bdb53dd4b081c99313996693db65e8489a0fa4c64`
(72,861,320 bytes). SDK27, macOS15 minimum. Both collected checksums verify.
No automatic installation or Release. The failed first Client attempt is not
an available installer; the catalog contains only the successful retry.

### 1.1.018-macos-app-icons

Source root `399de64846319ef6f8104642f5c88a2e01861b66`, Client
`944cf2b0ff32a7ca5c318d38eaaa3ecc0317f2a0`; other pins as above.
Signed/notarized macOS Host and Client collected. Host:
`1.1.018-macos-app-icons/macos/plank-host_1.1.018-macos-app-icons_arm64.pkg`.
SHA-256: `a3a2d1ac902b5d695bc2b98ed1b7dfb8e28bb6fcb01c877bc63fad37a8c52770`
(6,980,744 bytes).
Client: `1.1.018-macos-app-icons/macos/plank-client_1.1.018-macos-app-icons_arm64.pkg`.
SHA-256: `da3f4bba4da68bd9b414badc2f497787c4064c5c9eb0c3bd08548b55b526d7c0`
(72,858,129 bytes). Host minimum27; Client minimum15, both built with SDK27.
No installation or icon-cache reset. These are candidates, not a Release.

### 1.1.016-session-indicator

Signed/notarized **macOS Host only**, built from root
`34b19f38f9ecb2443d9e7b5c1267201975c20462`, Client
`86d1b3433f3e80ae3de874ef80cd066410dd4f28`, Linux Host/Kymux as above.

Package:
`1.1.016-session-indicator/macos/plank-host_1.1.016-session-indicator_arm64.pkg`

SHA-256: `0ede82a1387796d6f991c05d59da0c35f7c73bd9315366a8050850fb26d338a1`
(size 6,858,860 bytes). Signed hosted run `36111685826` passed native tests,
notarization/stapling and Gatekeeper. Automatic run `36111686759` passed both
Linux packages and both unsigned Mac builds; privacy `36111686784` and
clipboard `36111686774` passed. Dependencies used qualified caches.
This Host includes issue20/settings and permission setup, **not issue19's
hostname correction**. No signed 1.1.016 Client installer was built.

### 1.1.015-session-indicator

All four collected products under `1.1.015-session-indicator/{linux,macos}/`.
Root `812770480deca1b896f6f3b7e59df8129677a46e`, Client
`4038bddc5c970a25a74371c0134c96f895fcbedc`, Linux Host/Kymux as above.
All-product run `36104720921`, signed Host `36104720562` and signed Client
`36104723022` passed. Exact hashes remain in the catalog.
Client handoff is PKG-only: a redundant generated DMG wrapper was not collected.
The build script still generates that wrapper; its removal remains a separate
packaging cleanup. Failed earlier runs `36104286424`, `36104286273` and
`36104288898` are superseded and must not be used.

Neither candidate set was installed during this work. Do not infer fresh/upgrade
or streaming acceptance from package/signature gates.

## Next gates

1. Check the remaining automatic Linux Host job in run36178693950. Complete
   installed Client permission/status UI acceptance and clarify Host System Audio
   status as above. Camera deactivation and Client uninstall/purge
   require separate operator-supervised tests; component fixtures did not remove
   installed apps or user data. No cache resets or app modifications are automatic.
2. Test fresh/upgrade configuration on an authorized Mac: generated-name
   retirement, custom policy retention, interrupted retry, UUID/TLS preservation.
3. Verify installed local-to-remote access, login/logout, takeover, offline status,
   optional username display and wait/timeout behavior.
4. With an operator present, verify launch-time allow/deny consent, reconnection
   without new prompts, attached-tablet startup and Host empty-tap audio consent.
   Do not reset existing grants merely to manufacture a fresh test.
5. Verify toolbar placement/drag and fullscreen transitions on a notched Mac.
   Qualify the same Mac Client package on supported macOS15 and macOS27.
6. Retain the earlier native-media gates: long-duration duplex/camera lip sync,
   concurrent camera readers, output restoration and controlled stereo-channel
   measurements. User-confirmed distinct physical microphone channels are
   recorded in the [native-media plan](docs/development/plans/native-media-forwarding.plan).

Private machine addresses, deployment notes and operational evidence remain
outside Git; read the private notes' README before machine-specific work.
