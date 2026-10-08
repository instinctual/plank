# PLANK handoff

Read `AGENTS.md` and the relevant build runbook before work. Machine-specific
access and evidence belong in the external private notes, never in Git.

## Current work — native Apple Client integration

The operator authorized coordination with the contributor and separate
`apple-native-integration` branches, not a bulk import or replacement of the
shipping Client. Both branches are published:

- Parent starts at main `66f5c2ad775b093b41c991bc120cad7913c44c8a`.
- Client starts at main `0af6d9fc15197c11257b10e4eed40b0eba783886`.
- Product source, dependency gitlinks, package versions and defaults are unchanged.

[Client coordination issue #9](https://github.com/instinctual/plank-client/issues/9)
is the shared plan. It mentions the contributor, records the reviewed source
commits and requests agreement on the tested runtime/dependency checkpoints,
layout and contribution sequence. No reply or agreement has been received yet.

The proposed final Client layout is `app/` for the existing Qt/SDL Linux/macOS
application and `apple/shared/`, `apple/macos/`, `apple/visionos/` for the native
Apple implementation. Shared transport remains in the parent `protocol/` tree.
Do not create/move these directories before agreement. Import selected original
commits first, establish a reproducible build, then separate mechanical path
changes from behavior changes. Preserve authorship; do not rewrite the fork.

Order: shared Apple foundation and Vision Pro, current trust/precision/audio
contracts, parallel native Mac candidate, then separately reviewed tablet relay,
multiple-display and capture-quality extensions. Camera remains a separate
end-to-end gate. Draft [parent PR #24](https://github.com/instinctual/plank/pull/24),
reviewed at `1a7aa5e7a3ceb83709952a58a7b0aa313c91b7e1`, adds the PCAM v2
encoded-camera transport contract only. It is linked for parallel review, not
approved or merged, and does not supply the initial native Client checkpoint.

Priority integration gaps from source review: persistent pre-credential machine
trust; avoiding the native software fallback's 10-to-8-bit display conversion;
reconciling occupancy-driven audio sample skipping/repetition with current
bounded resampling; supported Host/profile/MTU behavior; and explicit regression
checks for changes to existing input workers. Hardware evidence reported by the
contributor is not independent qualification. Mac Client remains Apple Silicon,
macOS 15+ with SDK 27+; agree visionOS targets before extending the build matrix.

The integration uses a clean parent worktree at the canonical checkout's
`build/worktrees/apple-native-integration`, with a linked Client worktree at its
`apps/client`. Other submodules are intentionally uninitialized for this
coordination-only step. The canonical checkout remains on `scaling-quality`,
including the uncommitted README refresh. Its scaling and Wacom candidates are
preserved separately and are not implicitly merged into this branch.

Branch creation triggered the existing Hosted builds workflow; redundant run
`37712975340` was cancelled because no product change or package build was
requested. Its privacy and clipboard companion checks passed. Coordination
content passed local privacy/secret checks. No native build, installation,
hardware test, merge, release or signing authorization change was performed.

Next: obtain the contributor's checkpoint/layout agreement in issue #9, then
prepare the first focused Client PR against this integration branch. Existing
release evidence below is baseline evidence, not native Client acceptance.

## Released baseline — 1.1.030

The operator authorized merging the audio-playback-safety fixes, building a
release and retiring RK3576 research. Root and Client main are pushed. The
former integration worktree at
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
