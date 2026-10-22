# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Machine-specific access,
credentials, captures and operational evidence belong in the external private
notes, never in Git.

## Current mainline — Qt wheel scrolling

The operator accepted `1.2.01-qt-wheel-scroll` and authorized merging it into
root and Client `main`, then rebuilding the Ubuntu Client on GitHub Actions.
Continue on canonical `main`; Client is
`c0fdc2deaa7b67a487c3317678db617078948eed`. Version is **1.2.01**, under the
ordinary `plank-client` identity, without a branch suffix. The fresh mainline
package is complete; the accepted candidate was not relabelled. No release
publication or further installation is authorized. Native Apple work remains
separate.

Mainline [run39822530300](https://github.com/instinctual/plank/actions/runs/39822530300)
passed from root `7082a967ccaac8e80c18bdce46cf0404b4c6d6b7`, with the Client pin
above and unchanged Host/Kymux pins below. The verified DEB is
`artifacts/packages/releases/1.2.01/linux/plank-client_1.2.01_amd64.deb`
(17,162,820 bytes), SHA-256
`25f0268b2c277fb80f1d8b1ea492ee6b86a1e805a8ebe51529131e0d75c22657`.
Executable SHA-256 is
`e3c65a5ed98881d9b81e4f94974d41b51ba7f253b524da9cb4c17088cb5bb583`.
Exact recursive sources, Qt6.10.2/toolchain evidence and all reports are in
`artifacts/qualification/main-1.2.01/`. Normal/sanitized input, Wacom and
PipeWire tests, both 55-case GNOME scale suites, launcher and package gates
pass. Software-runner GPU skips remain explicit. The new mainline package has
not been installed; live wheel acceptance applies to the source-equivalent
candidate below. Root privacy and clipboard checks also pass.

The operator next authorized a CI-cache repair after this build. This run
missed all four dependency caches: runner image `20261021.171.10` differs
from the prior images even though dependency recipes did not change. Bootstrap
took about8m25s, followed by about15m of application/tests/package work.
Current fingerprints include the runner image and whole installed-package
inventory, and application objects are not cached. Narrow fingerprints to
actual dependency inputs and add compiler caching in a separate branch;
preserve patch verification, trust boundaries and all qualification gates.
Verify real cache hits in a second unchanged hosted build, not just unit tests.

Read-only diagnosis found that physical wheel deltas reach the Linux Host's
virtual mouse and XInput, while Qt injects an unchanged absolute position before
every wheel event. Linux uses XTEST for that position and uinput for the wheel;
GTK resets smooth-scroll baselines when the source device changes. The macOS
Host does not use that mixed Xorg input path. The operator confirmed that the
candidate fixes the reported scrolling failure on the affected hardware.

The window now sends the mapped position with the wheel event instead of
unconditionally emitting another motion event. The Qt input owner positions
only when needed, remembering successful wire-pixel coordinates and stream
dimensions. Focus/input release, reconnect and tablet-to-mouse handoff invalidate
that position. Real motion and button ordering are unchanged. No Host, transport,
Wacom forwarding or macOS Client source changes are included.

New regression coverage checks stationary and high-resolution wheel sequences,
horizontal scrolling, failed positioning, viewport/stream changes, focus and
reconnect invalidation, raw/normalized tablet handoff and local toolbar isolation.
Client implementation is `c0fdc2deaa7b67a487c3317678db617078948eed`.
All 81 local CI-policy checks, package collection/version tests and available
Qt package checks pass; ten DEB fixtures require the Ubuntu runner and are
explicit local skips. Hosted [run39806775871](https://github.com/instinctual/plank/actions/runs/39806775871)
passed from root `c870ea92a9cbac02d1a4f9fdb398f7a97f3bc4ec`. All 16 input-runtime
cases pass normally and under sanitizers, including the new wheel regression
cases. The 55-case session suite passes in GNOME at 100% and 125%; Wacom,
PipeWire, three launcher cycles, all 14 package fixtures and final DEB gates pass.
Software-only runner GPU handoff skips remain explicit; this is not hardware
or live-session acceptance. Recursive dependency pins match the 1.2.00 baseline
below; only the Client pin changes.

The verified package is
`artifacts/packages/candidates/1.2.01-qt-wheel-scroll/linux/plank-client_1.2.01-qt-wheel-scroll_amd64.deb`
(17,163,484 bytes), SHA-256
`9f382cb61d9a00f2975ec2810d72d10c9ff413c3b6e95e65925d97d7076cd7d2`.
Installed/extracted executable SHA-256 is
`26f64a7547dc36462b33f7d9391219d1650848bc48917b136020cd51c92a6ef0`.
Reports and exact source/toolchain evidence are retained in
`artifacts/qualification/qt-wheel-scroll-1.2.01/`. Dependency caches missed and
were rebuilt and saved; application, sanitizer and package checks were not skipped.

The operator-authorized installation on the designated test Client is complete.
No Client was running, no stream was interrupted, and no Host was modified.
Package version, binary checksum and offscreen runtime version match; the
administrator configuration checksum is unchanged. The older optional Qt test
package was left alone. Launch the ordinary Client for testing.

The operator confirms scrolling works after this exact Client update. This
accepts the reported wheel failure, not a separately measured soak or complete
hardware regression matrix. Focus/tablet/reconnect transitions and macOS-Host
scrolling remain useful follow-up checks. Private capture/deployment evidence
remains outside Git; all SSH/capture tasks are closed and temporary package
transfer staging is removed. Both accepted feature branches are merged into
main. No release has been published.

## Main baseline — Ubuntu Qt Client, Wacom recovery and CUDA

The operator authorized merging `wacom-usb-recovery` (including
`ubuntu-qt-session`) and `cuda-13-2` into main. Continue in the canonical
checkout on `main`, with Client and Linux Host at its exact submodule pins.
Native Apple Client development remains separate in
`build/worktrees/native-builds`; do not merge it as part of workspace cleanup.

The operator authorized retiring redundant local checkouts. PKG-only edits
already exist in main, the SDL upstream-status clarification is retained in
the dependency patch inventory, and the old Kymux review regression is already
committed in the native transport dependency. Native-build notes are preserved
on their own branch. Recovery copies of loose edits stay outside Git. Packages,
dependency caches and the shipping Kymux pin are unchanged. Historical paths in
candidate records below identify past evidence, not active resume locations.

Cleanup is complete: the only root worktrees are the canonical `main` checkout
and `build/worktrees/native-builds`. Client and Linux Host main checkouts now
live under the canonical `apps/` paths, not retired recovery folders. Merged
root/Client/Host feature branches were deleted locally and remotely; the native
Apple coordination branches remain preserved. Local dependency URLs no longer
refer to removed worktrees. This changes no product source or package pins.

The additional build-folder cleanup removed 44 obsolete download, test and
review directories, reducing `build/` from about 12 GiB to 29 MiB. Only the
active native-builds source worktree remains there before new build staging.
Prepared dependencies, package catalogs and qualification reports are untouched;
old loose review edits and source metadata have a checksum-verified private
recovery archive outside Git. Canonical and initialized dependency Git
connectivity checks and documentation-link checks pass after removal.

Ubuntu's Qt frontend is to replace the SDL session frontend under the ordinary
`plank-client` package, launcher, settings, administrator configuration and log
identity. It is no longer a separately installable product. macOS retains its
existing Client implementation. Version advances to **1.2.00** for this
combined integration; previous candidate artifacts are not relabelled.

Client main is `67a94f94d711e81f470b985001ca3eae37f5abad`; the root ancestry
merge is `88778d4`. The promotion commit containing this handoff pins that
Client, sets 1.2.00 and consolidates Ubuntu CI into the ordinary `linux-client`
job. Qt/PipeWire, sanitizer, compositor and launcher checks remain mandatory;
one full Client build replaces the previous two-build experimental job.
The package-upgrade fixture preserves administrator configuration and user
state. Do not copy the retired test app's profile over existing normal PLANK
settings or trust. Remove that optional old test package manually if installed.

Local validation passes 81 CI-policy tests, package collection/version checks,
runtime/identity source checks, reconnect/MTU and Mac frontend/permission wiring
checks, shell syntax, documentation links and new-content privacy checks.
Ten DEB fixtures require the hosted Ubuntu toolchain; one Mach-O test requires
macOS. They are local skips, not acceptance passes. The Mac fullscreen source
guard was updated for the external-renderer initialization signature and still
requires the unchanged null-presenter SDL initialization on macOS.

Root main promotion `3bff6b4fcde9b5b1f665d1b3c8e3c2950c5e57dd` and Client main
are pushed. Both requested Client branches and all three requested root branches
are ancestors of main. [Hosted run39685022784](https://github.com/instinctual/plank/actions/runs/39685022784)
passed Linux Host, Ubuntu Qt Client and unsigned macOS Host. The macOS Client
stopped at an outdated uninstaller source assertion: it expected an inline
application-name literal instead of the shared, unchanged identity constant.
The check now verifies that constant, and the executable Qt path fixture uses
the actual application constant rather than duplicating it. Local uninstall,
install, fullscreen, quit, Metal-overlay, keyboard/permission checks and all
81 CI-policy tests pass. This is a test correction, not a runtime change.

The operator requested a full rebuild from cleaned-up main: fresh application,
transport and package outputs for all four products on GitHub Actions, reusing
only verified dependency caches. macOS packages must be signed/notarized.
No installation or release publication is authorized by this rebuild request.
Rebuild source is `dfc2984662e3f144e630759fee0dee142edea5e8`, with the same
Client/Host/Kymux pins as the promotion. Explicit hosted runs:

- Linux Host: [39691129894](https://github.com/instinctual/plank/actions/runs/39691129894).
- Ubuntu Client: [39691129968](https://github.com/instinctual/plank/actions/runs/39691129968).
- Signed macOS Host: [39691129867](https://github.com/instinctual/plank/actions/runs/39691129867).
- Signed macOS Client: [39691129794](https://github.com/instinctual/plank/actions/runs/39691129794).

**All four 1.2.00 builds passed.** Their original packages are downloaded and
checksum-verified in `artifacts/packages/releases/1.2.00/`, with a combined
manifest and SHA256SUMS. This directory denotes mainline artifacts, not a
published GitHub release. Both macOS installers passed signing, notarization,
stapling and Gatekeeper; Client remains macOS15+, Host macOS27+. Detailed
hosted logs and the Qt test reports are retained under
`artifacts/qualification/main-1.2.00/`. Ubuntu's synthetic/component, sanitizer,
55-case compositor suites at 100%/125%, launcher, audio and package gates pass;
real GPU handoff is explicitly skipped on the software-only runner. The Mac
Client's updated uninstaller check and executable Qt path test both pass.

Linux Host passes its pinned CUDA 13.2 Update2/NVCC13.2.86, patched dependency,
transport, RPM and repeated input-lifecycle gates. The production RPM still
uses BUILD_TESTS=OFF; the separate test build and mocked UHID fixture are not
packaged. Real-kernel UHID cases remain explicit skips on the hosted builder.
The RPM owns `/var/log/plank` as root:root0700, independently checked after
download. Linux dependency caches were restored and verified; the macOS jobs
had cache misses and successfully bootstrapped their pinned dependencies.

Next: manual installation and hardware/session qualification when requested.
No release was published and no package was installed by this rebuild. The
temporary download staging directory is removed after verified collection.
The retained candidate sections below are historical evidence, not instructions
to resume an old branch or proof of new mainline hardware acceptance.

<details>
<summary>Exact recursive source provenance for the 1.2.00 rebuild</summary>

Root: `dfc2984662e3f144e630759fee0dee142edea5e8`. Paths below are relative to
the root.
Initialization records include inherited platform/documentation submodules;
their presence is not a claim that they are Linux runtime dependencies.

```text
apps/client 67a94f94d711e81f470b985001ca3eae37f5abad
apps/client/moonlight-common-c/moonlight-common-c 437be9a0a4d164efdf9ed20dc6dd5a2b7b9edc90
apps/client/qmdnsengine/qmdnsengine 920c097ffa742e2968290f15d4dde6693aec02e5
third_party/kyber-kymux 3f7a9d8618978287186e5d6ce0eaa067743cb06c
apps/host/linux 65dc0f1be60fe78d0457364f83813118c70bc8a8
apps/host/linux/packaging/linux/flatpak/deps/flatpak-builder-tools ac5a296ac6111aa2319daf532f609a067b88d8a9
apps/host/linux/third-party/Simple-Web-Server 546895a93a29062bb178367b46c7afb72da9881e
apps/host/linux/third-party/TPCircularBuffer cc520397504bb72bc6df79ff03eb72988a6dc50d
apps/host/linux/third-party/ViGEmClient 8d71f6740ffff4671cdadbca255ce528e3cd3fef
apps/host/linux/third-party/doxyconfig e552f7c9f00cd0cf24764a37d0905935b3d2c188
apps/host/linux/third-party/doxyconfig/doxygen-awesome-css d52eafe3e9303399fda15661f3d7bb8fe3d7eabc
apps/host/linux/third-party/glad 73db193f853e2ee079bf3ca8a64aa2eaf6459043
apps/host/linux/third-party/googletest 52eb8108c5bdec04579160ae17225d66034bd723
apps/host/linux/third-party/libdisplaydevice 6e9722f89103320c948dc1199066c9e17a69e88a
apps/host/linux/third-party/libdisplaydevice/third-party/doxyconfig e552f7c9f00cd0cf24764a37d0905935b3d2c188
apps/host/linux/third-party/libdisplaydevice/third-party/doxyconfig/doxygen-awesome-css d52eafe3e9303399fda15661f3d7bb8fe3d7eabc
apps/host/linux/third-party/libdisplaydevice/third-party/lizardbyte-common 06cd442b808f02f1674f3192a84d25b9a503c482
apps/host/linux/third-party/libdisplaydevice/third-party/lizardbyte-common/third-party/doxyconfig e552f7c9f00cd0cf24764a37d0905935b3d2c188
apps/host/linux/third-party/libdisplaydevice/third-party/lizardbyte-common/third-party/doxyconfig/doxygen-awesome-css d52eafe3e9303399fda15661f3d7bb8fe3d7eabc
apps/host/linux/third-party/libdisplaydevice/third-party/lizardbyte-common/third-party/googletest 52eb8108c5bdec04579160ae17225d66034bd723
apps/host/linux/third-party/libvirtualhid b793fa2f5369218c43e09c58d5b96a0cc638bf05
apps/host/linux/third-party/libvirtualhid/third-party/doxyconfig 419127bad87f49b2d45fa957ea7302abbb49c01f
apps/host/linux/third-party/libvirtualhid/third-party/doxyconfig/doxygen-awesome-css 46483f1e5a70ffb9ecd3b82d0a1cd1b24edf13da
apps/host/linux/third-party/libvirtualhid/third-party/lizardbyte-common f9d91e1d29b7473f58e43acde4579da4e56c4abe
apps/host/linux/third-party/libvirtualhid/third-party/lizardbyte-common/third-party/doxyconfig b87f7e4e1dcd8a31c9a550cd7702b7420d89efac
apps/host/linux/third-party/libvirtualhid/third-party/lizardbyte-common/third-party/doxyconfig/doxygen-awesome-css 24c4f966e375ed92e9805e075177d34a9849a43e
apps/host/linux/third-party/libvirtualhid/third-party/lizardbyte-common/third-party/googletest f8d7d77c06936315286eb55f8de22cd23c188571
apps/host/linux/third-party/lizardbyte-common f9d91e1d29b7473f58e43acde4579da4e56c4abe
apps/host/linux/third-party/lizardbyte-common/third-party/doxyconfig b87f7e4e1dcd8a31c9a550cd7702b7420d89efac
apps/host/linux/third-party/lizardbyte-common/third-party/doxyconfig/doxygen-awesome-css 24c4f966e375ed92e9805e075177d34a9849a43e
apps/host/linux/third-party/lizardbyte-common/third-party/googletest f8d7d77c06936315286eb55f8de22cd23c188571
apps/host/linux/third-party/moonlight-common-c 3a97a58f215323753cfd1180af760ec7e3253538
apps/host/linux/third-party/nvapi cd6918f60b3c9a0476fdfe7e89bb32330602049d
apps/host/linux/third-party/plasma-wayland-protocols 382dfabda886d3f2f5c067b22e5a22376685ba78
apps/host/linux/third-party/wayland-protocols 819004adb3ab7e46f3fa3caef05b96e20434b244
apps/host/linux/third-party/wlr-protocols bf4fc79abc359eea5a0edec0ac6d4a2b2955f82a
apps/host/linux/third-party/build-deps c29c4822cb96f5bfeb8640e72601c5cf4e3c3137
apps/host/linux/third-party/build-deps/third-party/FFmpeg/AMF eadd00804d5f7e5cd8c85d540073198312870776
apps/host/linux/third-party/build-deps/third-party/FFmpeg/FFmpeg 38b88335f99e76ed89ff3c93f877fdefce736c13
apps/host/linux/third-party/build-deps/third-party/FFmpeg/SVT-AV1 9292ec8e32bce26f781f277ec8739b53426c4300
apps/host/linux/third-party/build-deps/third-party/FFmpeg/Vulkan-Headers ee2ec5fd83dafce291024683b50dc89219333076
apps/host/linux/third-party/build-deps/third-party/FFmpeg/Vulkan-Loader b8b96a2862bff1eed468e602d43f706beae89cf1
apps/host/linux/third-party/build-deps/third-party/FFmpeg/nv-codec-headers e844e5b26f46bb77479f063029595293aa8f812d
apps/host/linux/third-party/build-deps/third-party/FFmpeg/x264 0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee
apps/host/linux/third-party/build-deps/third-party/FFmpeg/x265_git 1d117bed4747758b51bd2c124d738527e30392cb
```

</details>

## Retained candidate — Wacom USB recovery on the Qt baseline

Branch `wacom-usb-recovery` starts from the complete .052 Qt work:
parent `a08666b8b8fd820a92d3296ac88a5f7ebae9e3be`, Client
`ab38aa1fe9264d7440f3f4bad515f98c2c1a4c44`. No Host, macOS or wire-protocol
change was made in this candidate.

The candidate was built on `wacom-usb-recovery`; current development uses main.
Root and Client implementation commits are pushed. The post-build documentation
checkpoint is `44fadb7ac49a6ab7999eb69c3c7ed3727460291c`; the installer remains
the exact `bc204f6` source recorded below, not a relabelled notes build.
No build, sampler or debugger remains active for this task. The redundant
all-products run39510884633 is cancelled; the explicit Qt candidate run passed.
The operator now reports a successful live USB-recovery test: restart Flame
once, unplug the tablet for a few seconds, then reconnect it. The tablet worked
in the still-running Flame after a few seconds, without another restart.
Confirmation of the installed Client version is pending; do not yet attribute
this result to the exact .053 package or claim unchanged device IDs were measured.

Read-only live inspection found a client-side USB interface re-enumeration
followed by Host virtual-tablet destruction/recreation while the application
was running. A coordinated pen-only sample subsequently confirmed tip presses
and full pressure reaching the Host virtual device; the application no longer
selected its current extended-input device IDs. This supports the retention
fix, not a claim that all similar application failures share this cause.
No live application, device, service, configuration or package was changed.
The bounded sampler is stopped; operational evidence remains outside Git.

The shared Linux raw-HID adapter now uses the existing SUSPEND path for USB
I/O loss, preserving Host endpoints and releasing held contacts. Wire interface
ordering uses USB interface numbers, not hidraw names. Descriptor-driven
completeness checks reject a temporarily partial tablet during driver rebind.
Discovery also requires a pen-capable evdev node, because the kernel can expose
hidraw before registering pen input; a surviving touch node is not readiness.
Genuinely different device metadata/descriptors still reach the Host's existing
replacement policy. First-generation normalized fallback is unchanged.

New link-wrapped production-adapter tests cover renumbering, partial/malformed
interface inventory, missing pen evdev readiness, polling/read failures,
transient I/O interruptions, stale generation controls, reconnect barriers and
handle cleanup. Normal and ASan/UBSan/leak runs pass. The unchanged Host's
retained lifecycle fixture also passes 25 shuffled repetitions normally and
under sanitizers (eight cases per repetition), using its retained component
build, not a fresh Host package or real-kernel qualification.

**1.1.053-wacom-usb-recovery is ready for manual testing.** Hosted run39508923505
passes both full Client builds, 55 window/UI cases at 100% and 125%, offscreen
and sanitizer coverage, two-monitor selection, synthetic precision gates,
isolated PipeWire tests, three launcher/shutdown cycles, 14 package fixtures
and finished-DEB checks. Live GPU handoff remains explicitly skipped on the
software-only runner. These hosted checks are not hardware acceptance; the
operator's separate live USB result and its provenance limit are recorded above.

Exact candidate provenance:

- Parent `bc204f6de2509d2557394084e209750bb095f7e3`.
- Client `3b92fb419a1ea9c83f974a681efe57c0dc68e538`.
- Client common-C `437be9a0a4d164efdf9ed20dc6dd5a2b7b9edc90`; qmdnsengine `920c097ffa742e2968290f15d4dde6693aec02e5`.
- Unchanged Linux Host `65dc0f1be60fe78d0457364f83813118c70bc8a8`; kymux `3f7a9d8618978287186e5d6ce0eaa067743cb06c`.
- [Successful hosted run39508923505](https://github.com/instinctual/plank/actions/runs/39508923505).
- Package: `artifacts/packages/candidates/1.1.053-wacom-usb-recovery/linux/plank-client-qt_1.1.053-wacom-usb-recovery_amd64.deb`.
- Size: 17,165,256 bytes; SHA-256 `acc8c9eaa2609fc3ece94b1b18567ca0d1a10c246016af69f0ae741cd1ea363f`.
- Packaged executable SHA-256 `b4e3b31b938d8571da6ba13c1c8f005709bf7031a8af56c5497913add1fd0097`.
- Reports: `artifacts/qualification/wacom-usb-recovery-1.1.053/final/`.

The downloaded package checksum, metadata, source provenance and executable
hash are independently verified. Earlier run evidence is retained in attempt-1
and attempt-2: the first caught fortified libc entry points bypassing fixture
I/O injection; the second passed those tests and caught a stale packaging
function-name check. Both are corrected with coverage, not suppressed. Neither
failed run produced an installer. Privacy and clipboard checks also pass.

Next: confirm the installed version for that live result. Continue from the
working Flame session rather than restarting it again: qualify normal-tip
clicks, pressure, eraser and Tablet Margins, repeated same-port USB recovery
and network recovery. Host input IDs must remain unchanged for the same
metadata/descriptors; the operator's successful recovery alone does not measure
that invariant. See `protocol/wacom-hid.md` for the acceptance sequence.
No Host update is required. The shared adapter also compiles for
the ordinary Linux Client, but only the separate Qt package was produced.
No remote installation, live application restart, merge or release was performed.

## Previous Qt baseline

### .052 ready for manual testing — windowed size and fullscreen restore

The operator accepts .051's spacing and requests a useful normal window,
retention of manual resizing across fullscreen toggles and no small-window
preview before initial fullscreen. The Qt shell prepares an aspect-matched
normal size within 80% of the available logical width/height; GNOME controls
placement. Manual resizing is free-form with proportional video/letterboxing,
not a hard window-shape constraint or a new Host resolution request.

Hidden native creation retains the selected output. Initial raster painting
and child showing wait for that output's actual fullscreen geometry: GNOME
can expose a normal configure before its separate fullscreen configure.
Normal content size is saved before entering fullscreen and restored once
after the native normal-state event recreates decorations. Qt Wayland's own
restore could otherwise subtract the border/title-bar dimensions each time.
No fixed border offsets, timing delay, resize loop or private Wayland API.
Explicit hide/minimize cleanup and .050's covered-parent policy remain.

Hosted run39490258526 passes 55 window/UI cases at both 100% and 125%, separate
two-monitor selection, offscreen and ASan/UBSan/leak checks, isolated PipeWire
tests, all synthetic precision/import gates, both complete Client builds,
three launcher/shutdown cycles, 14 package fixtures and finished-DEB checks.
Real GPU handoff remains explicitly skipped on software-only drivers; this is
not fresh Intel decode, live stream, input or acoustic acceptance. The windowed
snapshot has no live frame and is not a visual-session qualification.

Exact **1.1.052-ubuntu-qt-session** candidate:

- Parent `aaa1482aa58c9650653750e12595c91c79afd97e`.
- Client `ab38aa1fe9264d7440f3f4bad515f98c2c1a4c44`.
- Client common-C `437be9a0a4d164efdf9ed20dc6dd5a2b7b9edc90`; qmdnsengine `920c097ffa742e2968290f15d4dde6693aec02e5`.
- Unchanged Linux Host `65dc0f1be60fe78d0457364f83813118c70bc8a8`; kymux `3f7a9d8618978287186e5d6ce0eaa067743cb06c`.
- [Successful hosted run39490258526](https://github.com/instinctual/plank/actions/runs/39490258526).
- Package: `artifacts/packages/candidates/1.1.052-ubuntu-qt-session/linux/plank-client-qt_1.1.052-ubuntu-qt-session_amd64.deb`.
- Size: 17,159,020 bytes; SHA-256 `61218d071c0f39d82fbd031aac13c3adf366ed6c9422670528aa64bb2496f697`.
- Packaged executable SHA-256 `2488062947b2adc4d7f6d80e7cb08f0982d2e79ca6edaa4864fbbd09b2292711`.
- Reports: `artifacts/qualification/ubuntu-qt-session-1.1.052/final/`.

Package checksum, metadata, provenance and executable hash are independently
verified after download. Earlier failed-run evidence remains in `attempt-1/`
through `attempt-6/`; no failing run produced an installer. Those runs caught
initial configure ordering, normal-size restoration and minimize behavior, plus
fixtures that needed to await real glyph/input-event delivery. The final tests
retain those assertions. Dependency caches were used; no checks were relaxed.

Next: manually test initial fullscreen, first windowed exit, arbitrary resize,
repeated toggles, toolbar and input alignment. Position is GNOME-controlled;
video must remain proportional and the Host mode unchanged. This remains the
separately installable Qt Client; ordinary Client, both Hosts and native PipeWire
behavior are unchanged. No remote installation, merge or release was performed.

### .051 accepted — compact toolbar

The operator approved reducing gaps between microphone, camera, fullscreen,
minimize and disconnect from 8 to 4 logical pixels. The controls retain their
32x32 click targets and 24x24 artwork. A nested controls row leaves all other
column spacing, the slider, toolbar height, reveal and input handling unchanged.
The RTT reserve is narrowed to three-digit whole milliseconds, including a
fixed `>999 ms` over-range indication. Unknown/unavailable RTT remains a dash.
Changing telemetry must not move the slider or control hit regions.

Hosted run39475946222 passes both complete Client builds, 43 window/input
cases on GNOME at 100%/125%, offscreen and ASan/UBSan/leak coverage, isolated
PipeWire tests, three full-launcher cycles, 14 package fixtures and finished-DEB
checks. The Wayland-only case is skipped offscreen and run on the compositor;
the PipeWire daemon cases run separately, not silently skipped. Software-only
GPU qualification does not replace real hardware or audible A/V acceptance.
Final compositor screenshots visually confirm unclipped icons/readouts.
New coverage checks RTT boundaries, stable hit regions and all four
microphone/camera visibility combinations. The first run failed only a fixture:
QVariant compares UINT_MAX and signed -1 equal; the distinct negative case now
uses -1.0. No assertion or product validation was weakened.

Exact **1.1.051-ubuntu-qt-session** package:

- Parent `51f9afd14da244d38602d1ff230e3f01332127ec`.
- Client `396ef6dc0678cfd8488c197c0a34d3050013e312`.
- Client common-C `437be9a0a4d164efdf9ed20dc6dd5a2b7b9edc90`; qmdnsengine `920c097ffa742e2968290f15d4dde6693aec02e5`.
- Unchanged Linux Host `65dc0f1be60fe78d0457364f83813118c70bc8a8`; kymux `3f7a9d8618978287186e5d6ce0eaa067743cb06c`.
- [Successful hosted run39475946222](https://github.com/instinctual/plank/actions/runs/39475946222).
- Package: `artifacts/packages/candidates/1.1.051-ubuntu-qt-session/linux/plank-client-qt_1.1.051-ubuntu-qt-session_amd64.deb`.
- Size: 17,154,440 bytes; SHA-256 `2bfd6f48c358c67b6f327ad4b5fa73d50ab0804f80c4ebe87268040a5b658533`.
- Packaged executable SHA-256 `766e9b0fc4aac11cbecdbbec1c4c89c4347722ba8cfb7f6bc88938f92c66ffda`.
- Reports: `artifacts/qualification/ubuntu-qt-session-1.1.051/final/`; first-run fixture evidence in `attempt-1/`.

Downloaded package/provenance/checksums are verified. Read-only archive
inspection independently confirms no payload-file overlap with ordinary1.1.039.
Both Hosts, ordinary Client and native PipeWire behavior are unchanged.
The operator accepts the compact toolbar in a live session. The separate
real-output audio/A/V-sync soak remains pending. No remote
installation, merge or release was performed.

### .050 ready for manual testing — covered-parent presentation repair

The .049 failure is reproduced on the authorized Intel Client without a Host
connection, including with no audio stream. Exact-format decoding succeeds,
but the opaque native video child completely covers its raster parent.
Wayland continues delivering child frame callbacks while omitting callbacks
for the covered parent. Qt 6.10.2's timeout heuristic marks that parent hidden
and propagates the state to the child, stopping rendering and the bounded
decoder qualification. This is not an HEVC-support, PipeWire or Host failure.

The standalone hosted probe reproduces the failure on repeated native-child
starts, with and without silent PipeWire. Removing the parent passes 12 starts;
retaining it and setting process-local `QT_WAYLAND_FRAME_CALLBACK_TIMEOUT=0`
also passes all 12, including audio setup/teardown. Actual Wayland tracing
confirms the parent/child callback distinction. Raw traces and machine state
remain in private notes, not Git. No installed package or Host was changed.

Candidate .050 sets that policy before creating Qt surfaces, only in the
experimental Qt Client and its probes. Explicit diagnostic overrides remain.
It disables the timeout heuristic, not frame callbacks or swap pacing; normal
hide/minimize handling and the two-second exact-format gate remain. The
native-child design still avoids Qt's RGB8 decoration framebuffer. New tests
exercise sustained rendering, fullscreen/windowed changes and hide/restore.
The first two hosted runs caught a stale child exposed flag after hiding its
parent, then an incorrect assumption that programmatic minimize delivers a
WindowStateChange event. The final shell uses QWindow's public visibilityChanged
signal for show/hide/minimize/restore, with the child as connection-lifetime
context. Both offscreen visibility and real-compositor swap assertions remain.
Neither failed run produced an installer; their evidence is retained.

Hosted run39385477049 passes both complete Client builds, all component tests,
ASan/UBSan/leak checks, 41 compositor cases at 100%/125%, ten-bit precision and
RGB8-rejection gates, three full-launcher cycles, 14 package fixtures and the
finished-DEB checks. The Wayland-only swap test is explicitly skipped offscreen
and under offscreen sanitizers, not counted as passed there. Real isolated
PipeWire daemon tests pass separately from the deterministic audio tests.
Downloaded archive/provenance/checksums are verified. Read-only archive
inspection independently confirms no payload-file overlap with ordinary1.1.039.

The final hosted standalone probe also passes 12 fullscreen HEVC VA-API starts
with silent PipeWire and 12 windowed starts without audio on the authorized
Intel Client, with no timeout environment override. Fullscreen/windowed
roundtrips pass all nine shader/import/conceal cases, RGB8 rejection and 120
real Vulkan/GL ownership handoffs. Earlier diagnostic A/B also verifies all1024
RGB/gray framebuffer levels. These are hardware component checks, not a live
Host connection or audible A/V soak. The temporary probe is removed and SSH
closed; no package or system setting was installed/changed.

Exact **1.1.050-ubuntu-qt-session** package:

- Parent `eb6d33690df388666b852455f8a51152f63269c5`.
- Client `730acdd5d6808f7efe9fedf3b7b74db28b40386a`.
- Client common-C `437be9a0a4d164efdf9ed20dc6dd5a2b7b9edc90`; qmdnsengine `920c097ffa742e2968290f15d4dde6693aec02e5`.
- Unchanged Linux Host `65dc0f1be60fe78d0457364f83813118c70bc8a8`; kymux `3f7a9d8618978287186e5d6ce0eaa067743cb06c`.
- [Successful hosted run39385477049](https://github.com/instinctual/plank/actions/runs/39385477049).
- Package: `artifacts/packages/candidates/1.1.050-ubuntu-qt-session/linux/plank-client-qt_1.1.050-ubuntu-qt-session_amd64.deb`.
- Size: 17,154,160 bytes; SHA-256 `9c788ad5c8031aa5bbbed9b5ea462c90e9c8f987470360e04e3a4d09aff64ac3`.
- Packaged executable SHA-256 `9ef85983f78741f91de8689088350c3956d2fbc6f670b8b0f7d4d9feb140feff`.
- Reports: `artifacts/qualification/ubuntu-qt-session-1.1.050/final/`; earlier failed gates in `attempt-1/` and `attempt-2/`.
- Final standalone probe SHA-256 `94270f0a54293e9a80f1f74f2f10ebe563d17271cbcd32e84b4444825eec9cf0`.

The operator has installed .050; the subsequent authorized toolbar screenshot
shows a live session. The .051 toolbar candidate above supersedes the installer
handoff, not the remaining real-output crackle and long A/V-sync gates. Native
PipeWire is retained; ordinary Client and both Hosts are unchanged. No merge or
release.

### Candidate ready — direct PipeWire playback in Qt only

The operator authorized direct PipeWire integration after read-only inspection
confirmed actual short output reads in Qt .048: 11 shortages over 45 seconds,
4289 missing stereo output frames, 8999 audio transport callbacks and zero
concealed samples. This identifies output starvation; it does not prove that
Host batching/arrival jitter is irrelevant. Machine access and raw evidence
remain outside Git. The trace and SSH session are closed.

Candidate .049 replaces Qt's SDL audio stream with native PipeWire playback,
measured graph/device timing, a bounded SPSC PCM queue and producer-side smooth
FFmpeg compensation. A rolling post-pull headroom guard prevents repeated phase
catch-up from draining the reserve. Startup/recovery primes one graph quantum
plus 12ms; this is a bounded continuity/latency tradeoff, not free buffering.
No ordinary Client, Host, microphone, transport or video policy change. See
the Qt plan for design and tests. Candidate **1.1.049-ubuntu-qt-session** is
downloaded and package-verified; hardware/audio-soak acceptance remains open.
Successful run 39375933711 passed all 19 audio component cases, including nine actual-FFmpeg
drift/batching combinations and large-quantum startup. Real isolated PipeWire
playback, repeated destruction and unavailable-server handling passed normally
and with ASan/UBSan at 1024/4096 frames. Reported playback underruns were zero.
All existing component/compositor gates, both complete Client builds, three
full-launcher cycles, 14 package fixtures and the finished-DEB gates passed.
The earlier run's backend-object check used the wrong qmake path; the corrected
gate checks `app/release/pipewire.o` and absence of `app/release/sdlaud.o`, with
explicit error messages. This is a regression-build gate, not proof of live
Intel hardware decoding or real-output acoustic behavior.

Early leak-check failures came from libdbus globals being unloaded with the
standalone test's PipeWire modules. The test now retains the library and calls
its documented `dbus_shutdown()` only after all renderers/threads are gone.
The sanitized rerun passes with leak detection enabled and no suppressions.
Never move that global shutdown into the real renderer; other GUI components
use D-Bus. Stream destruction itself stays synchronized with the live PipeWire
loop and balances initialization. Producer high-water follows graph quantum
plus reserve when larger than 50ms, so large devices can actually prime.
Before/after evidence is retained under the .049 qualification directory.

Exact package sources and retained evidence:

- Parent `239044961b01576ebfbc8358835b0bf128ee33ba`.
- Client `0e177030034c4e02cbcfa64c0e2f7d3be7153ea1`.
- Client common-C `437be9a0a4d164efdf9ed20dc6dd5a2b7b9edc90`; qmdnsengine `920c097ffa742e2968290f15d4dde6693aec02e5`.
- Unchanged Linux Host `65dc0f1be60fe78d0457364f83813118c70bc8a8`; kymux `3f7a9d8618978287186e5d6ce0eaa067743cb06c`.
- [Successful hosted run 39375933711](https://github.com/instinctual/plank/actions/runs/39375933711).
- Package: `artifacts/packages/candidates/1.1.049-ubuntu-qt-session/linux/plank-client-qt_1.1.049-ubuntu-qt-session_amd64.deb`.
- SHA-256: `996fc09f29ea828d3d0d9474334d64bab1b5f92090b4ef8a06c5ad6a76b9f094`.
- Packaged executable SHA-256: `fe9e806920deafc9e480312472aeb44a7a1b5bf80d65465645fbf1b0d1fe9129`.
- Reports: `artifacts/qualification/ubuntu-qt-session-1.1.049/final/`; earlier lifecycle/gate evidence is alongside it.

The downloaded archive and binary hashes match the builder. Read-only `ar`/`tar`
inspection on the Rocky coordinator independently confirms no payload-file
overlap with the retained ordinary 1.1.039 DEB; Ubuntu's full dpkg namespace and
disposable-install/purge tests ran in CI. Do not install DEBs on the builder.
The operator installed .049 but encountered the startup issue described above.
After .050 fixes startup, verify brief crackles, A/V sync over a long real-output soak,
OS-selected output routing and interruption recovery. Log `PLANK PipeWire
playback` provides actual shortages, missing frames, headroom and correction.
No merge, release, remote installation or real-output listening acceptance.

### Accepted follow-up — hide startup decoder test images

The operator accepts .047's icons, then reports a momentary light-blue screen
during connection. Source inspection finds that decoder qualification fills
the visible output with its test frame; both window backgrounds already use
black. Candidate **1.1.048-ubuntu-qt-session** explicitly marks qualification
frames and clears their pixels to black after the existing exact-format GPU
draw, before Qt draws controls and swaps. No hidden window, extra framebuffer,
timer, readback or per-live-frame clear is added. The check still validates
actual import, shader, target precision and swap feedback. Live frames are not
concealed. The immutable marker stays with retained frames, including any
older surface still being sampled during a decoder transition.

The connecting message now waits for actual live-frame swap feedback, not
test-frame presentation or mere live submission. Each decoder generation has
fresh readiness, so old feedback cannot end a new startup notice. Automatic
recovery, input, transport, codecs and both Hosts are otherwise unchanged.
New controlled-feedback tests exercise qualification, live readiness,
cancellation and generation replacement; the compositor's exact-pixel fixture
checks black concealment and immediate unchanged live rendering for all nine
existing format/crop/filter cases. Concealment must still reject an RGB8
substitution for a ten-bit target. Hosted run 39358327903 passed on its first
attempt. All nine presenter cases passed normally and with ASan/UBSan; all
40 window/input cases passed offscreen, with sanitizers and on GNOME/Wayland
at 100%/125%. The compositor passed 72 conceal/reveal pixel scenarios across
both scales and window modes, retaining the ten-bit target rejection gates.
Both complete Client builds, ordinary Client preflight, three Qt launcher
cycles, 14 package fixtures and finished-package gates passed. The downloaded
DEB has no file overlap with the retained ordinary 1.1.039 Client. Hosted Mesa's
external-memory/semaphore handoff is still an explicit skip, not Intel hardware
acceptance. Dependency restore/verification/bootstrap took 21 seconds; the
combined component and complete-build step took 14m29 of the 17-minute job.

Exact **1.1.048-ubuntu-qt-session** package sources and evidence:

- Parent `e3ef63836b470ce248c90a3e038bfdb73b7ba668`.
- Client `68cabc025b8f0d4a0a741ab0d0c9a46e5180b299`.
- Successful [GitHub-hosted run 39358327903](https://github.com/instinctual/plank/actions/runs/39358327903).
- Package: `artifacts/packages/candidates/1.1.048-ubuntu-qt-session/linux/plank-client-qt_1.1.048-ubuntu-qt-session_amd64.deb`.
- SHA-256: `acd7fe7ad61a82133a43e8bf70d59b43a6895087c536a5bce3f02a229b341dc4`.
- Packaged executable SHA-256: `6563b41c087926c15db0c73a86726710c8e7f4ccebb3b2764193ef424c4ef205`.
- Retained reports: `artifacts/qualification/ubuntu-qt-session-1.1.048/`.

The operator tested .048, reports the startup transition is better, and
authorized committing/pushing this checkpoint. This accepts the startup
improvement, not the remaining full interruption, profile, audio and
camera/microphone qualification gates. Both source commits are pushed on
`ubuntu-qt-session`; no remote installation, Host update, merge or release
was performed.

### Retained follow-up — borderless, consistently sized toolbar icons

The operator reports that .046's icons, including minimize/close, look squeezed
inside small boxes. Read-only inspection found that the real app's Material
style supplies edge-specific padding/insets despite the custom button's generic
`padding: 0`. The earlier isolated UI tests used the default style, so their
successful SVG renders did not exercise this production layout. This is not
evidence of another video-import or cursor defect.

Candidate **1.1.047-ubuntu-qt-session** uses Qt's unstyled Button template for
the existing toolbar controls: 32-pixel invisible click targets, centered
24-pixel SVGs, no idle box, and subtle hover/press feedback. Minimize and close
now use the same vector dimensions, color and line weight as the other icons.
The microphone/camera also use centered vector artwork; supported/active states
still come from existing telemetry. Toolbar height remains 39 logical pixels.
No window, input, video, audio, transport, Host or ordinary Client policy changes.

The isolated probe and Client tests now use the production Material Dark/Dense
style. Added regressions require actual 24-pixel content geometry, zero style
insets, wide rendered glyphs, transparent idle backgrounds, hover/press feedback
and all six controls activating from outside their artwork without remote click
leakage. First hosted run 39354381789 passes all 40 window/input cases offscreen,
on GNOME at 100%/125% and under ASan, but LeakSanitizer stops afterward on a
320-byte Fontconfig configuration allocation reached through Material startup.
The standalone test/probe now finalize Fontconfig after Qt teardown; leak
detection remains enabled, without suppressions or a production cleanup change.
The final Material screenshots show correctly sized, borderless icons at both
scales. Hosted rerun 39355378111 passed: all 40 window/input cases offscreen,
on GNOME/Wayland at 100%/125% and under ASan/UBSan with leak detection; both
complete Client builds, ordinary Client preflight, three Qt launcher cycles,
14 package fixtures and the finished-package gates also passed. The downloaded
DEB has no file overlap with the retained ordinary 1.1.039 Client. Hosted Mesa's
Vulkan/GL semaphore handoff remains an explicit skip, not hardware acceptance.

Exact **1.1.047-ubuntu-qt-session** package sources and evidence:

- Parent `f9ad67b704e7e9900c7304a49f6a8c86c91dc811`.
- Client `ba0d2227288eb055c17bf144518b5a4c42c295c7`.
- Successful [GitHub-hosted run 39355378111](https://github.com/instinctual/plank/actions/runs/39355378111).
- Package: `artifacts/packages/candidates/1.1.047-ubuntu-qt-session/linux/plank-client-qt_1.1.047-ubuntu-qt-session_amd64.deb`.
- SHA-256: `0445aeab306697628d489ef776cb0c484ff8016209ff0c35cc35643bcde46522`.
- Packaged executable SHA-256: `b3e9eac0ff9fe8a32576225c3e84d7c13d17ce4dd48a3eea4c77f17c25010f9c`.
- Retained reports: `artifacts/qualification/ubuntu-qt-session-1.1.047/`.

The successful job took about 18 minutes: 5m17 dependency bootstrap, 10m39
component/full-build validation, and the remainder setup/packaging. The first
test-harness cleanup failure required a separate attempt. No build-speed change
or reduced test policy was made. Build only through the explicit GitHub-hosted
`linux-client-qt` job. No end-user installation, merge or release was performed.
The operator subsequently accepted the toolbar appearance. Automatic recovery
after a cable interruption and full live-profile/audio/camera/microphone gates
remain separate.

### Retained toolbar labels, icons and automatic recovery

The operator accepts .045's windowed toolbar interaction. They request the
regular Client's two-row stats layout and recognizable pin/fullscreen icons.
Candidate **1.1.046-ubuntu-qt-session** stacks labels above FPS, Video Mbps,
Loss and RTT values, reserves text widths to avoid control movement, and keeps
the 39-pixel toolbar height. Encoder Target remains above its slider. Loss
colors and three-decimal precision are unchanged.

Bundled SVG resources replace the repaint-dependent Canvas pin and literal
square fullscreen character. Pin changes between upright/slashed; fullscreen
corners point outward or inward based on the top-level shell's actual state.
Qt SVG support is already a package dependency. No hover, video, Wacom or Host
policy changes are added. New tests check actual rendered
icon pixels, resource/state changes, hide/reveal, native window transitions,
stacked label geometry, stable control positions and no remote click leakage.
Hosted build/package qualification passed; the candidate is downloaded and
checksum/provenance-verified. Earlier attempts caught a read-only QML Image
size assignment, an overly strict antialiased-icon test and the standalone
probe's obsolete Keep Waiting callback. These were corrected without relaxing
the behavioral gates; none of those attempts produced a package. A fixed-size
Item owns each vector image, load guards protect the new tests, and the icon
fixture checks foreground contrast against the dark button background.
Continue on the existing `ubuntu-qt-session` branches; no deployment is claimed.

The operator also authorized automatic recovery after a cable interruption.
Read-only inspection confirmed that .045's Ask deadline paused retry requests,
even after the network returned. The Qt frontend now treats that timeout as a
notice deadline, not a retry deadline. It shows a Disconnect-only status dialog
while continuing the established bounded/delayed recovery loop. Successful
reconnection clears the notice and restores current input geometry without a
button press. Explicit auto-disconnect still uses its deadline. Authentication
denial, changed Host identity and active-session takeover remain terminal; no
new password retry policy or silent takeover is introduced. The regular Client
and macOS keep their current policy. Qt preferences describe the new behavior.
Added checks cover continuous/bounded request gating, revocation, terminal
errors, a single local Disconnect action, cursor visibility and automatic
notice removal/input restoration. Live cable-loss acceptance remains pending.

Exact **1.1.046-ubuntu-qt-session** package sources and evidence:

- Parent `967de834d1d23ffe76ee99de31559355ee169544`.
- Client `44b6c4f470f7eaa7cd1e3634eaa3d274e44986ca`.
- Successful [GitHub-hosted run 39350839732](https://github.com/instinctual/plank/actions/runs/39350839732).
- Package: `artifacts/packages/candidates/1.1.046-ubuntu-qt-session/linux/plank-client-qt_1.1.046-ubuntu-qt-session_amd64.deb`.
- SHA-256: `67be549b55a082d807e4be75c612281733f6df9a69858d12aebf4a4781dc6de1`.
- Packaged executable SHA-256: `91dc3dbfad8bd754f2edd34d7385d6cb92d519cf05fe1f9422091040ca40ef14`.
- Retained reports: `artifacts/qualification/ubuntu-qt-session-1.1.046/`.

All 38 window/input cases pass offscreen, under ASan/UBSan with leak detection,
and on isolated GNOME/Wayland at 100% and 125%. The restored icons, stacked
stats and Disconnect-only notice were also visually inspected in the actual
test renders. Both complete Client variants compiled; the ordinary Client's
preflight, continuous/bounded reconnect policy, three Qt launcher cycles,
14 package fixtures, production payload non-overlap and package/runtime gates
passed. Hosted Mesa still lacks the Vulkan/GL external semaphore capability;
that hardware-sensitive gate is skipped, not accepted. Microphone and camera
reuse the existing capture/transport and are wired into the Qt toolbar for
compatible macOS Hosts, but real-device Qt acceptance remains pending.
No Host update, remote installation, merge or release was performed. The
later production-style sizing issue above supersedes the earlier visual
acceptance of these default-style test images. No SSH or trace is active.

### Accepted windowed toolbar access and separate ghost-cursor investigation

The operator accepted the 1.1.044 video repair and reports working mouse and
tablet input. They also report a longstanding duplicate arrow at the physical
screen's top-left, outside the now-windowed session. Do not treat that as a
Host-video or coordinate-mapping defect without evidence. Controlled tests now
reproduce it **without PLANK running**: closing the app leaves the arrow; local
pen movement clears it; launching a standard native GNOME dialog brings it
back. Merely launching PLANK also reproduces it before any stream/tablet grab.
Temporarily disabling Qt's Wayland tablet interface did not help and is not a
product change. The launch-only process had no input/hidraw devices open.
Investigate the local GNOME/Wayland cursor lifecycle, not remote input mapping.
The precise compositor/driver defect remains unproven. No OS update, reboot,
Host change or permanent runtime setting was applied. Private machine evidence
and unsuccessful screenshot captures remain outside Git.

The operator refined the windowed solution: **no additional Show Toolbar
button**. Use a wider, twelve-logical-pixel activation strip below the native
title bar. Fullscreen retains its three-pixel physical-edge trigger. The
one-second dwell, five-second hide and Pin policy are unchanged. Mode follows
the top-level shell rather than the native child. Qt owns all hit testing;
no new popup/native surface or decoration implementation is added. Remote
drags suppress reveal. Added regressions cover dwell/cancellation, shell
fullscreen transitions, recovery, Pin and released-input fullscreen controls.
Hosted compositor runs save synthetic UI screenshots at both scales.

Candidate **1.1.045-ubuntu-qt-session** passed the hosted build and package
gates and is downloaded below. All 35 window/input cases pass offscreen, under
ASan/UBSan with leak detection, and on isolated GNOME/Wayland at 100% and 125%.
The new hover cases cover cancellation, repeated native fullscreen/windowed
transitions, recovery, Pin and released-input controls without Host click leakage.
Earlier attempts stopped in new test fixtures and produced no packages. The
final fixture waits for actual compositor geometry, exposure and rendering;
it does not incorrectly require keyboard activation in a headless input seat.
The original behavioral assertions remain. Synthetic screenshots were inspected
at both scales. The operator subsequently confirmed the windowed toolbar works.

### Retained hardware presentation repair

The operator reports that 1.1.043 connects and its toolbar responds, but the
remote image does not update normally. With permission, short thread snapshots
were collected from the already-affected Qt process and it was immediately
resumed. No package was installed, input injected, or Host process changed.
There is no captured deadlock: GUI/decoder threads were waiting normally and
presentation counters show some frames delivered. The log does show repeated
hardware presentation failure, software fallback and decode queue overflow.

An independent surfaceless EGL probe under the desktop user's account confirms
that the actual Intel desktop OpenGL driver rejects `GL_TEXTURE_EXTERNAL_OES`
with `GL_INVALID_ENUM`, while `GL_TEXTURE_2D` succeeds. The Qt importer chose
the unsupported target for packed Y410/XR30 and XYUV/XR24 images. The repair
imports all already-reinterpreted RGB/R/RG planes as ordinary 2D textures; it
does not change color mapping, decoding policy, transport or input. The unused
external-sampler variant is removed from this Qt-only renderer. Import failures
now report the failed operation and graphics error, once per failed generation.

The compositor precision regression now creates real EGLImages and uses the
same import helper as the renderer before checking packed 8/10-bit and planar
P010 values, crop and filtering. The former direct-texture fixture skipped the
failing operation. This remains synthetic qualification, not a substitute for
hardware VA-API DMA-BUF/live-session testing. Candidate 1.1.044 passed the hosted
gates and is downloaded below. The operator subsequently confirmed that it
fixed playback; complete profile/soak qualification remains separate. The
production Client and both Hosts are unchanged.
SSH is closed and no debugger remains attached. Private backtraces stay outside Git.

### Retained Wacom crash repair

The 1.1.043 cursor-texture ownership repair remains included. The prior
1.1.042 tablet crash resolved to double deletion in
`QSGSimpleTextureNode::setTexture()`. Qt now owns that texture's retirement.
The rendered 24-replacement/clear/visibility/destruction regression passes
again under normal, sanitizer and 100%/125% compositor tests. Do not recommend
1.1.042. The operator now reports working tablet/mouse input; pressure, margins
and interruption/reconnect qualification remain separate gates.

Continue in `build/worktrees/ubuntu-qt-session`, on matching parent/Client
`ubuntu-qt-session` branches, based on main
`38e00a557670df063926af1ef3466156145302ae` (1.1.039).
The persistent-tablet and Client session-recovery fixes are included.
The independent CUDA candidate and canonical checkout's unrelated PKG edits
remain untouched. Read [the plan](docs/development/plans/ubuntu-qt-session.plan).

The operator requires full feature equivalence and continued work until their
input is necessary. No Development NUC is currently available. Build/test only
on GitHub-hosted Ubuntu Actions; do not request VM prerequisite installation or
contact stale hardware addresses. The **PLANK Client Qt** /
`plank-client-qt` DEB must co-install without sharing production configuration,
bookmarks, trust, logs, libraries or executable/application identity.

### Previous candidate — accepted windowed toolbar access

**1.1.045-ubuntu-qt-session** is built, downloaded and checksum/provenance
verified. Exact package sources:

- Parent `2a792fd389eef3344adc40cbbcf2bf57a59c60c1`.
- Client `95e426587fb79913eee779cefe2b95a1a98c7baa`.
- Successful [GitHub-hosted run 39345546408](https://github.com/instinctual/plank/actions/runs/39345546408).
- Package: `artifacts/packages/candidates/1.1.045-ubuntu-qt-session/linux/plank-client-qt_1.1.045-ubuntu-qt-session_amd64.deb`.
- SHA-256: `ba697979c967a34847e6d527a09996fb1fe99952bb9c3296a4f9162637742aae`.
- Packaged executable SHA-256: `2fc03cf0eaf027c6f0f53ac1805ac74cd9793aecdb26ec377dcaba8885ea3ceb`.
- Retained reports: `artifacts/qualification/ubuntu-qt-session-1.1.045/`.

Both complete Client variants compiled and linked; ordinary Client preflight,
three Qt launcher/shutdown cycles, all 14 package fixtures, actual production
payload non-overlap, runtime/dependency/RPATH/version/no-autostart gates passed.
The 73 root CI-policy tests passed. The retained EGLImage/precision tests pass
again at both scales. Hosted Mesa still lacks the Vulkan/GL external semaphore
capability: that hardware-sensitive gate remains explicitly skipped. Sources
and recursive Client/transport pins match the downloaded report and BUILD-INFO.
No Host/macOS package was built, no candidate was remotely installed, and no
merge or release was performed. The normal installed Qt launcher was restored
without the temporary diagnostic environment; SSH and all diagnostics are closed.

### Previous candidate — accepted playback repair

**1.1.044-ubuntu-qt-session** is built, downloaded and checksum/provenance
verified. Exact package sources:

- Parent `ebbc237aad6e11b490dea427423da687a2cd97f9`.
- Client `bb7d75a8f232cf02c33b03a687ef8369f7df06b3`.
- Successful [GitHub-hosted run 39337612932](https://github.com/instinctual/plank/actions/runs/39337612932).
- Package: `artifacts/packages/candidates/1.1.044-ubuntu-qt-session/linux/plank-client-qt_1.1.044-ubuntu-qt-session_amd64.deb`.
- SHA-256: `6e2b6d69b015cfb77b0d686249095cea4502fb708d3bc52e0d277a0fb2c7dc10`.
- Packaged executable SHA-256: `e726d5c5bba0daa15c48808667fc5b579ce1b46a11130032ff57fb953f6302a6`.
- Retained reports: `artifacts/qualification/ubuntu-qt-session-1.1.044/`.

Both full application builds passed: the experimental Qt app and the ordinary
Client regression build/preflight. Component tests, ASan/UBSan with leak
detection and isolated GNOME/Wayland 100%/forced-125% tests passed, including
32 window/input cases at each scale. All 14 package-fixture checks passed.
The actual candidate and published 1.1.039 production DEB have no overlapping
non-directory payload paths. The synthetic install/purge test preserves the
production fixture; neither real package was installed on the builder.
Runtime dependencies, private FFmpeg/SDL, RPATH, version, actual Qt linkage,
no-autostart and package metadata gates passed. Three real launcher cycles
passed with SDL video deliberately unavailable. Privacy/clipboard regressions
and all 73 root CI policy tests also passed. These are not real network-session
or Intel GPU qualification results.

The candidate integrates the asynchronous Qt session owner with existing
transport, authentication, exact-profile decoder selection, audio synchronization,
recovery and teardown. Qt owns the windows and event dispatch; no SDL video
surface or second Wayland event loop is introduced. The same immutable
VA-API/software frame leases feed a one-slot presenter. Primary swap feedback
advances the unchanged audio clock. Qualification waits are bounded/cancellable.

All nine EGL-image import/shader cases pass in windowed/fullscreen and mode
round trips at both scales, including rejection of an 8-bit intermediate.
The software converter and shader tests preserve all 1024 codes, RGB identity,
full-range BT.709, crop/offset, downscaling and the unchanged encoded fixtures.
Current macOS Host profiles require full-range BT.709; the legacy setup-range
field is not authoritative. Both actual Apple profile fixtures are tested.
Generic limited-range conversion tests do not imply that macOS streams are limited.

Hosted Mesa does not expose the required Vulkan/OpenGL external semaphores.
The 120-roundtrip interop qualification correctly reports skipped, not accepted.
Actual Intel VA-API decoding/export, Vulkan-to-GL delivery, display precision,
performance, audio/video soak and physical Wacom remain pending hardware gates.

### Implemented scope / remaining acceptance

The current Client additionally connects toolbar bitrate acknowledgement,
shared rate/loss/RTT statistics, microphone/camera controls, overlay, Qt physical
keyboard/mouse input, shared raw-HID and normalized tablet workers, Host cursor
shapes/positions and Wayland shortcut/pointer policy. The ordinary Client now
shares its bounded cursor-message parser with the Qt frontend. New input tests
cover key identities, malformed cursor chunks and reconnect sequence epochs.
The raw-HID worker includes the .053 USB-retention changes described above;
the normalized fallback is unchanged.
The successful hosted checkpoint also exercises retained tablet-reader
lifecycle, cross-output drag geometry, P010 two-plane GPU conversion, idle
inhibition, visible-output precision qualification, and stale-generation
rejection. The earlier incorrectly typed Qt signal sender is corrected, and
both complete applications compiled and linked successfully.

The launcher now uses Qt display enumeration without an SDL video probe. Exact
decoder qualification remains on the session surface, not an unknown temporary
window. Unix termination follows the Qt asynchronous teardown path. A new
compiled display-enumeration test and three complete launcher smoke cycles run
with SDL video unavailable. The candidate also keeps Ctrl+Alt+Shift+Q local during startup,
released input and Host timeout, with tests for repeat suppression, no remote
key leakage and non-Latin layout fallback. Both local and streaming shortcuts
use the same layout resolver. All these hosted gates passed. The earlier .041
run was superseded before packaging; it is not the delivered candidate.

**Next action: .053 live Flame USB/network recovery acceptance**, using the
sequence at the top of this file and in `protocol/wacom-hid.md`. Earlier .046
toolbar/recovery instructions are not a request to reinstall that candidate.
Preserve the accepted toolbar appearance, spacing and windowed reveal behavior.
During network recovery, the status dialog must recover automatically without
a Keep Waiting click; separately verify Disconnect and the configured
automatic-disconnect policy. The desktop ghost is independently reproducible
without PLANK; do not add input workarounds merely to hide it.
Keep the ordinary Client closed during Qt testing. Still confirm exact-profile H.264
High 10 software and HEVC Rext 10-bit hardware paths, toolbar/letterbox and
window controls, keyboard/mouse, Wacom pressure/Tablet Margins and recovery,
one/two outputs and scale changes, microphone/camera, and a moving-video/audio
soak. Capture the Qt app's separate `plank-client-qt/logs` state directory if
startup fails. No Host update is needed for this experiment. Do not remove the
ordinary implementation or claim full feature equivalence before acceptance.
No package was remotely deployed and no merge/release is authorized. Preserve
the experimental branches and canonical checkout's unrelated edits.

Dispatch from a clean pushed branch with:
`bash scripts/ci/dispatch.sh linux-client-qt-tests false`.
That target builds both full application variants and isolated tests, not a package.
Use `bash scripts/ci/dispatch.sh linux-client-qt false` to run the same gates and
then package the exact Qt binary with the independent identity. All checks run
on GitHub-hosted Ubuntu; do not install a package on a builder.
Warnings include inherited FFmpeg Vulkan queue-callback deprecations, unused
Quinn telemetry and the existing launcher Back shortcut's multiple bindings;
do not claim a warning-free build. Minimal headless GNOME lacks optional
calendar services; its generated warnings did not fail the isolated tests.

Dependency pins remain unchanged: Linux Host `65dc0f1be60fe78d0457364f83813118c70bc8a8`,
Client common-C `437be9a0a4d164efdf9ed20dc6dd5a2b7b9edc90`,
qmdns `920c097ffa742e2968290f15d4dde6693aec02e5`,
Kymux `3f7a9d8618978287186e5d6ce0eaa067743cb06c`,
build-deps `c29c4822cb96f5bfeb8640e72601c5cf4e3c3137`.
No Host, macOS-specific session or wire-protocol changes are part of this work.

## Retained candidate — CUDA 13.2 Update 2

Continue in `build/worktrees/cuda-13-2` on `cuda-13-2`, based on main
`38e00a557670df063926af1ef3466156145302ae`. The operator reports the released
1.1.039 working without observed issues on NVIDIA 595.104.02 and authorized a
separate Linux Host toolchain candidate. Version is **1.1.040-cuda-13-2**.
Do not merge, publish a release, install a package or interrupt a live session
as part of this build request. The independent Qt Ubuntu prototype stays paused.

Only the Linux Host CUDA build components move to Toolkit 13.2 Update 2
(NVCC/runtime 13.2.86). Exact RPM pins and a fail-closed component/compiler
check are shared by hosted installation and package preflight. The existing
cache fingerprints already include NVCC and installed RPMs; the compiled Host
dependency tree rebuilds with the new toolchain without weakening cache checks.
Keep the full GPU architecture set. Host/Client/Kymux and recursive source pins,
NVENC SDK 13.0.19 headers, encoding settings, transport and macOS are unchanged.
No new Client package is needed.

The Linux Host-only hosted build passed at exact source
`c018fb26048cf723d3ba5fc4315dbee562472755`:
[39186329545](https://github.com/instinctual/plank/actions/runs/39186329545).
The RPM is downloaded and collected under
`artifacts/packages/candidates/1.1.040-cuda-13-2/linux/`:
`plank-host-1.1.040-0.cuda_13_2.1.el9.x86_64.rpm` (8,749,513 bytes), SHA-256
`5f5ebb2b8e4fa672e8a9df2ce91573512d128f01c66296f07a3cec756ed5ec72`.
The transferred manifest exactly matches the hosted manifest. The package
contains visible version `1.1.040-cuda-13-2`, CUDA fatbins, the production
`BUILD_TESTS=OFF` payload and its owned root:root `0700` log directory. RPM
runtime requirements match 1.1.039 apart from the self-versioned config entry.

Validation passed: 75 CI-policy tests, 17 local packaging/path/collection
checks plus the release-version contract, dependency-patch verification,
Rust/protocol/C ABI gates, and three 900-frame controlled-loss matrices at
150 Mbps/60 fps over 0/0.5/1/3/5% loss (zero unrecovered source symbols).
The input lifecycle suites ran 25 shuffled repetitions each: 45 production
passes with three kernel-dependent skips, and 56 wrapped-UHID fixture passes.
Both CUDA installation and package preflight verified NVCC 13.2.86. Compilation
retained architectures `75;80;86;87;89;90;100;103;110;120;121` and NVENC headers
`e844e5b26f46bb77479f063029595293aa8f812d` (SDK 13.0.19).
Rust, Cargo and Boost caches were reused; the Host FFmpeg/dependency cache was
rebuilt, patch-verified and saved for the new compiler. All root and recursive
source pins remain those of the baseline below.

No build remains running. No merge, release publication or installation was
performed. Next is manual Host installation with the existing 1.1.039 Client,
then real capture, identity/color, scaling, NVENC and live performance checks
on 595.104.02. These hardware gates remain pending; hosted results do not prove
a performance gain or replace live qualification.

## Inherited main baseline — persistent tablet and Client recovery integrated

The operator authorized merging `wacom-persistent` into main. The parent,
Linux Host and Client now use `main`; the two changed dependencies use their
established product branches. All integration is fast-forward, preserving the
candidate commits and their authorship. Main remains in
`build/worktrees/wacom-persistent`, not the canonical checkout's
separate, dirty `client-pkg-only` branch.

| Component | Integrated source / branch |
| --- | --- |
| Parent package source | `2b3279755bd7ed27ffcd380a0121e9793bf469e6` / `main` |
| Linux Host | `65dc0f1be60fe78d0457364f83813118c70bc8a8` / `main` |
| Client | `58f4df097c1cdf11bf6b4b429701f156e2b10109` / `main` |
| Client common-C | `437be9a0a4d164efdf9ed20dc6dd5a2b7b9edc90` / `plank/client` |
| Host libvirtualhid | `b793fa2f5369218c43e09c58d5b96a0cc638bf05` / `plank/main` |

This includes `wacom-state-recovery`, `client-session-recovery`, persistent
desktop tablets, the reproducible private Ubuntu SDL repair, and Mac Client
PKG-only packaging. It does not include the independent `ubuntu-qt-session`,
`apple-native-integration` or `native-builds` work. The ordinary product Kymux
pin remains `3f7a9d8618978287186e5d6ce0eaa067743cb06c`; no dependency update PR
was merged as part of this task. Host header-only common-C remains unchanged.

All 70 root CI-policy tests were rerun successfully. Privacy checks passed for
the complete newly integrated range in each changed repository. Product source
and dependency pins are identical to the successful `.039` Host candidate;
only HANDOFF differs. Previous `.036` and `.037` validation below still applies
to their exact recorded components, not to an unperformed new hardware test.

All four **1.1.039** mainline packages were built from the exact parent package
source above, downloaded and checksum/provenance-verified. The operator then
authorized publication. [PLANK 1.1.039](https://github.com/instinctual/plank/releases/tag/v1.1.039)
was published on 2026-10-12 as the latest release, using those unchanged
packages. Existing candidates keep their original filenames/checksums; none
was relabeled.

| Package | Successful hosted build |
| --- | --- |
| Rocky 9.7 Host RPM | [38287535913](https://github.com/instinctual/plank/actions/runs/38287535913) |
| Ubuntu 26.04 Client DEB | [38286682059, Client job](https://github.com/instinctual/plank/actions/runs/38286682059/job/114936731007) |
| Signed/notarized macOS 27 Host PKG | [38287229443](https://github.com/instinctual/plank/actions/runs/38287229443) |
| Signed/notarized macOS 15+ Client PKG | [38287233183](https://github.com/instinctual/plank/actions/runs/38287233183) |

The original files and combined provenance manifest are in
`artifacts/packages/releases/1.1.039/{linux,macos}/`. Annotated tag `v1.1.039`
points to the exact package source `2b3279755bd7ed27ffcd380a0121e9793bf469e6`,
not a later documentation commit. The release has four installers, a flat-name
`SHA256SUMS`, and a public `manifest.json`; their server-side hashes matched
the local files before publication. A fresh download of the published assets
also passed all four checksums and byte-for-byte metadata comparisons.
Mac Client delivery is PKG-only. SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `linux/plank-host-1.1.039-1.el9.x86_64.rpm` | `8db345237dba1808a3b731e66337f5fff27d167668c6519d8f4734c74d5201e0` |
| `linux/plank-client_1.1.039_amd64.deb` | `1dfb05a39ce42f8f9cdaf1fdcebb7cc0c0ff418ae881e5fb668f947bccb5e78c` |
| `macos/plank-host_1.1.039_arm64.pkg` | `0af10e2ef2dfbe129e1274142fda644df96fd3f71cf10049f1cd56aada8eec3a` |
| `macos/plank-client_1.1.039_arm64.pkg` | `5786914eee466ca764a2dd14021d11723cea0886ef8aa3c6e5dd199a5ad7fc81` |

Hosted compilation, automated regression tests and package checks passed. The
Host ran three 900-frame loss matrices with zero unrecovered source symbols,
25 shuffled production input-suite repetitions (45 passes and three unavailable
kernel-dependent cases each), and 25 wrapped-UHID fixture repetitions (56 passes
each). The RPM is the `BUILD_TESTS=OFF` production payload and owns its root:root
`0700` log directory. The Ubuntu DEB contains the patched private SDL 3.4.2
runtime and passed Wacom worker/reconnect, render shutdown, cursor lifecycle,
runtime dependency and no-autostart checks. Both Mac PKGs passed notarization,
stapling and Gatekeeper on their builders. No hardware acceptance is implied.

The original all-product run's Host job failed before compilation when fetching
the unchanged AMF dependency (`bad pack header`). Only the Host was redispatched
at the identical source; that retry passed without source changes or relaxed
gates. Verified dependency caches were saved on main. The original run remains
red because of that first Host job; its Client artifact is successful.

No build remains running, no package was installed and no session was
interrupted. Live network-interruption/Flame acceptance and the separate hotkey
diagnostic remain open. Feature branches are retained; no cleanup was requested.

## Candidate evidence — persistent Linux desktop tablet

The candidate was prepared on `wacom-persistent`, based on
`client-session-recovery` parent `1572c09e26d6ce7db20d9d1feefe11a3155963b8`.
**1.1.039-wacom-persistent**, Linux Host only, is built and downloaded.
Client source remains
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
No candidate build remains running. The later integration is recorded above;
no release or installation was performed.

All four Host dependency caches missed in that first attempt. The earlier
Ubuntu SDL cache work changed the shared cache script, which participates in
every component fingerprint; this invalidated unrelated Host keys. Versions
were unchanged, and new exact-input caches were saved successfully. Keep this
cache-granularity inefficiency separate from the test-target repair; no cache
validation was weakened.

No package has been installed and no machine restarted or interrupted.
The operator authorized integration; real hardware acceptance remains pending.
Next hardware gate: after installing the Host and restarting Flame once to
clear any previously cached device identities, leave Flame running and interrupt
the Client network for about ten seconds, reconnect, and verify stable Host
XInput device identities, hover, tip/barrel buttons, pressure and Tablet Margins.
Also test ordinary disconnect/reconnect, Client restart and authorized takeover. Real-kernel
cleanup, XInput identity and Flame acceptance are not proved by the fixture.

## Open diagnostic — application hotkeys

The operator reports ordinary typing and Shift capitalization work, but some
Flame shortcuts using Shift do not. Read-only inspection found no Client USB
keyboard disconnect/reset since boot and no Host virtual-keyboard replacement
after Flame started. Neither side showed held modifiers when sampled; Flame
had focus and its log still recorded other shortcuts. These observations do
not prove delivery of the particular failing shortcut, which has not yet been
specified.

A later raw-Wacom endpoint replacement was observed on the older Host candidate,
but no causal link to the keyboard symptom is established. The inspected Host
was still `.036`, with Client `.037`; the new `.039` Host was not installed.
Do not attribute the symptom to the uninstalled persistent-tablet repair.
No keys were injected/reset, devices grabbed, debugger attached, application
restarted or session interrupted. No keyboard fix was implemented.

Next diagnostic, only with operator participation: identify one exact safe
failing combination, including whether Shift is paired with a key or pen/mouse
action, then compare bounded passive Client and Host input observations.
Do not collect arbitrary typed content or passwords. Private machine/log
locations remain outside Git. There is no running trace or monitoring task.

The independent Ubuntu SDL cursor-retirement fix remains necessary: preserving
Host tablet endpoints does not repair Client Wayland surface teardown. The
Qt session experiment is separate, paused and not included in these packages.

## Inherited candidate — Client session recovery

The inherited candidate was prepared in `build/worktrees/wacom-state-recovery`
on `client-session-recovery`. Parent base `5ac23ba7f6f5a84c347e3081791521e25a369c2e`
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

## Previous mainline build — 1.1.035

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

## Previous mainline baseline — scaling and Wacom consolidation

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

Current native development and TestFlight automation are on `native-builds`;
read that worktree's HANDOFF for the accepted imports and current testing gate.
The original coordination checkpoint below is historical. Its branch is
retained, but the duplicate `apple-native-integration` worktree is retired.

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

[PLANK 1.1.039](https://github.com/instinctual/plank/releases/tag/v1.1.039)
is the recorded published baseline. Exact source, package hashes and build
evidence are in the **Inherited main baseline** section above, not the current
Qt candidate section. [Release notes](docs/releases/1.1.039.md)
compare against 1.1.030 and explicitly preserve the remaining hardware gates;
publication does not claim that unperformed tests passed. No machines were
automatically upgraded.

[PLANK 1.1.030](https://github.com/instinctual/plank/releases/tag/v1.1.030)
remains the previous published rollback point. Exact source is
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

The ordinary Client's audio policy uses Host common-clock phase for macOS and separate
relative-rate handling for Linux. Smooth resampling is bounded to one percent,
with SDL output-demand/headroom guards. No extra audio-frame dropping or video
delay was added; recovering playback reserve can retain a few milliseconds.
A shortage-request counter is not a measured speaker underrun. See the
[audio plan](docs/development/plans/audio-sync.plan) and
[real-world procedure](docs/development/audio-sync-baseline.md).
The Qt candidate instead uses native PipeWire playback from .049 onward;
its isolated daemon/clock tests do not replace the pending real-output listening
and A/V-sync soak. Do not diagnose Qt playback as the ordinary SDL audio path.
No old sampler is still running merely because a prior note described a soak.

Keep machine identities and private evidence outside Git. Read the private notes
README before accessing any test system.
