# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Machine-specific access,
credentials, captures and operational evidence belong in the external private
notes, never in Git.

## Current baseline — consolidated main

The operator authorized merging the pending fixes and parent PR #24 to establish
a clean baseline. Parent, Client and Linux Host are consolidated on `main`, with
common-C on its product branch `plank/client`. All are pushed in dependency order.
The parent product integration is the commit below; the following handoff update
changes documentation only. No merge remains pending for these fixes.

| Component | Mainline source |
| --- | --- |
| Parent integration, before final handoff | `e7a8ff4fda6e6115a6bcd638f80a5b9629862968` |
| Client | `942f911fc4221d1306aca0f81c45c71190dbdd41` |
| Linux Host | `73ad3ecb548b2f4d2e93fe4ed0860d27b300c734` |
| Client common-C (`plank/client`) | `036df96f2d1577af7a1b08c05d87a5218fff7c9b` |
| Kymux, unchanged | `3f7a9d8618978287186e5d6ce0eaa067743cb06c` |
| Host header-only common-C, unchanged | `3a97a58f215323753cfd1180af760ec7e3253538` |
| qmdnsengine, unchanged | `920c097ffa742e2968290f15d4dde6693aec02e5` |

Other recursive pins remain in those exact component trees, including Host
libvirtualhid `a0d3aa0cc4d53daa18bfa2f2fbdf848957b6d294`, GoogleTest
`52eb8108c5bdec04579160ae17225d66034bd723` and build-deps
`c29c4822cb96f5bfeb8640e72601c5cf4e3c3137`.
Do not merge Client common-C runtime code into its separate header-only Host
branch, or confuse its historical default branch with the product branch.

The integration includes:

- **Wacom/input recovery:** bounded reliable-event backpressure instead of silent
  click/release loss; asynchronous bounded hidraw feature I/O; generation-safe
  completion and kernel-query cancellation; independent Wayland cursor commits.
  Healthy device identity, coordinates and Tablet Margins mapping are retained.
- **Scaling quality:** Mac initial stream sizing uses active backing pixels for
  all Host/layout combinations. Metal area filtering preserves small-window
  detail. Direct Linux NvFBC/NVENC reductions use GPU area integration before
  color conversion, with no CPU readback or additional frame queue.
- **README refresh:** parent, Client, Linux Host and native Mac Host introductions
  now describe current PLANK products, platforms, configuration, build entry
  points and limitations. Upstream attribution and license files remain intact.

The earlier `macos-scaling` shader changes are carried forward in Client
`9d0bbe8b`; comparison confirms the same production shader/renderer changes.
The `wacom-pressure` branch has no additional product changes beyond main,
only older candidate version/provenance notes. Do not merge old candidate
version numbers backwards merely to make these branch tips ancestors.

Package version remains **1.1.034**. This consolidation is not a new release or
new main-built package. Existing candidate filenames, checksums and manifests
remain unchanged; never relabel them as mainline builds. No machine was
installed, rebooted or interrupted during consolidation.

## Camera transport — parent PR #24

Reviewed head: `f6a815df11c53628404424d0ed9fe161f3cdccc6`.
[PR #24](https://github.com/instinctual/plank/pull/24) is approved and merged,
preserving the contributor's commits. Its Linux Host, Ubuntu Client, Mac Host,
Mac Client, privacy, clipboard and policy checks all passed at that exact head.
[Hosted build run](https://github.com/instinctual/plank/actions/runs/37714438288).
Protected signing was intentionally skipped for the fork PR, not a failed gate.

PCAM v2 adds explicitly selected Mac VideoToolbox H.264 camera records while
leaving existing PCAM v1 callers and transport ABI 13 intact. Queue limits,
generation isolation and camera-only failure handling remain. It is transport
preparation, not a finished Mac camera sender, Host adapter or native Apple
Client. Product authorization, consent, capture and hardware qualification
remain separate.

Independent validation at that head passed:

- Both C wire vectors; strict parsing, bounded queues and recovery tests.
- Encrypted direct/setup transport for v1/v2, with and without microphone
  traffic; short-buffer handling and isolated version mismatch.
- All 60 non-ignored transport unit tests; nine tests intentionally ignored.
- Privacy/new-content and whitespace checks.

The same transport unit and encrypted camera tests passed again on the combined
parent integration tree, alongside CI policy and repository/link checks.
The consolidated main push starts ordinary hosted CI; this is not a separately
requested signed build or release. Do not assume its result from the PR checks.

No physical camera or product session was used. The optional generated-Mac-camera
fixture was not run locally. Local evidence is under
`build/tests/pr24-camera-transport/`; the clean review worktree is
`build/reviews/pr24-camera-transport`.

## Native Apple Client coordination — kept separate

The published `apple-native-integration` branches remain isolated from main.
Root branch `f47fb1549439af58f5afe47812357269eae7dede` contains coordination
notes only; Client branch is based on `0af6d9fc15197c11257b10e4eed40b0eba783886`.
Their worktree is `build/worktrees/apple-native-integration`, with a linked
Client worktree at `apps/client`.

[Client issue #9](https://github.com/instinctual/plank-client/issues/9) asks the
contributor to confirm source checkpoints, layout and contribution order before
imports or moves. Proposed native Mac/Vision Pro applications are not part of
this mainline consolidation. No experimental native Client source was imported.

## Validation and retained candidate artifacts

Consolidation checks passed: 62 CI policy tests, 20 privacy-guard tests, ten
Mac geometry/fullscreen source gates, two Metal overlay gates, two Linux CUDA
scaling-wiring gates and repository/documentation-link checks. Eight shared
input/queue tests and the rebuilt Host input-recovery component suite passed.
These are component/source checks, not fresh package or hardware acceptance.

Original candidates remain in the version/platform catalog. Their manifests
contain exact checksums, sizes and full package/source provenance:

| Candidate | Exact root source | Product artifacts |
| --- | --- | --- |
| `1.1.033-wacom-recovery` | `353eb071f0f8d766de7ab6fb9aed7eef8a664aa2` | Linux Host RPM and Ubuntu Client DEB |
| `1.1.034-scaling-quality` | `feab22761a6cd2462ccd82b73dbee17eed8f1925` | Linux Host RPM and signed Mac Client PKG; original DMG wrapper also retained |

Paths are `artifacts/packages/candidates/<version>/<platform>/`.
Wacom candidate component pins were Client `eedb1ba8`, Host `2034c3eb` and
common-C `036df96f`. Scaling pins were Client `9d0bbe8b`, Host `57f85d1b`
and the same common-C; later README commits do not change those artifacts.

Passed hosted candidate runs:

- Wacom [Host](https://github.com/instinctual/plank/actions/runs/37686911394) and
  [Client](https://github.com/instinctual/plank/actions/runs/37686910847).
- Scaling [Host](https://github.com/instinctual/plank/actions/runs/37707420681) and
  [signed Mac Client](https://github.com/instinctual/plank/actions/runs/37707423366).

Host runtime RPMs use `BUILD_TESTS=OFF`; separate input test binaries are not
shipped. Host package gates verified root-owned `0700` log-directory metadata,
patch provenance and dependencies. Each candidate Host run passed three native
loss matrices (900/900 frames, no unrecovered source symbols) and 25 shuffled
input-suite repetitions (36 passed, three UHID-dependent skips per repetition).
The Ubuntu candidate passed shared-input, hidraw-worker, Wayland cursor,
audio/pacer, dependency, binary/version and no-autostart gates.

The signed Mac scaling build passed deployment target, compilation, component
tests, runtime closure, signing, notarization, stapling and Gatekeeper. The first
notarization wait timed out; attempt 2 passed unchanged. Exact-input dependency
caches were reused, not a new clean-bootstrap qualification.

Earlier production-shader fixtures passed 220 Metal area and 630 color cases,
including all 1024 10-bit levels. A CUDA fixture passed 114 8/10-bit area/identity
cases on the hardware-test GPU. At 5120x2160→3840x1620, measured area+10-bit
conversion averaged 0.679 ms over 30 iterations; this excludes capture, encoding,
transport and presentation. Standalone Host fixture logging uses builder Boost
1.75, not the pinned Boost 1.89 product input. No-GPU exit 77 is a skip.

Mac window/fullscreen transitions still change presentation only, never
renegotiate stream size. Native-size NvFBC/NVENC bypasses the resampler. Native
X11/x264 conversion and Linux Client sizing are unchanged.

## Last published release and rollback

[PLANK 1.1.030](https://github.com/instinctual/plank/releases/tag/v1.1.030)
remains the latest release. Exact source is
`e515fe411d5185d3236a8b5c19a14b012375183e`; original verified packages and
manifests remain under `artifacts/packages/releases/1.1.030/`.
The release's Client is `0af6d9fc`, Linux Host `b8308a44`, Client common-C
`55758dc5` and Kymux `3f7a9d86`. All four release builds and signing gates
passed; no new publication is implied by this handoff.

[Release notes](docs/releases/1.1.030.md) compare against 1.0.143. Upgrade Host
and Client together across that boundary: RaptorQ 2 is incompatible with the
older recovery format. Mac distribution is by PKG. Never rename old feature
candidates into release artifacts.

The pushed `checkpoint/audio-sync-1.1.027` tags remain in parent and Client:
root `179c3a719735b3065100e8c4ea7adfc3fe2f520d`, Client
`34c2adb89996c4e05ce4c6790e818b4d5ec66f2c`. This is a rollback point,
not proof that every audio issue was resolved.

## Remaining functional gates

Merging does not close hardware acceptance. See
[acceptance criteria](docs/development/acceptance-criteria.md), especially:

- Wacom pressure, tip/barrel clicks, Tablet Margins, matching/different hybrid
  tablet models, focus/held-contact recovery and temporary loss/transport stalls.
  Kernel touch-arbitration remains an unproven hypothesis; no module policy,
  fabricated neutral reports or device resets were packaged.
- Scaling: Scaled-Span versus Native, fullscreen→windowed, fractional window
  sizes, Retina/notch, multiple displays, color precision and input alignment.
  Qualify the identical Mac Client package on both macOS 15 and 27.
- Real audio/video synchronization, listening soak, duplex/camera lip sync and
  output restoration. Estimated clock phase is not acoustic measurement.
- Fresh/upgrade Mac setup and permissions, optional camera deactivation,
  uninstall/purge, login/logout, locked-session takeover and timeout recovery.
- Deferred Mac Wallpaper/Screen Saver pointer lag, Linux physical-display
  provenance mismatch and immediate-paste clipboard stress.

Current audio policy uses Host common-clock phase for macOS and separate
relative-rate handling for Linux. Smooth resampling is bounded to one percent,
with SDL output-demand/headroom guards. No extra audio-frame dropping or video
delay was added; recovering playback reserve can retain a few milliseconds.
A shortage-request counter is not a measured speaker underrun. See the
[audio plan](docs/development/plans/audio-sync.plan) and
[real-world procedure](docs/development/audio-sync-baseline.md).
No old sampler is still running merely because a prior note described a soak.

Keep machine identities and private evidence outside Git. Read the private notes
README before accessing any test system.
