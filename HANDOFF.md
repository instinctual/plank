# PLANK handoff

## Current state

The operator authorized commit, push and merge of the complete
`session-indicator` work. Integration is a conflict-free fast-forward of
root `3b200b5d44f276ec4c5e4f72966c5aa2ac0e0fe2` onto
main, following the companion repositories in dependency order:

- Client main: `9cb38c3a32f26279af50d1a3d2e6c76f3e5838fb`.
- Linux Host main: `aabaf34c171a7620b7467883e6f4948a3f2659b0`.
- Kymux unchanged: `3f7a9d8618978287186e5d6ce0eaa067743cb06c`.
- Client common-C unchanged: `060f6179f88343327b44d915007f1fb4cede71f1`.
- qmdnsengine unchanged: `920c097ffa742e2968290f15d4dde6693aec02e5`.

Continue in the main worktree `build/worktrees/macos-session-takeover`.
The primary worktree contains unrelated RK3576 work; leave it untouched.
Feature branches are retained; branch deletion was not requested.
Version is **1.1.017**. No signed 1.1.017 installer has been produced, deployed,
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

1. Build fresh mainline 1.1.017 packages when requested, using the release runbook
   and protected hosted signing. Keep the current template and all submodule pins.
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
