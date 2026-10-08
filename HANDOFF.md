# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Machine-specific access,
credentials, captures and operational evidence belong in the external private
notes, never in Git.

## Current work — native Apple Client integration

Native build automation is being qualified on `native-builds`, based on the
accepted integration below. `.github/workflows/apple-native.yml` builds native
Mac, Vision device and Vision simulator on GitHub-hosted `xcode-27` workers.
The separate `vision-testflight` environment is reserved for protected manual
uploads; public PRs have no signing credentials. See
`docs/development/build/apple-native-builds.md`. No local Mac builds, shipping
main merge, production release or hardware acceptance accompanies this work.
Hosted run [37819200521](https://github.com/instinctual/plank/actions/runs/37819200521)
passed all three native Release builds, exact dependency bootstraps, component
tests and artifact gates. Its root is `d596187575f0984c6641f596e517da22736babec`,
Client `693a14a68e60e5434251b86fa158b88a2f410a6c`, version 0.1.0 / build 3.1.
The device archive includes UUID-matched crash symbols; Mac and simulator ZIPs
are unsigned/ad-hoc inspection artifacts, not distributable PKGs or TestFlight
installs. Its protected Apple export failed before upload. The internal app
record and tester group are configured; first TestFlight delivery remains
pending. Do not describe compiled workflow artifacts as an installable build.

Qualification fixed three build-only defects: CMake emits dSYMs outside its
archive; SDK 27 Rust host proc-macros require the release-profile strip override;
the Vision simulator lacks the real-device presentation-timestamp callback.
Real-device rendering behavior and shipping client paths are unchanged.
The follow-up root `d36da1fbf328d21d3c8a67558b9bf6bc9c393bc1` adds sanitized Apple
failure categories and requires `IN_BETA_TESTING` before announcing readiness.
All 74 root CI tests pass. Hosted run
[37820515210](https://github.com/instinctual/plank/actions/runs/37820515210)
again passed all builds (version 0.1.0 / build 4.1). Apple export then reported
`cloud-signing-denied` and `missing-profile`; credential cleanup passed. Read-back
confirms no Vision build has been uploaded. Work is waiting on the operator to
confirm the Team API key's role and signing authority. Do not repeatedly rebuild
or alter account permissions to work around this denial. No job remains running.

[Client PR #10](https://github.com/instinctual/plank-client/pull/10) imported the
Vision foundation at `1953cc11a4b281f24286c11301d10fc76601a972`.
[Client PR #11](https://github.com/instinctual/plank-client/pull/11) is now approved
and merged into Client `apple-native-integration` at
`e8d8536486bf2eb0d7080aab8965f12d7d87b0af`; the parent integration branch pins
this exact merge. Its tree matches reviewed head
`ac9fb757979cf6c92768448345abad592920ddc5`. Original contributor commits and
authorship are preserved.

The imports add the Vision Client at `visionos-native/`, the separate native Mac
pilot at `apple-native/`, and public unsigned build recipes. The shared Mac
Wacom worker gains an injectable sender/native compile boundary, preserving the
existing Qt/SDL default path. Client dependency pins and the Linux Host are
unchanged. Shipping parent and Client `main` remain unchanged by these imports;
the native pilot does not replace the shipping application.

Both PR #11 review findings are resolved: manual/timeout tablet opt-out retires
USB capture and admission while allowing release messages through the live
sender; cursor ownership uses filtered physical activity rather than raw status
reports. The source includes regression tests for late hotplug, focus callbacks,
new sessions, ordered release, background status and callback revocation.
Independent C-wrapper lifetime/barrier/epoch tests passed with Clang ASan/UBSan,
alongside shell/Python syntax and whitespace checks. Hosted native Swift/AppKit
component tests and Apple builds subsequently passed as recorded above. Physical
streaming/tablet acceptance was not repeated. Contributor-reported results are
recorded in the Client's native Mac integration document, not promoted to
hardware qualification here.

[Kymux PR #5](https://github.com/instinctual/plank-kymux/pull/5) was approved and
merged first into dependency `main` at
`04c3f179b3c6cb8fea237638d2be1d76eca2e719`, retaining both stale-video retirement
and the shipping audio/video completed-packet drain fix. It fixes group lookup
after eviction and rechecks retirement before admitting media. Resource bounds,
wire format, ABI and pacing are unchanged.

The native recipe still selects its distinct parent
`6c6865562713d265a657dec613f55169ccb379b2` and Kymux
`8654cfece0fe5f3ab35177f520ca9378f6d35c24`; the latter has the identical tree to
the dependency merge. Do not silently replace the native parent with current
PLANK main. The parent's ordinary product Kymux pin remains `3f7a9d86`, so the
dependency merge does not change shipping packages. Integration common-C stays
at `036df96f2d1577af7a1b08c05d87a5218fff7c9b`.

Independent validation of these exact native transport inputs passed all 33
audio/video component tests and 53 parent transport unit tests on Rust 1.89.0;
six integration tests were intentionally not run. The three eviction regressions
and both late-config draining tests pass. The subsequent hosted build results
above use Python 3.12+ as required by the native recipe; the local 3.9 runtime is
not a supported substitute. No package was installed, and no hardware acceptance
is implied.

The coordination worktree is `build/worktrees/apple-native-integration`, with a
linked Client worktree at `apps/client`; other submodules remain uninitialized.
[Client issue #9](https://github.com/instinctual/plank-client/issues/9) remains
open. Next reconcile persistent pre-credential Host trust, exact-format decoder
fallback, audio clock/input contracts and current parent transport/CI before
production acceptance. Optional tablet sharing and display/window/wheel slices
remain separate follow-on reviews; camera product work and directory moves are
also separate. Retain the documented streaming/Wacom and OS gates. No package,
release, installation or hardware-session change accompanies this merge.

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

## Native Apple Client coordination — agreed

[Client issue #9](https://github.com/instinctual/plank-client/issues/9) is the
shared plan. The contributor's
[checkpoint handoff](https://github.com/instinctual/plank-client/issues/9#issuecomment-6050900867)
confirms the integration targets, eventual layout, PR order and division of work.

Reported tested runtimes and published review checkpoints are distinct:

| Candidate | Tested runtime | Review checkpoint |
| --- | --- | --- |
| Vision build 46 | `d0056978e823a7f9a999efe9336cdb155aa61f35` | `5f2d28a10a0a1a113b7618bcf4e7b1e521f00725` |
| Native Mac build 24 | `5db90ffeb7568105a664df0f340c5769c79b0603` | `04675c95c9486e8f22d7587348d705bb44aeb1a4` |

The handoff records their original transport, Kymux, common-C, tablet-relay and
media-library inputs. These are evidence for those builds, not replacements for
the maintained pins above. Reconcile differing inputs explicitly.

The shared Apple foundation/Vision PR #10 and separate native Mac foundation
PR #11 are merged into `apple-native-integration` at their existing source paths,
with explicit public dependency inputs and unsigned build/test instructions.
Next reviews are the contributor's optional tablet-sharing and display/window/
wheel slices, retargeted in dependency order. Preserve commits and authorship;
do not promote the native pilot to shipping main. The eventual mechanical move
into `apple/shared/`, `apple/macos/` and `apple/visionos/` remains separate. Shared
transport stays in the parent `protocol/` tree. Do not start a competing import
or engine rewrite.

The contributor leads native architecture and device qualification; upstream
owns current trust, precision, audio/input contracts and parent CI/package
reconciliation. The native Mac pilot remains a separate test application.
Tablet sharing, multiple displays, capture-quality selection and camera product
integration stay independently reviewable. Parent PR #24 is already merged;
it is not a pending draft or complete camera product.

Remaining native gates: persistent pre-credential Host trust; exact precision on
decoder fallback; bounded smooth audio resampling and correct Host clock epochs;
supported Host/profile/MTU/session scope; Wacom startup, drag/buttons/pressure,
reconnect, hotplug and multi-window recovery. Periodic video stutter and previously
reported Host input-queue overflow are unresolved in the contributor's runtime.
Current mainline recovery code is present, but that is not proof that these
native observations are fixed. Coordinate any overlapping backpressure work.

Reuse accepted evidence for unchanged exact inputs; do not repeat transport
tests merely to import commits. Changed inputs and reconciled behavior still
need targeted regression tests. Actual Vision device/OS evidence remains to be
recorded; the existing archive declares visionOS 26.0. Native Mac builds retain
Apple Silicon/macOS 15+, SDK 27+, with same-package runtime acceptance on 15 and
27 still required. The macOS Host remains 27-only. Public PR builds remain
unsigned and separate from protected signing/TestFlight.

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
