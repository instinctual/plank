# PLANK handoff

## Current task

Branch `session-indicator` in `build/worktrees/session-indicator`, based on latest
main `5593932d5e8bc9fea2f52292fc0a5665b5c650a0` and Client
`b5c3a7a5ddd37e010155883054931be3010fc5a2`. Source version **1.1.015**;
candidate versions must include `-session-indicator`. Main and the unrelated
primary RK3576 worktree are untouched. No merge to main, deployment or Release.
Changes are committed locally, not pushed.

Username implementation checkpoint: root `67f2837b0a3e53223276f3b3f25f24c9c9bfe1ba`,
Client `417ac6bcf9427d8364a4c0613159ee32cae2b1c9`, Linux Host
`aabaf34c171a7620b7467883e6f4948a3f2659b0`. Issue16's Match Host label checkpoint
is Client `b3b6bcada422728cb09e2a0ce583919ce2788ee7`. Current Client is
`b97b4ed1623e700e23983720051def93635a817f`, including issue15's toolbar notch
offset removal. Dependency commits must be pushed before root.

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
- Linux `security.publish_session_user` defaults false. Opting in publishes the
  sanitized desktop name before authentication; macOS remains nameless.
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

The earlier occupancy Mac and Ubuntu component tests used clean worktrees at
root `b0ec487` and Client `d990292e`. Subsequent Linux pending occupancy has its
own passing production-owner test at `b2e809b`. Username tests use the newer
root/Client checkpoint above; macOS-specific username UI acceptance is pending.
No live workstation, installed package or active session has been modified.

Known unrelated baseline gate: `tests/packaging/test-host-supervisor-package.sh`
still expects an obsolete `layout_arguments(request.mode_1, request.mode_2)`
call and old reconnect-loop spelling. Both differ already on the main commits
above. The gate was left unchanged, not bypassed; full packaging is not claimed.

Next: build candidates when requested, reconcile that stale source-pattern gate,
then verify installed local-to-remote access, login/logout, takeover, offline
clearing and long-name UI. Check centered toolbar reveal/drag and fullscreen/
windowed transitions on a notched Mac. No full package or hardware acceptance yet.

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
