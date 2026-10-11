# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Machine-specific access,
credentials, captures and operational evidence belong in the external private
notes, never in Git.

## Current work — persistent Linux desktop tablet

Continue in `build/worktrees/wacom-persistent`, branch `wacom-persistent`, based
on `client-session-recovery` parent `1572c09e26d6ce7db20d9d1feefe11a3155963b8`.
This is separate from the unshipped `ubuntu-qt-session` experiment. Candidate
**1.1.039-wacom-persistent**, Linux Host only, is built and downloaded. Client source remains
`58f4df097c1cdf11bf6b4b429701f156e2b10109`; the existing
`1.1.037-client-session-recovery` DEB can test this Host without an update.
No protocol, Client, macOS or physical-tablet policy changes are involved.
Linux Host fix `65dc0f1be60fe78d0457364f83813118c70bc8a8` is pushed. Host
libvirtualhid remains `b793fa2f5369218c43e09c58d5b96a0cc638bf05`; header-only
common-C remains `3a97a58f215323753cfd1180af760ec7e3253538`.

Read-only field evidence showed orphaned Desktop reservation cleanup replacing
a raw-HID endpoint group after network interruption. XInput then reused a former
eraser ID for the new stylus. Restarting Flame cleared the observed symptom;
the recorded stroke sample did not contain a tip-down event, so do not claim a
complete input-event reproduction. Private evidence remains outside Git.

The fix removes tablet destruction from reservation cleanup, terminate-all and
last-stream teardown. Session join still releases held input and suspends raw
forwarding. Devices belong to the desktop worker's input subsystem, not a
stream reservation. Matching identity/descriptors reuse healthy endpoints;
changed devices, incomplete probes and repeatedly unverifiable contact cleanup
retain their existing recovery. Worker shutdown/user-desktop transitions still
destroy devices. Authentication and desktop ownership checks are unchanged.

Validation so far: the two new reservation regression tests fail on the old
implementation and pass with the fix. All 56 isolated Host input tests pass,
including 25 shuffled repetitions. The wrapped-UHID fixture confirms repeated
fresh-launch reconnects do not create/destroy devices, Client generation-counter
restart can reuse the same device, changed identity replaces it, stale reports
and late lease cleanup cannot affect the new stream, and final shutdown closes
the endpoints. The full Host input CI now runs this fixture as well as the
production test binary. All 70 root CI-policy tests pass.

The first hosted attempt at parent `258104f7e6182b5c0b6c116dbf61adf32aa9c01d`
([run](https://github.com/instinctual/plank/actions/runs/38116001405)) built
the `.038` Host and RPM, passed package gates, three native loss matrices and
25 shuffled production input-suite runs (45 passed, three kernel-dependent
skips per run). It then failed compiling the additional wrapped-UHID fixture:
its CMake target omitted header-only Boost links. No artifact was uploaded.
Local fixtures had inadvertently obtained those headers from distro Boost.
The target now links pinned Asio, Endian and Format explicitly, and CI rejects
system Boost paths in the fixture's compiler dependencies. All 56 component
tests passed another 25 shuffled runs using only pinned Boost headers.
All 56 also passed five shuffled repetitions with ASan/UBSan and leak detection,
again using only pinned Boost headers. Evidence is under `build/tests/wacom-persistent/`.
The `.039` Host-only retry passed at exact parent
`9c780c30fc99297fb17341afb69db821ee895752`
([run](https://github.com/instinctual/plank/actions/runs/38156644894)).
All four dependency caches restored and verified; bootstrap took 27 seconds.
Source/privacy and clipboard gates passed. The Host job took 24m17s, including
fresh application/test compilation, RPM gates, three consecutive native loss
matrices (900 frames per run, zero unrecovered source symbols), 25 shuffled
production input runs (45 passed, three kernel-dependent skips each), and
25 shuffled wrapped-UHID fixture runs (56 passed each). The RPM remains the
`BUILD_TESTS=OFF` production payload. No hardware acceptance is claimed.

The original RPM is checksum/provenance-verified in the canonical catalog:
`artifacts/packages/candidates/1.1.039-wacom-persistent/linux/`
`plank-host-1.1.039-0.wacom_persistent.1.el9.x86_64.rpm`.
Size: 8721998 bytes. SHA-256:
`a674d4a9a500c00fee985651014370ee15a7784892c7a43ca40637645303a884`.
The extracted media ELF reports `1.1.039-wacom-persistent`; its SHA-256 is
`df3b0d51207bd4b0a7333e6e8233160cfd152dc232dd68202bea77950a529537`.
Local inspection also verified the RPM-owned root:root `0700` log directory.
The downloaded and locally collected manifests are byte-identical. The full
CI log is retained at `build/tests/wacom-persistent/host-1.1.039-ci.log`.
No build remains running. No merge, release or installation was performed.

All four Host dependency caches missed in that first attempt. The earlier
Ubuntu SDL cache work changed the shared cache script, which participates in
every component fingerprint; this invalidated unrelated Host keys. Versions
were unchanged, and new exact-input caches were saved successfully. Keep this
cache-granularity inefficiency separate from the test-target repair; no cache
validation was weakened.

No package has been installed and no machine restarted or interrupted.
Do not merge/release without acceptance.
Next hardware gate: after installing the Host and restarting Flame once to
clear any previously cached device identities, leave Flame running and interrupt the Client network for
about ten seconds, reconnect, and verify stable Host XInput device identities,
hover, tip/barrel buttons, pressure and Tablet Margins. Also test ordinary
disconnect/reconnect, Client restart and authorized takeover. Real-kernel
cleanup, XInput identity and Flame acceptance are not proved by the fixture.

## Inherited candidate — Client session recovery

Continue in `build/worktrees/wacom-state-recovery`, now on
`client-session-recovery`. Parent base `5ac23ba7f6f5a84c347e3081791521e25a369c2e`
includes the complete `.036` Wacom work below; this is not based on main.
Client source `58f4df097c1cdf11bf6b4b429701f156e2b10109` and common-C
`437be9a0a4d164efdf9ed20dc6dd5a2b7b9edc90` are pushed. Exact Ubuntu package
source is `c774091962ede46dcd638642637145d91909675e`. Host/transport pins and
`.036` artifacts are unchanged. Candidate version is
`1.1.037-client-session-recovery`, not a release. No build remains running.

The occupied end-user machine must not be interrupted. Private read-only evidence
identified a null Wayland proxy call, but no stack trace survives to establish
its caller. Geometry warnings also occur on successful streams. Do not present
the warning as the proven cause, or claim field acceptance from isolated tests.

Candidate changes: callback lifetime exclusion during input destruction;
checked Wayland cursor/toolbar constructor failures; bounded callback-queue
failure diagnostics; a private SDL 3.4.2 one-line tablet cursor retirement repair.
The latter uses the tablet surface instead of the independent mouse surface.
The OS SDL stays untouched. Tests inject allocation failures, late releases,
callback stalls and independent tablet/pointer surface states without a session.
Isolated Ubuntu tests pass normally and with ASan/UBSan: callback retirement,
worker/lifecycle, Wayland allocation failures/recreation/pending releases; all
eight common-C tests pass, including forced callback timeout then reconnect.
Negative controls reproduce a null SHM-pool crash in the old PLANK code and a
null-pointer-surface failure in the actual unpatched SDL retirement function.
Patched SDL passes all eight independent tablet/pointer fixture combinations.
Root CI policy/cache tests (68) and package build-path tests (10) pass.

The [Ubuntu hosted build](https://github.com/instinctual/plank/actions/runs/38091147661)
passed compilation, component tests, version/banner, dependency/runtime,
private SDL driver, package-path and autostart-absence gates. The original DEB
is downloaded and checksum/provenance-verified in
`artifacts/packages/candidates/1.1.037-client-session-recovery/linux/`:
`plank-client_1.1.037-client-session-recovery_amd64.deb`, 17028500 bytes,
SHA-256 `e067c59409ec4256d5bf4765d98276015be7cbcdd300993d72c4e53764b8c5e8`.
Local payload inspection independently confirmed the exact nested source pins,
the package-relative `$ORIGIN/../lib/plank` RUNPATH and no builder-home paths.
Catalog metadata records package checks passed and functional acceptance pending.

The [unsigned Mac Client build](https://github.com/instinctual/plank/actions/runs/38089940376)
passed compilation and component/audio regression tests at root
`747e23822626b980d2ea69b5e18d87d98eece530`. Its Client/common-C/Mac source is
identical to the final Ubuntu candidate; subsequent root changes are documentation
and Ubuntu SDL bootstrap/validation. This was not a signed Mac package build or
Mac hardware qualification. Mac SDL is unchanged.

The first hosted Ubuntu attempt passed compilation but failed the final payload
path gate: SDL's default pkg-config metadata injected its absolute installation
prefix into the Client RUNPATH. The bootstrap now sets `SDL_RPATH=OFF`, and
prepared-source validation plus a regression test reject injected RPATH metadata.
No gate was weakened and no failed package was distributed. The private Ubuntu
SDL is an application-local copy, not a replacement for system SDL; revisit the
patch and bundling when the distribution supplies the upstream retirement fix.

The local build attempt was deliberately stopped before producing a package:
its SDL build had silently omitted PipeWire because the builder lacks the
already-declared development package. Native SDL driver verification is now
mandatory at preparation, cache restore, binary build and packaging. A hosted
Ubuntu builder installs the complete declared dependencies. No package using
that incomplete local SDL may be distributed; local source-level test results
are not audio/runtime qualification. Next: separate real Wayland/input acceptance
when an unoccupied, authorized test session is available. Reconnect, cursor
replacement, tablet hover/tip/buttons and mouse/keyboard remain hardware gates;
the field crash's exact caller remains unknown. No package was installed, and
no merge, release or deployment is authorized. See private notes for access.

## Previous candidates — 1.1.036 Wacom state recovery

These were built on `wacom-state-recovery`, based on parent
`252d770f64d5fa2943b44db24f5f1a20372a3282`.
All four **1.1.036-wacom-state-recovery** candidate packages passed hosted builds
and have been downloaded with independently verified checksums and provenance.
Source and dependency branches are pushed; nothing was merged, released or
installed. No build remains running.
This branch includes the previously requested Client PKG-only packaging cleanup;
the independent native Apple Client automation is not included. Mainline
packages remain **1.1.035**. No merge or release is authorized by this build.

| Component | Exact candidate source |
| --- | --- |
| Parent | `02e7964cdc4b18d6d68028cc1aa450fa91cdd7de` |
| Client | `eb6fda977cc82aba5d9e1c2239a7fbfcc9297096` |
| Linux Host | `65468c3297de82cebfd8f0f0af7dcbd351001cb7` |
| Host libvirtualhid | `b793fa2f5369218c43e09c58d5b96a0cc638bf05` |

Other recursive pins are unchanged from the baseline below.

Packages are in `artifacts/packages/candidates/1.1.036-wacom-state-recovery/`,
under `linux/` and `macos/`. The catalog's `manifest.json`, `SHA256SUMS` and
per-package sidecars retain original filenames and build provenance; all four
local checksum checks passed. The Mac Client output is PKG-only, without a DMG.

| Product / passed hosted run | Bytes | SHA-256 |
| --- | ---: | --- |
| [Linux Host RPM](https://github.com/instinctual/plank/actions/runs/38086303216) | 8723959 | `0a354fe3c86cb5d8632e4822b7b97423dddd6df639f18062d2f90041776e63a6` |
| [Ubuntu Client DEB](https://github.com/instinctual/plank/actions/runs/38086303189) | 15611904 | `57daf45d3342c6ae0def873aa429b8a27a05458664dd25df15dd3a811c79775d` |
| [macOS Host PKG](https://github.com/instinctual/plank/actions/runs/38086303190) | 7004798 | `514cb15d543a137df5b80bf552cfd6bbbdbc969a88dcb22db532d8ce09fab04a` |
| [macOS Client PKG](https://github.com/instinctual/plank/actions/runs/38086303362) | 72880450 | `9f70e39471820e2eb8191c327e1e5a3fee60a7eda3c2c6c10288cd406d94b9ac` |

Both Mac jobs passed Developer ID signing, notarization, stapling and Gatekeeper.
Linux Host passed the RPM payload/log-directory gates, three consecutive
150 Mbps native loss matrices (900 frames each; zero unrecovered source symbols),
and 25 shuffled input-suite repetitions (42 passed, three hardware-dependent
skips each). Its runtime RPM remains `BUILD_TESTS=OFF`; input tests are a
separate build after packaging. Ubuntu passed the actual Wacom worker/lifecycle
tests, version/banner checks, dependency closure and DEB payload gates.

All jobs used dependency caching with fresh application/transport/package builds.
Linux Host and both Mac jobs hit all dependency groups. Ubuntu hit Rust/Cargo;
its FFmpeg exact key missed, was rebuilt with required patch checks and saved.
No cache or validation gates were bypassed. Logs are retained under
`build/tests/wacom-state-recovery/candidate-build-logs/`. Temporary signing
branch permission is limited to `wacom-state-recovery`; remove it when retiring
the branch. No signing secrets were copied locally.

Implementation changes:

- Serialize Host input delivery, repeat callbacks, reset and lease replacement.
  Retire held state before publishing a replacement lease; a late old-session
  reset cannot release the new session's input.
- Release normalized pen contact, pressure, barrel buttons and proximity on
  leave/cancel/disconnect. Preserve accepted state when an output write fails.
- Reuse healthy raw-HID endpoints, but require verified contact cleanup before
  reuse. Recreate an endpoint when cleanup remains unsuccessful or unverifiable.
- Give the Ubuntu raw capture worker sole ownership of device lifecycle; queue
  control requests without holding a shared mutex over device I/O or network
  enqueue. Both raw and normalized paths now observe the reconnect barrier.
- Apply bounded receive backpressure to reliable input bursts instead of
  immediately failing a full 128-record queue. A continuously stalled consumer
  still fails closed after two seconds; cancellation interrupts the wait.

Coordinates, raw report formats and healthy-device identities are unchanged.
No kernel touch-state workaround was added, and no particular intermittent
field failure is claimed reproduced or fixed by hardware evidence yet.

Earlier component validation completed:

- Shared transport: 63 tests passed; 65 with `macos-source-first`. Nine
  certificate/camera/loss-harness tests were ignored in each run, not qualified.
- libvirtualhid: 118 device-independent tests passed. A full builder run also
  attempted 16 device-dependent tests, which failed prerequisites because this
  builder has no `/dev/uinput` or `/dev/uhid`; those remain hardware gates.
- Host recovery harness: 51 tests passed, then all 51 passed in each of 25
  shuffled repetitions. It compiles the actual native input/reset paths and
  requires the retained qualified Boost 1.89.0 source, not distro Boost.
- Ubuntu builder: report-worker, Wayland cursor, raw-adapter and lifecycle tests
  passed normally and with AddressSanitizer/UndefinedBehaviorSanitizer. The
  lifecycle fixture intentionally fails mocked udev discovery without touching
  physical devices. No candidate was installed on either builder.

Local component evidence is under `build/tests/wacom-state-recovery/`. The
Ubuntu component checkout tested parent `b864290a2c658ecc75f6cf94345eeaec59fa78b7`
with Client `da42d3c941716402fb5c2f1d8dedf6b31e343106`; the final Client pin adds
only the candidate changelog. Later parent changes affect Host, transport and
packaging/documentation, not that component test runner. Source bundles
were SHA-256 verified and imported Client-first with recursive fetch disabled.

Next: manually install matching candidates and qualify real hover, tip, pressure, barrel
buttons, Flame Tablet Margins, mouse/keyboard, focus changes, reconnect,
hot-unplug and packet-loss recovery. Include healthy endpoint identity reuse
and unhealthy-endpoint recreation. Component tests are not live tablet,
streaming, WAN-loss or long-soak acceptance. Mac Client live acceptance on both
macOS 15 and macOS 27 remains separate from the SDK27 build. No installed session
was changed.

## Current build — 1.1.035 from main

The operator requested all four installable packages from `main`, without a
release publication or installation. Source is
`f11d109f4b2fbf26c7f2d474bf61200ef05786b3`; Client is
`77cca49d46f5d3b666eb91d143c44ccc1b30da40`. Relative to the consolidated
baseline below, only the shared package version, Client changelog and parent
Client pin changed. No native Apple Client code was imported.

All four jobs passed at that exact source with dependency caching enabled and
fresh application/transport/tests/package builds. Both Mac jobs completed
protected Developer ID signing, notarization, stapling and Gatekeeper checks:

- [Linux Host](https://github.com/instinctual/plank/actions/runs/37719975551)
- [Ubuntu Client](https://github.com/instinctual/plank/actions/runs/37719976025)
- [macOS Host](https://github.com/instinctual/plank/actions/runs/37719975753)
- [macOS Client](https://github.com/instinctual/plank/actions/runs/37719976146)

All four installable packages have been downloaded and checksum/source-verified
into `artifacts/packages/releases/1.1.035/`: Linux Host RPM and Ubuntu Client DEB
under `linux/`, Mac Host and Client PKGs under `macos/`. The original signed
Client DMG wrapper is also retained, not substituted for the installer PKG.
`manifest.json` and `SHA256SUMS` retain exact checksums and recursive source pins.
Every entry records root `f11d109f`, branch `main` and package validation passed.

Local preparation passed 62 CI-policy tests, seven package-collector tests,
privacy checks and whitespace checks. The Host run passed three native loss
matrices (900 frames each, zero unrecovered source symbols) and 25 shuffled
input-suite repetitions (36 passed and three hardware-dependent skips each).
The runtime RPM still uses `BUILD_TESTS=OFF`; test binaries are built separately.
Client component, dependency/runtime, version and packaging gates passed. The
Mac Client dependency caches were populated during this run; no full-bootstrap
or fresh hardware-acceptance claim is implied for the complete product set.

Source/version commits are pushed. No package was installed, no hardware session
was tested, and no GitHub release or tag was published. The `releases/` catalog
name denotes mainline package provenance, not release publication. Mac Client
streaming/input/audio qualification on both supported OS generations remains a
separate gate.

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

The consolidation used package version **1.1.034**; the rebuild above advances
it to **1.1.035**. Existing candidate filenames, checksums and manifests
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
The consolidated main [hosted CI run](https://github.com/instinctual/plank/actions/runs/37716568593)
passed all four unsigned product builds. The signed mainline package rebuild is
tracked above; neither run is a hardware-acceptance or release-publication claim.

No physical camera or product session was used. The optional generated-Mac-camera
fixture was not run locally. Local evidence is under
`build/tests/pr24-camera-transport/`; the clean review worktree is
`build/reviews/pr24-camera-transport`.

## Native Apple Client coordination — agreed and kept separate

The published `apple-native-integration` branches were refreshed from the
consolidated mainline. Parent `b26b84e377522fddacb21617a23c82def66040da`
contains the product tree from `89e992b` plus updated coordination notes;
Client is `942f911fc4221d1306aca0f81c45c71190dbdd41`. These precede only the
1.1.035 version/changelog changes, not the accepted product fixes.
Their worktree is `build/worktrees/apple-native-integration`, with a linked
Client worktree at `apps/client`.

[Client issue #9](https://github.com/instinctual/plank-client/issues/9) records
the contributor's agreement and distinct tested-runtime/dependency checkpoints.
The focused foundation/Vision import at existing paths remains separate from
the shipping build, with public pinned inputs and unsigned reproducible build
instructions. Keep shipping `app/` untouched, preserve authorship, and coordinate
trust, precision, audio/input and CI reconciliation before production acceptance.
Native Mac, directory moves and camera product work remain separate. No native
Client source was imported; 1.1.035 is the existing Qt/SDL Client.

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
