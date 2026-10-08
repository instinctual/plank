# PLANK handoff

Read `AGENTS.md` and the relevant build runbook before work. Machine-specific
access and evidence belong in the external private notes, never in Git.

## Current work — scaling quality (not released)

Root, Client and Linux Host are on `scaling-quality`, based on root
`73d434071bc54e1789ad589ff53d48c2bd424103` and the Wacom candidate pins below.
Client common-C remains unchanged on `wacom-recovery`. The prior
`macos-scaling` and `wacom-recovery` branches/packages are preserved. Current
scaling source is committed/pushed dependency-first; main is unchanged.
Linux Host RPM and signed Mac Client PKG candidates **1.1.034-scaling-quality**
are built, downloaded and independently SHA-256 verified. No installation,
merge or release was performed. Exact candidate root source is
`feab22761a6cd2462ccd82b73dbee17eed8f1925`.

- Client: `9d0bbe8b4d6aae246b80924327a1efb3ef6e00b0`.
- Linux Host: `57f85d1b297fa22a23dc8be5e206f04bffc20370`.
- All other dependency pins remain those listed in the retained Wacom baseline.

The operator confirmed Native (1:1 pixels) avoids the reported degradation.
Read-only Client logs showed an active 5120x2160 backing canvas but an advertised
3840x2160 native mode, resulting in a 3840x1620 requested stream. The Linux Host's
direct NvFBC/NVENC conversion used point sampling even when reducing the image.
The Mac window then displayed that already-reduced stream at 1:1. Private logs
and target identities remain outside Git.

Implemented:

- Every Mac Client Host/layout now uses the active backing-pixel snapshot for
  initial stream sizing. Keep logical/Retina/notch geometry separately, and
  preserve Linux Client sizing. Window/fullscreen transitions still change only
  local presentation; they never renegotiate the stream resolution.
- Carry forward the Mac area-filter implementation from Client
  `7ad14c3ef574e5b8f91875a2ce914ea601128879` and
  `cb3861e1fc709cd97b4e9d87d7aea2d8f699a015`, without replacing Wacom changes.
- Direct NvFBC/NVENC reductions use separable GPU area integration before the
  existing color conversion. Float intermediates are retained per encoder;
  no CPU readback, extra frame queue, matrix change or 8-bit requantization.
  Native-size conversion bypasses the resampler. Native X11 and x264 conversion
  are unchanged.

Validation so far:

- Ten portable fullscreen/geometry wiring tests, two Metal overlay checks,
  two Host conversion-wiring checks and 62 CI policy tests pass. Current/native
  CoreGraphics and nine Qt stream-sizing results pass at deployment target 15.0
  on the dedicated SDK27 Mac, including an advertised 4K/active 5K mismatch.
- Production Metal shaders pass 220 area cases plus 630 color checks on that
  Mac, including native/upscale equality, fractional/cropped/anisotropic
  reductions and all 1024 10-bit code levels. Not live-window acceptance.
- Production CUDA kernels and colorspace code built on the Rocky builder with
  GCC14/CUDA13 and all supported CUDA architectures. The standalone fixture
  passed 114 8/10-bit area/identity cases on the hardware-test NVIDIA GPU,
  including thin lines, stride/border sentinels, unchanged 1:1 output and 5K.
  Average GPU area+10-bit conversion over 30 iterations: 0.679 ms for
  5120x2160→3840x1620; 0.177 ms→1920x810; 0.402 ms→1x1. These timings exclude
  capture, encoding, transport and Client presentation.
- The component fixture uses builder Boost 1.75 only for standalone logging;
  it is not a product build or a replacement for the pinned Boost 1.89 package
  input. Tests are in `tests/video/linux-cuda-scaling/`; configure with the
  documented builder compiler paths and `PLANK_FFMPEG_INCLUDE` pointing at the
  prepared Host FFmpeg headers. Exit 77 means no GPU, not a passing GPU test.

Integration review and focused checks are complete. Both builds use that source:
[Linux Host](https://github.com/instinctual/plank/actions/runs/37707420681) and
[signed Mac Client](https://github.com/instinctual/plank/actions/runs/37707423366).
The Host passed full compilation, package gates, three native loss matrices
(900/900 frames each, zero unrecovered source symbols) and 25 shuffled input
suite repetitions (36 passed, three UHID-dependent skips per repetition).
The RPM is production `BUILD_TESTS=OFF`; the separate test build is not shipped.
Downloaded checksum, version, source provenance and root-owned `0700` log
directory metadata were independently verified. The extracted media binary
contains the GPU area-scaling marker and the qualified candidate version.

The first Mac attempt passed compilation, component tests and signing, but
Apple notarization exceeded its 600-second processing wait. **Attempt 2 passed
unchanged**: full Client compilation/tests, dependency closure, version and
deployment-target checks, signing, notarization, stapling, Gatekeeper and signing
cleanup. The successful Host and Mac runs reused all exact-input dependency
caches; application objects and package gates ran fresh. This is not a new
clean-bootstrap qualification or live macOS 15/27 acceptance.

Original files are retained under
`artifacts/packages/candidates/1.1.034-scaling-quality/`, with checksums and
per-package source provenance in its manifest. Use the PKG to install the Client;
the build's DMG wrapper is retained alongside it.

| Package | Bytes | SHA-256 |
| --- | ---: | --- |
| `linux/plank-host-1.1.034-0.scaling_quality.1.el9.x86_64.rpm` | 8715253 | `17729a5e929e88f5e32ee153faaf985c3cdd1594b249b586d1528c3ed4e2896e` |
| `macos/plank-client_1.1.034-scaling-quality_arm64.pkg` | 72873864 | `c7e438838dfc2748866b0f9bb36282dcde216d57e947e2b92055a79311506a77` |
| `macos/plank-client_1.1.034-scaling-quality_arm64.dmg` | 74399335 | `5d9bbad845689524f2bc571d585eb6ed531817e0bb9a70ba1975c9d166243cf6` |

Only this candidate branch was added to the protected signing allowlist; remove
its permission when retiring the branch. Next: operator manual installation and
visual testing. No merge or release is authorized yet.
No installations, reboots, session interruption or display changes were made.
Live acceptance must cover Scaled-Span versus Native, fullscreen→windowed,
fractional window sizes, Retina/notch, multi-display and input alignment.

## Retained baseline — Wacom recovery (not released)

The operator requested the Wacom review fixes in a new branch. The retained
`wacom-recovery` branches are based on root main
`66f5c2ad775b093b41c991bc120cad7913c44c8a`. Existing `macos-scaling` and
`wacom-pressure` candidates/branches were preserved, not merged or relabelled.

Linux Host RPM and Ubuntu Client DEB candidates **1.1.033-wacom-recovery** are
built, downloaded and independently SHA-256 verified. Both were built on the
GitHub-hosted target-OS builders. The branch and required dependency commits are
pushed; nothing is merged or released. No installation, reboot, live loss
injection or kernel touch-arbitration policy change was performed.

Exact candidate package source (later notes do not change artifact provenance):

| Component | Commit |
| --- | --- |
| Root | `353eb071f0f8d766de7ab6fb9aed7eef8a664aa2` |
| Client | `eedb1ba822fff80638a4612da6648b6d25a80852` |
| Linux Host | `2034c3ebdf87b0d8046f77f15d84478cd4c06253` |
| Client common-C | `036df96f2d1577af7a1b08c05d87a5218fff7c9b` |

Other recursive dependencies are unchanged from the base, including Host
header-only common-C `3a97a58f215323753cfd1180af760ec7e3253538`, libvirtualhid
`a0d3aa0cc4d53daa18bfa2f2fbdf848957b6d294`, GoogleTest
`52eb8108c5bdec04579160ae17225d66034bd723`, Kymux
`3f7a9d8618978287186e5d6ce0eaa067743cb06c`, qmdnsengine
`920c097ffa742e2968290f15d4dde6693aec02e5` and Host build-deps
`c29c4822cb96f5bfeb8640e72601c5cf4e3c3137`.

Original packages are under
`artifacts/packages/candidates/1.1.033-wacom-recovery/`, with a manifest,
per-package checksum sidecars and `SHA256SUMS`:

| Package | Bytes | SHA-256 |
| --- | ---: | --- |
| `linux/plank-host-1.1.033-0.wacom_recovery.1.el9.x86_64.rpm` | 8694103 | `3b70f2b55d0a2060a15b48d533fed51547aace8c7544f287cac9680fab6f1209` |
| `linux/plank-client_1.1.033-wacom-recovery_amd64.deb` | 15607780 | `162b04c7b0078c7e051f3cdf19f17d466af83fec303522cefa6f786bd7642e97` |

Hosted build and package gates passed:

- [Linux Host](https://github.com/instinctual/plank/actions/runs/37686911394):
  runtime RPM built with `BUILD_TESTS=OFF`; dependency-patch, binary, manifest,
  configuration and root-owned `0700` log-directory checks passed. Three native
  loss-matrix repetitions passed. The separately built Host input suite passed
  36 tests across 25 shuffled repetitions, with three UHID-dependent skips per
  repetition. These skips are not real-device acceptance.
- [Ubuntu Client](https://github.com/instinctual/plank/actions/runs/37686910847):
  shared-input backpressure, bounded hidraw worker and Wayland cursor protocol
  tests passed, as did audio/pacer, version/banner, runtime dependencies,
  private FFmpeg/RUNPATH, DEB manifest and no-autostart checks. The downloaded
  packaged binary hash matches its embedded build record.
- Exact dependency caches were reused on the Host. The Client reused Rust and
  Cargo caches but rebuilt its pinned FFmpeg after a cache miss. Neither run
  installed the product or performed compositor, GPU or physical-tablet tests.

Next: install both candidates on the authorized hardware test pair and exercise
pressure, clicks, Tablet Margins, focus loss, reconnect and transport stalls.
Do not describe compile/package gates as functional acceptance.

Implemented:

- Preserve ordered input and raw-tablet feedback on transport backpressure.
  Bounded queues fail the session explicitly instead of silently losing clicks,
  releases, feature requests or attach acknowledgements. Cursor positions may
  coalesce; raw reports may not. Normal uncongested sends have no added delay.
- Move Linux hidraw feature ioctls off capture/callback locks to one bounded
  worker; invalidate old-generation completions and release local grabs safely.
  Drain report bursts without the previous unconditional per-report sleep.
- Cancel outstanding kernel GET/SET queries on suspend/generation retirement,
  answer new suspended queries with ENOTCONN, and reuse only started endpoints.
  A late UHID_START is still recorded while suspended. Healthy endpoint IDs,
  descriptors, coordinate mapping and Flame Tablet Margins identity are retained.
- Apply Wayland tablet cursor updates through an owned anchor surface, without
  waiting for video commits or committing SDL's surface.
- Keep normalized pen barrel-button events from changing contact/pressure.

Earlier component-only validation on the appropriate builders:

- Rocky: 30 production Host component tests passed 25 shuffled repetitions.
  The UHID boundary is simulated; libvirtualhid and GoogleTest source pins are
  checked. Logging in this standalone harness uses the builder's Boost 1.75,
  not the product's prepared Boost 1.89. This is not a full Host package build.
- Eight shared input/queue tests passed locally and on Ubuntu, including 25
  Ubuntu repetitions with ASan/UBSan. Includes ordered mouse/key releases under
  backpressure, prompt stop, explicit exhaustion and cursor/control isolation.
- Ubuntu: release-mode worker tests and the production Wayland cursor protocol
  fixture passed, also under ASan/UBSan; the actual Linux hidraw adapter compiled
  with warnings-as-errors. No real compositor/tablet or installed Client tested.
- Shell syntax, repository-layout/link checks, diff checks and new-content
  privacy checks passed. Client packaging and Host CI input filters now include
  the new regression gates.

Tests live in `tests/input/linux-recovery/`, Client `tests/linuxrawwacom/` and
common-C `tests/native-input-backpressure.c`. Protocol notes document limits and
failure behavior. Local evidence is under ignored `build/tests/wacom-recovery/`;
builder-specific source/worktree locations are in external private notes.

Still unproven: evdev contact cleanup is not evidence that hid-wacom's private
touch/proximity arbitration cache resets for every model. Do not claim that
hypothesis fixed or introduce fabricated neutral reports/device resets. Real
focus-loss/touch-held/reconnect testing must decide whether further repair is
needed. Also qualify pressure, tip/barrel buttons, Tablet Margins, matching and
different hybrid tablet models, and induced loss/temporary transport stalls.

The subsequent package build changes only version/changelog and packaging
records relative to implementation checkpoint root `684e3f9`, Client
`ad983266`. The proposed `wacom touch_arbitration=0` module option remains an
unqualified administrative experiment, not a packaged policy or a proven fix.

## Released baseline — 1.1.030

The operator authorized merging the audio-playback-safety fixes, building a
release and retiring RK3576 research. Root and Client main are pushed. The
release was built from `main`; the former integration worktree at
`build/worktrees/macos-session-takeover` is detached at the release source.
Do not infer a branch from that historical worktree name.

Exact package source:

| Component | Commit |
| --- | --- |
| Root | `e515fe411d5185d3236a8b5c19a14b012375183e` |
| Client | `0af6d9fc15197c11257b10e4eed40b0eba783886` |
| Linux Host | `b8308a44c129599ef50b75c30051cee1bb55bf26` |
| Kymux | `3f7a9d8618978287186e5d6ce0eaa067743cb06c` |
| Client common-C | `55758dc5160c7f60680345533e887f9aaa5b4dda` |
| Host header-only common-C | `3a97a58f215323753cfd1180af760ec7e3253538` |
| qmdnsengine | `920c097ffa742e2968290f15d4dde6693aec02e5` |

Other recursive pins remain in these exact submodule trees. Notes-only commits
after the package source do not change the source of the release artifacts.

All four exact-source GitHub builds passed from main:

- [Linux Host](https://github.com/instinctual/plank/actions/runs/36644830124).
- [Linux Client](https://github.com/instinctual/plank/actions/runs/36644833766).
- [Signed Mac Host](https://github.com/instinctual/plank/actions/runs/36644836963).
- [Signed Mac Client](https://github.com/instinctual/plank/actions/runs/36644840048).

All four original packages are downloaded and independently SHA-256 verified
under `artifacts/packages/releases/1.1.030/`, with manifest and sidecars.
[PLANK 1.1.030](https://github.com/instinctual/plank/releases/tag/v1.1.030)
was published on September 29 as the latest non-prerelease. Annotated tag
`v1.1.030` points to the exact package-source commit above. GitHub asset digests
match the local originals. Published checksums/manifest use downloadable
basenames; the local catalog retains its platform directories. Never relabel
the feature candidates. No release build or publication step remains pending.
Both macOS products are distributed as signed/notarized PKGs, not Client DMGs.
Production Linux RPMs use `BUILD_TESTS=OFF`; separate test builds must not
replace the packaged binary. Exact dependency caches may be reused; application
builds and package gates ran again. No test machine was upgraded or rebooted.

| Package | Bytes | SHA-256 |
| --- | ---: | --- |
| `linux/plank-host-1.1.030-1.el9.x86_64.rpm` | 8687281 | `a3db70a7898691891cb4ed0086f6224cdedaf6a00657c8a239f21fe2d0ab0731` |
| `linux/plank-client_1.1.030_amd64.deb` | 15596188 | `1bdc7c34648d1839f2f89526b24fb2d6c2ef2e4f6a09f2929d73176501289a57` |
| `macos/plank-host_1.1.030_arm64.pkg` | 6993611 | `a308a36eef6e4c024ab8f1e88d1f8eb5f7ccbc6d8134b307236d026be1052262` |
| `macos/plank-client_1.1.030_arm64.pkg` | 72866823 | `f8a6117ec63c46d72b3942f5612bddbaf586bfb1712cef4c4a113e9221afa177` |

The Linux Host passed three 150 Mbps/60 fps loss-matrix repetitions at 0, 0.5,
1, 3 and 5% injected loss. Its input suite passed 32 tests with three UHID-dependent
skips per iteration; skips are not hardware acceptance. Both Client builds passed
the finite-queue audio suites, 17 Pacer and eight independent-rate results. Mac
signing, notarization, stapling, Gatekeeper and signing cleanup all passed.

[Privacy](https://github.com/instinctual/plank/actions/runs/36645041219) and
[clipboard](https://github.com/instinctual/plank/actions/runs/36645044171)
checks passed for the release source. Local repository-layout, release-version,
62 CI policy and 20 privacy-guard tests passed. These are not hardware acceptance.

The [release notes](docs/releases/1.1.030.md) compare against published 1.0.143.
Upgrade Host and Client together: the RaptorQ 2 recovery format is incompatible
with that old release. Latest audio changes themselves are Client-side only.

## Audio implementation and qualification boundaries

Client `ccbb875e` snapshots video PTS before EGL transfers the AVFrame reference,
restoring the video-clock reference used by audio correction. The operator
accepted the improvement in 1.1.026; remaining drift led to the later fixes.

Client `34c2adb8` replaces common-clock macOS Host sample-count fitting with one
source-phase controller. It uses smooth resampling, a zero phase target, bounded
one-percent correction, filtering, slew limits and stale-clock/queue guards.
Linux Host timestamps have independent epochs and retain their separate relative
rate policy. Do not interpret Linux timestamps as absolute A/V phase.

Client `eecdab35` replaces the fixed producer-side starvation cutoff with actual
SDL output-demand feedback. A callback records requests and post-pull headroom
under SDL's existing stream lock. The decoder snapshots counters under that lock
and logs once per second away from the output thread. No callback allocation,
logging, additional queue, silence insertion, audio-frame dropping or video delay.

Catch-up stops at low headroom. Three distinct healthy pulls are required to
resume; low headroom also constrains the same bounded resampler below zero to
recover reserve when the device clock is faster. The initial 028 attempt merely
stopped catch-up and failed an extended faster-device test; do not distribute it.
The 029 recovery can retain a few milliseconds more audio. Do not promise zero
latency cost or acoustically exact sync. `shortage_requests` is not a measured
speaker-underrun counter: SDL can overestimate required input.

Candidate 029 passed actual SDL/qualified FFmpeg finite-queue tests with
independent arrival/output clocks, signed 400 ppm drift, differing output chunks,
jitter, stale/wrap/format cases and an infeasible phase target. All six cases had
zero post-warmup short reads; settled/final minute phase means differed by less
than 0.1 ms in those models. ASan/UBSan, 17 Pacer results, eight independent-rate
results and timestamp observer/callback/analyzer gates also passed. These are
models/component tests, not a real speaker or lip-sync measurement.

Earlier 027 real monitoring ended at a confirmed manual reconnect after about
2 h 21 m. Estimated median lag remained bounded at 29.35 ms, but the operator
reported brief crackles and occasional holds. One crackle trace had no audio
concealment requests and briefly empty SDL input; this supports investigation,
not proof of hardware starvation or exclusion of delivery/source glitches.
The sampler deadline was September 27 at 16:16 Pacific and has passed. Do not
describe those samplers as active or treat their old log as a new-version soak.
Private final evidence has not been reassessed in this release task.

Release authorization is not completion of long-duration listening or measured
absolute A/V synchronization. Next functional gate is a real synchronized
flash/click and listening soak on the operator-selected Host/Client/output path,
then cross-platform checks. Do not claim acoustic sync from estimated phase.
See [plan](docs/development/plans/audio-sync.plan) and
[procedure](docs/development/audio-sync-baseline.md).

## Rollback and retained artifacts

Annotated `checkpoint/audio-sync-1.1.027` remains pushed in root and Client:
root `179c3a719735b3065100e8c4ea7adfc3fe2f520d`, Client
`34c2adb89996c4e05ce4c6790e818b4d5ec66f2c`. It is a rollback checkpoint, not proof
that every audio issue was resolved.

The original 029 DEB remains at
`artifacts/packages/candidates/1.1.029-audio-playback-safety/linux/plank-client_1.1.029-audio-playback-safety_amd64.deb`:
15,598,592 bytes, SHA-256
`0dec7f8828e73f2d1c4878870f5c2fc31542f1ce8a4bbf621995a4a35c8b5343`.
Its source is root `2a8e4b6b490b0756c586299e7704f62c4f1869a3` and Client
`eecdab352caa8fcf2001daf2d359425153fc90d7`. Hosted Ubuntu 36356543713 and unsigned
Mac 36356545044 passed. Catalog functional validation remains unrecorded.
Earlier mainline 1.1.024 packages remain in their original release catalog.
Detailed historical candidate evidence is retained in Git history and manifests.

## Cleanup and other remaining gates

The retired `rk3576-client` branch had no unique commits or product changes.
Its local branch, untracked plan and obsolete local routing notes were removed;
no remote RK branch existed. A temporary recovery copy of those notes is outside
the checkout. Generic upstream Rockchip support and unrelated worktrees remain.

The operator accepted the Mac setup centering/foreground behavior and matching
Client styling. Wacom lifecycle PRs were integrated before live qualification;
do not turn their component-test results into pressure/margins/hybrid acceptance.
Reference [Wacom review](docs/development/reviews/wacom-focus-contact-pr-review.md).

Remaining gates in [acceptance criteria](docs/development/acceptance-criteria.md)
still apply, especially:

- Real audio/video sync, duplex/camera lip sync, long sessions and output restore.
- Real Wacom pressure, margins, hybrid devices, focus and held-contact recovery.
- Fresh/upgrade Mac configuration, optional camera deactivation, Client uninstall
  and purge, and new-user permission behavior. Do not reset grants without approval.
- Login/logout, locked-session takeover, timeout handling and notched fullscreen;
  test the Mac Client on both supported macOS 15 and 27.
- Deferred Mac Wallpaper/Screen Saver pointer lag, Linux physical-display
  provenance mismatch and clipboard immediate-paste stress qualification.

Keep machine identities, credentials, private captures and operational evidence
outside Git. Read the private notes README before any machine-specific work.
