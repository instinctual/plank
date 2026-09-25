# PLANK handoff

## Current task

Branch `session-indicator` in `build/worktrees/session-indicator`, based on latest
main `5593932d5e8bc9fea2f52292fc0a5665b5c650a0` and Client
`b5c3a7a5ddd37e010155883054931be3010fc5a2`. Source version **1.1.015**;
candidate versions must include `-session-indicator`. Main and the unrelated
primary RK3576 worktree are untouched. No merge to main, deployment or Release.

Integrates root PR13 (5830df9), Client PR8 (2bd72178) and Linux Host PR10
(8f49a7c1), with the targeted repairs in
[the plan](docs/development/plans/session-indicator.plan).
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
- Client metadata is transient. Invalid names are rejected, names without
  occupied status are ignored, and long names cannot hide the status label.

## Validation and next action

Production Linux occupancy/private-record tests and existing session-policy
tests pass locally. SDK27 authentication/discovery and Ubuntu Qt parser tests
are being prepared; do not claim those or full package/hardware acceptance yet.
No live workstation or active session has been modified.

Next: complete focused component checks, inspect the complete diff against
current main, and record exact source commits/results. Then build candidates
when requested; installed local-to-remote access, login/logout, takeover,
offline clearing and long-name UI remain functional acceptance checks.

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
