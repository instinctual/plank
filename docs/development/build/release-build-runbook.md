# PLANK Release Build Runbook

For disposable GitHub-hosted workers, see [GitHub-hosted builds](github-builds.md).
Hosted jobs reuse exact-input dependencies, never application objects
or signing state. Use the dispatch helper's `--clean-bootstrap` third argument
to bypass both cache restore and save when qualifying a fresh bootstrap.
Those workflows establish the same OS, dependency, clean-source and package
contracts through `scripts/ci/`; they do not deploy or replace hardware gates.

A full application rebuild still permits reuse of verified, exact-input
dependencies. Reserve `--clean-bootstrap` for an explicit dependency-bootstrap
qualification, not ordinary rebuilds after a merge. All four hosted products
have exact-input dependency caches. Linux Host retains prepared FFmpeg and
Boost sources, Ubuntu Client retains patched FFmpeg, and macOS Client retains
prepared libraries and Qt. The other three products also retain the pinned
Rust toolchain and downloaded Cargo inputs; macOS Host uses native Apple media
frameworks, so has no separate FFmpeg/Qt dependency build to cache. Application
and transport objects, tests, packaging and signing always run fresh. See
`github-builds.md` for cache boundaries and cold/warm qualification status.

This is the canonical, repeatable procedure for producing PLANK host
and client candidate packages. Read it before changing or running a release
build. `AGENTS.md` defines machine policy; this runbook supplies the exact
sequence and records known failure signatures.

For a clean replacement builder, read `docs/development/build/builder-vm-bootstrap.md` first.
It recreates every non-Git input and defines the path-variable contract.
Absolute paths in historical release records are provenance, not reusable
configuration. Export `PLANK_SOURCE_ROOT`, `PLANK_CANONICAL_ROOT`, `PLANK_WORK_ROOT`,
`PLANK_DEP_ROOT`, `PLANK_PACKAGE_ROOT`, `PLANK_RUSTUP_ROOT`, and
`PLANK_CARGO_ROOT` for the current builder before using the commands below.

## Package catalog and source layout

Products live under `apps/`; packaging templates under `packaging/<product>/<os>`.
Git submodule section names remain `host/sunshine-fork` and
`client/moonlight-qt-fork`, but working paths are `apps/host/linux` and
`apps/client`. Never infer a working path from a section name.

The package scripts assemble into the explicit candidate scratch directory,
run their existing package gates, then call `scripts/package/collect-package.py`.
The collector writes to `$PLANK_CANONICAL_ROOT/artifacts/packages` by default
(override with `PLANK_ARTIFACT_ROOT`). Main builds use
`releases/<version>/<os>`; feature builds use `candidates/<version>-<branch>/<os>`.
Filenames retain product and architecture. Each version contains a manifest
and checksums. Keep this catalog outside disposable candidate worktrees.

When bringing a package back from another builder, run the collector locally
with the exact source commit, branch, product, OS, architecture, target OS and
the builder's independently recorded SHA-256 (`--expected-sha256`). Never
relabel a feature package after merging. See `artifacts/README.md`.

Root CMake only builds qualification tools/tests. To validate repository
structure and package collection without Linux hardware dependencies, use
`-DPLANK_BUILD_LINUX_QUALIFICATION=OFF`. This is not a product build or hardware
qualification substitute.

## Distribution build paths

Product build entrypoints source `scripts/build/build-paths.sh`. Preserve its
C/C++ file-prefix maps and Rust remap flags, including the macOS SDK27
`strip=none` workaround. Do not set `CARGO_ENCODED_RUSTFLAGS`: it overrides
the required Rust flags and is rejected. Build roots must not contain whitespace,
quotes or equals signs. These mappings affect diagnostic/debug filenames, not
filesystem access, media configuration or protocol behavior.
Cargo native objects use `HOST_*FLAGS`/`TARGET_*FLAGS`. Do not export plain
`CFLAGS`/`CXXFLAGS` through qmake/Make: Make exports its replacement app flags
to Cargo, which can inject the ARM C-only forced header into Ring assembly.

Client FFmpeg bootstrap sanitizes only the generated `FFMPEG_CONFIGURATION`
diagnostic string after configure, retaining all codec/platform options and the
identity-GBR patch. Its actual install prefix and pkg-config metadata remain the
prepared dependency directory. Rebuild old prepared Client libraries with the
current bootstrap scripts; stripping or relabeling an old library is not enough.

macOS OpenSSL is configured for a neutral product prefix and staged with
`DESTDIR`. Only development pkg-config/link metadata is relocated into the
prepared tree. Its runtime configuration default is `/etc/plank/openssl`,
not a builder's home directory; no configuration, optional provider module,
engine, or trust-policy file is newly shipped. Bundled dylibs are relocated and
signed by the existing app packaging step. Never modify signed release bytes.
OpenSSL links with `-headerpad_max_install_names` so staged development install
names can grow without exceeding Mach-O load-command space.

All four package entrypoints run `check-package-build-paths.py` on their payload
before collecting a package (the RPM is extracted after normal debug stripping).
It rejects embedded Linux/macOS home paths
and reports counts only. Run `tests/packaging/test-build-paths.py` when changing
this policy. This narrow reproducibility gate supplements, not replaces, the
private denylist/history/asset audit and live runtime acceptance.
Client DEB and Mac assembly remove debug sections before hashing/signing; the
unstripped development binary remains available privately. This also removes
assembly DWARF from static dependencies, which compiler file macros do not map.
DEB BUILD-INFO records both unstripped-build and actual packaged binary hashes.
The pinned official macOS Qt6.10.2 libraries contain three public vendor source
paths (six occurrences). The gate allows only those exact NUL-terminated strings
inside their specific QtQuick/QtWidgets frameworks, never a general vendor or
home-directory exemption. They are not operator metadata; do not rebuild Qt or
edit its runtime strings solely to remove public upstream diagnostics.

## Classify failures correctly

macOS Finder's prohibited icon / "damaged or incomplete" can be inaccessible
bundle metadata, not a corrupt binary or rejected notarization. Host 1.0.103
contained owner-only bundle directories and resources inherited from umask 077.
Root signature/notary checks did not prove ordinary desktop users could read
the app. Build assembly now scopes public resources to umask 022, including
codesign's generated seal. `check-macos-host-permissions.py` independently checks
the app, staged payload and the finished PKG's BOM and extracted payload.
Directories must be 0755, resources 0644, executable/uninstaller 0755; symlinks
and unexpected executable/write permissions fail. CI assembles an ad-hoc Host
bundle under caller umask 077 and tests an unsigned PKG roundtrip. These are
not distribution signing or live installation passes. Never broaden installed
private keys, configuration or log permissions to repair a public app bundle.

The macOS Host distribution recommends restarting through Installer. The final
PKG gate requires `installer -query RestartAction -pkg PACKAGE` to report
`RecommendRestart`. Restarting loads an updated microphone driver; the installed
binary hash alone does not prove Core Audio has loaded that version. Users can
defer the restart. Package scripts must not reboot or restart audio services.

A compiler, linker, package gate, or nonzero packaging-script exit is a build
failure. A later ad hoc inspection command is a validation-command failure and
does not invalidate an already successful build unless it exposes a package
defect.

The Qt client initializes a GUI platform before handling `--version`. Over a
headless SSH connection, invoking it without a platform override aborts with
`could not connect to display`. Always run a package-tree version check as:

```bash
package_tree=${PLANK_PACKAGE_TREE:?set the extracted Client package tree}
QT_QPA_PLATFORM=offscreen \
env -u LD_LIBRARY_PATH \
  "$package_tree/usr/bin/plank-client" --version
```

`scripts/package/build-client-deb.sh` performs this check automatically and requires
the exact effective version described below. It also confirms that
the packaged icon is byte-for-byte identical to the approved client logo.

Do not apply that ad hoc invocation to an uninstalled Host on linux-host-builder. The
Host reads its administrator configuration before dispatching `--version`,
so it aborts when `/etc/plank/host.conf` is absent. That is a diagnostic-command
failure, not a compile/package failure; do not install a Host configuration on
the builder to work around it. Verify RPM version, the production compile's
`PROJECT_VERSION`, and the extracted media binary's embedded version instead.
Distinguish `/usr/bin/plank-host` (launcher script) from
`/usr/libexec/plank/plank-host` (media ELF) when recording payload hashes.

## Native transport lifecycle qualification

The Linux Host build runs the vendored Quinn DATAGRAM boundary/accounting tests
before compilation. Prepare its test-only dependencies with
`cargo fetch --locked --target x86_64-unknown-linux-gnu --manifest-path third_party/quinn-proto-0.11.17/Cargo.toml`
alongside the production transport fetch. Hosted bootstrap does this
automatically. These use the vendor's separate lockfile and test archive, never
the production link inputs.

The native loss matrix requires three consecutive release-mode passes for the
selected shipping rate policy, with no retry after failure. The loopback runner defaults to release;
an explicitly requested debug run is diagnostic, not performance qualification.
Each pass sends exactly 150 Mbps of payload at 60 fps: 312,500 bytes per frame,
180 frames (three seconds) at each of 0/0.5/1/3/5% induced loss. Every pass
requires all 900 payloads byte-for-byte in order and zero unrecovered source
symbols, plus these fixed performance gates **at every loss level**:

- Submitted and received payload throughput at least 142.5 Mbps (95% of nominal).
- p95 scheduled-frame-to-complete-frame delivery at most 50 ms.
- Maximum scheduled submission and delivery at most 100 ms.
- Maximum receive gap at most 100 ms, including across loss-phase boundaries.

One continuous 60 Hz schedule supplies the timing origin: a delayed send must
not reset its deadline, lower the offered load, or disguise accumulated latency.
Send/receive waits use absolute 100 ms deadlines; measured completion times also
catch synchronous work that an async timeout cannot preempt. Per-phase output
includes submitted/received payload rates, received frame rate, worst submission,
p95/worst delivery, worst receive gap, completion duration and pass/fail. These
are loopback regression bounds, not WAN or glass-to-glass latency guarantees;
payload rates exclude FEC, QUIC and IP overhead. Deterministic unit tests prove
that slow senders, catch-up stalls and delayed phases fail even when all frames
eventually arrive. The matrix's fixed-size frames and evenly spaced proxy drops
do not replace hardware, variable-keyframe, burst-loss or WAN soak testing.

Its dedicated test-only proxy reports
the effective socket receive buffer and Linux per-socket kernel drops separately
from deliberately injected loss. `controlled_loss_only=false` means extra local
drops occurred (or the counter is unavailable on that OS); do not describe that
run as an exact-loss measurement. A complete recovery pass still exercises at
least the deliberate loss. Any frame failure remains a failure, regardless of
proxy drops. Do not loosen assertions, add retries, tune machine-wide sysctls,
or change product pacing/FEC/latency to hide a fixture limitation.

For native transport lifecycle changes, run the Rust completion tests and the
real C ABI stress runner on Linux and the dedicated Mac:
`bash scripts/test/run-peer-close-stress.sh ABSOLUTE_ARCHIVE NEW_OUTPUT 50`.
It executes 100 active/setup-promoted connection cases and stops on the first
failure. Do not interpret KyNet's orderly `closed() -> Ok(())` as a local stop:
only an explicit local stop request may produce `Stopped`; a peer close must
deliver queued control followed by a terminal receive error. A result of
`TIMEOUT` with state 7 (`Stopped`) and no error is the fixed 1.0.97 failure
signature, not proof of congestion or a missing close packet. See
[qualification](../reviews/peer-close-qualification.md). Keep the 2-second bound;
do not add retries to make this gate pass.

## Source snapshot order

Use clean Git worktrees. Do not use source archives. For unpublished commits,
create and SHA-256-verify Git bundles. Import nested dependencies before their
parents. Verify the exact refs carried by each bundle; a bundle created from a
named branch does not necessarily advertise `HEAD`. On `linux-client-builder`,
import the Moonlight bundle into the canonical client repository first; then
import the root bundle into the canonical root repository with recursive
submodule fetching disabled. Create detached worktrees after both imports:

The standard release defaults below assume common-c, qmdnsengine, Kymux, Host,
and Client dependency commits are already pushed and present in the builder's
canonical repositories/mirror. If any nested commit is unpublished, stop and
import its verified bundle before its parent: common-c or qmdnsengine before
Client; Kymux, Host, and Client before root. Update the retained Kymux mirror
from its verified bundle before initializing the root worktree. Set
`client_ref` and `root_ref` to the actual candidate refs for a feature build;
the `main` defaults are only for a mainline release. The sanitized Host,
Client and Kymux companion repositories each use `main`.

```bash
source_root="$PLANK_SOURCE_ROOT"
client_ref=refs/heads/main
root_ref=refs/heads/main
if ! git -C "$source_root/apps/client" \
  show-ref --verify --quiet "$client_ref"; then
  client_ref=refs/remotes/origin/main
fi
bundle_dir="$PLANK_WORK_ROOT/candidate-bundles"
client_repo="$PLANK_CANONICAL_ROOT/apps/client"
root_repo="$PLANK_CANONICAL_ROOT"
client_worktree="$PLANK_WORK_ROOT/client-candidate"
root_worktree="$PLANK_WORK_ROOT/root-candidate"
client_bundle="$bundle_dir/client.bundle"
root_bundle="$bundle_dir/root.bundle"

mkdir -p "$bundle_dir"
git -C "$source_root/apps/client" bundle create \
  "$client_bundle" "$client_ref"
git -C "$source_root" bundle create "$root_bundle" "$root_ref"
sha256sum "$client_bundle" "$root_bundle"
git -C "$source_root/apps/client" bundle verify "$client_bundle"
git -C "$source_root" bundle verify "$root_bundle"
git bundle list-heads "$client_bundle"
git bundle list-heads "$root_bundle"
client_commit=$(git bundle list-heads "$client_bundle" \
  "$client_ref" | cut -d' ' -f1)
root_commit=$(git bundle list-heads "$root_bundle" \
  "$root_ref" | cut -d' ' -f1)
test "$client_commit" = \
  "$(git -C "$source_root/apps/client" rev-parse "$client_ref")"
test "$root_commit" = "$(git -C "$source_root" rev-parse "$root_ref")"
git -C "$client_repo" fetch --recurse-submodules=no "$client_bundle" \
  "+$client_ref:refs/plank/candidate/client"
git -C "$root_repo" fetch --recurse-submodules=no "$root_bundle" \
  "+$root_ref:refs/plank/candidate/root"

git -C "$client_repo" worktree add --detach "$client_worktree" "$client_commit"
git -C "$root_repo" worktree add --detach "$root_worktree" "$root_commit"
```

Do not replace either fetch above with a plain `git fetch`. Repository-local
configuration can enable recursive submodule fetching and cause Git to contact
GitHub for an unpublished child commit before its local bundle is registered.
The explicit command-line option is the hard guard; the import order remains
client first, root second.

The `git -C` on bundle creation is also a hard guard. Root and Client can both
have similarly named refs; creating `client.bundle` while accidentally in the
root repository produces a valid-looking bundle with the wrong object. The
two `test ... rev-parse` checks above must pass before either bundle is copied
or imported.

Let long-running Git/build commands remain attached to their execution session
and wait on that exact session or PID. Never monitor them with a loop around
`pgrep -f`: the watcher command can match itself and remain alive indefinitely.

An error such as `not our ref <client-commit>` during root-bundle import means
the dependency was imported in the wrong order. It is a source-seeding error,
not a compilation failure. Import the client bundle, repeat the root fetch with
recursion disabled, then verify the exact root, client, and recursive-submodule
commits before building.
An error such as `couldn't find remote ref HEAD` means the fetch incorrectly
assumed the bundle advertises `HEAD`; use the exact ref printed by
`git bundle list-heads`.

## Client DEB — linux-client-builder only

The Host/Client base version is packaging/VERSION. Increment it for new package
bytes. Starting with **1.1.001**, retain a three-digit, zero-padded patch component
(1.1.002, 1.1.003, and so on) in the product version and package filenames.
This is the operator-facing product numbering convention, not strict SemVer;
do not parse the padded component as octal or strip its leading zeroes.
Internal dependency/crate versions and protocol negotiation are separate.
Set PLANK_BUILD_BRANCH explicitly on detached snapshots: main produces
an unqualified version; a feature branch adds its lowercase kebab-case name to
package filenames and visible application versions. Never relabel a candidate
after merging; rebuild from main. RPM feature Release values sort below the
same-version main package; Debian feature versions sort above it and require
an explicit downgrade when replacing them at the same base version.

For the explicitly authorized .52 frame-flow diagnostic, export
`PLANK_CLIENT_FRAME_FLOW_TRACE=1` before `build-client-package-binaries.sh`.
Default0 leaves tracing disabled. This passes `CONFIG+=plank-frame-flow-trace`
to qmake; require `PLANK_FRAME_FLOW_TRACE` in the app Makefile and the numeric
`PLANK frame-flow` marker in the finished ELF. No transport feature or Host
change is needed. Use this diagnostic Client with the retained .51 Mac Host.
The trace stores at most49152 numeric records per lane and120seconds per
receive/decoder/render instance. It flushes at teardown to existing Client
logs, not to a new file or endpoint. Memory is bounded, no frame payload or
input/credentials/addresses are captured, and no per-frame trace logging occurs
during ordinary playback. A decoder reset can flush its retired instance.
Decode/render queue policy is unchanged. Record instrumentation overhead as
unqualified until compared; this is not a production-default feature.
Run `tests/protocol/client-frame-flow.cpp` plus
`tests/protocol/test-client-frame-flow.py`; after user disconnect, analyze the
complete Client product log with `scripts/test/analyze-client-frame-flow.py`.
The parser handles interleaved lane flushes and rejects incomplete traces.
Existing AVFrame presentation timestamps have millisecond precision, so render
joins use that precision and flag duplicate receive timestamps as ambiguous.

Canonical build machine: `linux-client-builder` (`192.0.2.42`). Its qualified
toolchain is Qt 6.10.2 and the prepared private FFmpeg 9.0.1 work directory at
`$PLANK_CLIENT_FFMPEG_WORK`. `client-test-machine` is the separate
install/functional-test target; never compile a release candidate there.
The prepared FFmpeg source must contain the tracked identity-GBR hardware
decode patch under
`apps/client/app/deploy/linux/ffmpeg-patches/`; the Client package
preflight verifies the patch and fails before qmake if it is missing. Do not
recreate the prepared FFmpeg tree from the upstream archive without running
`scripts/build/build-client-ffmpeg.sh` to apply that product patch.

The PLANK native transport additionally requires exact Rust 1.89.0 and the
retained Cargo source cache. That cache includes the exact `kywasmtime` Git
database/checkout and every registry crate resolved by the pinned KyProto
lockfile. Export these paths before qmake or either package script; do not let
a clean worktree download a toolchain or crate:

```bash
export RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export CARGO_HOME="$PLANK_CARGO_ROOT"
export PATH="$CARGO_HOME/bin:$PATH"
test "$(rustc --version)" = "rustc 1.89.0 (29483883e 2025-08-04)"
test "$(cargo --version)" = "cargo 1.89.0 (c24e10642 2025-06-23)"
```

Before the first qmake invocation in a clean candidate, prove the retained
cache with a target-specific offline build. `cargo fetch --offline` is not a
valid preflight: it resolves irrelevant cross-platform packages such as
`windows-sys` that the qualified Linux target does not build.

```bash
cargo_preflight="$PLANK_WORK_ROOT/cargo-preflight-candidate"
CARGO_TARGET_DIR="$cargo_preflight" \
  cargo build --release --locked --offline \
    --target x86_64-unknown-linux-gnu \
    --manifest-path "$root_worktree/protocol/plank-transport/Cargo.toml"
```

The SDL3 candidate uses the system's native SDL3 and SDL3_ttf development
packages and links directly to `libSDL3.so.0` and `libSDL3_ttf.so.0`; do not
introduce `sdl2-compat`. Audio uses SDL3's PipeWire driver and device-stream
API rather than libsoundio or a PulseAudio compatibility renderer.

After installing an SDL3 candidate on the Client hardware-test target, validate
the same native output API without requiring a Host session:

```bash
root_worktree=${PLANK_ROOT_WORKTREE:?set the exact installed-candidate root worktree}
g++ -std=c++17 -O2 -o /tmp/plank-sdl3-audio-probe \
  "$root_worktree/probes/client-sdl3-audio-probe.cpp" \
  $(pkg-config --cflags --libs sdl3)
/tmp/plank-sdl3-audio-probe
```

The probe must print `audio_driver=pipewire` and a real output device. This is
a focused transport gate; the real session still needs audible output and A/V
synchronization validation.

For a non-interactive diagnostic screenshot of the Client hardware-test target
under GNOME Wayland, do not retry `gnome-screenshot` over SSH: GNOME rejects
that caller and its X11 fallback cannot see native Wayland surfaces. Capture
and detile the Intel primary scanout through VA-API instead:

```bash
sudo ffmpeg -hide_banner -loglevel error \
  -vaapi_device /dev/dri/renderD128 \
  -f kmsgrab -device /dev/dri/card1 -format x2rgb10le -i - \
  -vf 'hwmap=derive_device=vaapi,scale_vaapi=format=bgra,hwdownload,format=bgra' \
  -frames:v 1 -update 1 -y /tmp/plank-screen.png
```

This captures compositor content, including the toolbar child and any remote
cursor already present in the decoded frame. Intel exposes the real local
pointer on a separate KMS cursor plane, so the primary-plane PNG alone omits
that pointer. Inspect `/sys/kernel/debug/dri/1/state` for the active
`cursor A` plane and its `crtc-pos` only when a diagnostic explicitly needs a
separate cursor-plane capture. Do not use the raw tiled framebuffer download;
without the VA-API map/scale step it produces patterned garbage.

The qualified Qt executable is the NUC's `/usr/bin/qmake6`; do not assume a
home-directory Qt installation. The prepared FFmpeg CLI, when an explicit
version probe is needed, is at
`$PLANK_CLIENT_FFMPEG_WORK/install/bin/ffmpeg` (not
`bin/ffmpeg` directly under the work-directory root). The build scripts consume
the matching `install/include`, `install/lib`, and pkg-config metadata.
The bootstrap may retain the checksum-verified release archive under the
dependency root. Do not redownload FFmpeg during an ordinary candidate build.
Packaging checks
the prepared source's `VERSION` and `RELEASE` identity and requires exactly
9.0.1 before reusing its installed libraries.

The prepared tree's pkg-config metadata must name its current PLANK path. A
directory rename does not relocate the absolute prefix embedded by FFmpeg's
configure/install step; stale metadata silently sends the linker to the OS
FFmpeg and is rejected later by the private-FFmpeg SONAME gate. Check this
before creating the package build directory:

```bash
ffmpeg_work="$PLANK_CLIENT_FFMPEG_WORK"
test "$(PKG_CONFIG_PATH="$ffmpeg_work/install/lib/pkgconfig" \
  pkg-config --variable=prefix libavcodec)" = "$ffmpeg_work/install"
test "$(PKG_CONFIG_PATH="$ffmpeg_work/install/lib/pkgconfig" \
  pkg-config --variable=libdir libavcodec)" = "$ffmpeg_work/install/lib"
```

If either check fails, stop before qmake and repair or regenerate the retained
prepared tree once. Do not let an ordinary candidate fall back to distro
FFmpeg, and do not classify the later SONAME gate as a compiler failure.

The PLANK encoding profile is selected per bookmark. Decoder choice
is not configurable: the client first performs a real test decode through each
available exact-format hardware path, validates the decoded surface's bit
depth and chroma geometry (plus full-range identity metadata for identity GBR),
and then falls back to exact-format FFmpeg software decoding. The package gate
rejects a restored global decoder preference or CLI override and requires the
test-frame validation path. A generic codec-family capability claim is not an
acceptance result, and the client must never change the bookmark profile to
make a decoder probe succeed.

Run the following commands only inside an SSH shell on the Linux Client builder and
make the machine identity the first hard gate. Do not rely on local and remote
paths being different enough to catch a missing SSH wrapper:

```bash
test "$(hostname)" = "${PLANK_EXPECTED_CLIENT_BUILDER:?set the builder hostname in your private environment}"
```

Starting from clean detached root and client worktrees:

Build focused qmake/Qt tests in their own shadow directories outside
`client_build`. The package binary script requires `client_build` to be a new,
nonexistent directory and correctly rejects it if a prior test or ad hoc probe
has populated it. A focused test pass does not make that occupied directory a
valid package build tree; keep the test result and start packaging with a
separate new path.

Initialize every current client submodule before invoking the build. The
current Linux client has two top-level submodules: qmdnsengine and common-c;
common-c has no recursive Linux dependencies. h264bitstream is vendored source,
libsoundio has been removed, and the Windows/macOS prebuilts repository is not
a Linux candidate input. Do not restore the old submodule list from a previous
Moonlight base. `linux-client-builder` retains canonical local repositories for
the current dependencies. Point the candidate worktree at those local
repositories *before* the first submodule update. Import an unpublished
common-c bundle into the canonical common-c repository first. The build
preflight rejects uninitialized or wrong-revision submodules before
qmake starts.

```bash
root_worktree="$PLANK_WORK_ROOT/root-candidate"
client_worktree="$PLANK_WORK_ROOT/client-candidate"
client_build="$PLANK_WORK_ROOT/client-build-candidate"
client_artifacts="$PLANK_WORK_ROOT/client-artifacts-candidate"
ffmpeg_work="$PLANK_CLIENT_FFMPEG_WORK"
canonical_client="$PLANK_CANONICAL_ROOT/apps/client"
kyber_cache="$PLANK_CLIENT_SUBMODULE_CACHE/kyber-kymux.git"

test "$(git -C "$kyber_cache" rev-parse --is-bare-repository)" = true
git -C "$root_worktree" config submodule.third_party/kyber-kymux.url "$kyber_cache"
git -c protocol.file.allow=always -C "$root_worktree" \
  submodule update --init third_party/kyber-kymux
test "$(git -C "$root_worktree/third_party/kyber-kymux" rev-parse HEAD)" = \
  "$(git -C "$root_worktree" rev-parse HEAD:third_party/kyber-kymux)"
for submodule_path in \
  moonlight-common-c/moonlight-common-c \
  qmdnsengine/qmdnsengine; do
  test "$(git -C "$canonical_client/$submodule_path" \
    rev-parse --is-inside-work-tree)" = true
  git -C "$client_worktree" config \
    "submodule.${submodule_path}.url" \
    "$canonical_client/$submodule_path"
done
git -c protocol.file.allow=always -C "$client_worktree" \
  submodule update --init

test -z "$(git -C "$root_worktree" status --porcelain)"
test -z "$(git -C "$client_worktree" status --porcelain)"
test "$(git -C "$root_worktree" rev-parse HEAD:apps/client)" = \
  "$(git -C "$client_worktree" rev-parse HEAD)"

"$root_worktree/scripts/build/build-client-package-binaries.sh" \
  "$client_worktree" "$ffmpeg_work" "$client_build"
"$root_worktree/scripts/package/build-client-deb.sh" \
  "$client_build/app/plank-client" "$ffmpeg_work" \
  "$client_artifacts" "$client_worktree"
```

Use a new, nonexistent build directory for each candidate. Reuse the prepared
FFmpeg work directory. Do not build on the End-User NUC, and do not remotely
install its DEB without explicit user authorization.

A successful `linux-client-builder` package run ends with the uninstalled DEB and all
package-tree gates passing. Do not install it on `linux-client-builder`. Record its
size and SHA-256, and inspect its metadata and manifest before transfer:

On Ubuntu's merged-`/usr` layout, `dpkg-shlibdeps` can warn that the libc6
diversion between `/lib64/ld-linux-x86-64.so.2` and its `.usr-is-merged` path
may affect output. If dependency generation completes and the subsequent
runtime-dependency, private-FFmpeg, RUNPATH, and DEB-manifest gates all pass,
classify those two diversion messages as packaging-tool noise rather than a
build failure.

```bash
source "$root_worktree/scripts/package/package-version.sh"
plank_load_package_version "$root_worktree"
client_deb="$client_artifacts/plank-client_${PLANK_PACKAGE_VERSION}_amd64.deb"
test -f "$client_deb"
client_deb_sha_file="$client_deb.sha256"
(
  cd "$(dirname "$client_deb")"
  sha256sum "$(basename "$client_deb")" > "$(basename "$client_deb_sha_file")"
  sha256sum --check "$(basename "$client_deb_sha_file")"
)
dpkg-deb --info "$client_deb"
dpkg-deb --contents "$client_deb"
```

Transfer that exact DEB and its `.sha256` sidecar to
`client-test-machine`. The
Client is interactive and must not autostart. Its one-time transition from the
old user-service package is complete; do not purge the package during recurring
candidate installs. Install through APT so dependency transitions, including
the conflict between the free and non-free Intel media drivers, are resolved
atomically. Verify the transferred hash before installation, then verify the
embedded version, installed binary hash, private RUNPATH, absence of the
packaged unit, and inactive legacy service:

```bash
client_deb=${PLANK_CLIENT_DEB:?set the transferred DEB path}
client_deb_sha_file="$client_deb.sha256"
test -f "$client_deb" && test -f "$client_deb_sha_file"
(
  cd "$(dirname "$client_deb")"
  sha256sum --check "$(basename "$client_deb_sha_file")"
)

sudo apt-get install -y "$client_deb"
QT_QPA_PLATFORM=offscreen \
env -u LD_LIBRARY_PATH /usr/bin/plank-client --version
sha256sum /usr/bin/plank-client
readelf -d /usr/bin/plank-client | grep -F '$ORIGIN/../lib/plank'
systemctl --user daemon-reload
test ! -e /usr/lib/systemd/user/plank-client.service
if systemctl --user is-active --quiet plank-client.service; then
  echo "legacy PLANK client service remains active" >&2
  exit 1
fi
if systemctl --user is-enabled --quiet plank-client.service 2>/dev/null; then
  echo "legacy PLANK client service remains enabled" >&2
  exit 1
fi
```

Automated candidate installation is allowed only on `client-test-machine`.
End-User NUCs remain clean manual-install/test targets.

After the candidate is accepted, its DEB and SHA-256 are retained in the root
repository's `artifacts/packages/`, and dependency-first pushes are verified,
remove its `linux-client-builder` build state. Deinitialize the submodules in the
exact client worktree, remove that registered client worktree and the exact
root worktree, then remove the exact build, package, and copied-bundle paths.
Prune both canonical worktree registries afterward. Never use a wildcard or a
broad home-directory target for cleanup.

```bash
client_worktree="$PLANK_WORK_ROOT/client-candidate"
root_worktree="$PLANK_WORK_ROOT/root-candidate"
git -C "$client_worktree" submodule deinit -f -- \
  moonlight-common-c/moonlight-common-c qmdnsengine/qmdnsengine
git -C "$PLANK_CANONICAL_ROOT/apps/client" \
  worktree remove --force "$client_worktree"
git -C "$root_worktree" submodule deinit -f -- third_party/kyber-kymux
git -C "$PLANK_CANONICAL_ROOT" worktree remove --force "$root_worktree"
git -C "$PLANK_CANONICAL_ROOT/apps/client" worktree prune
git -C "$PLANK_CANONICAL_ROOT" worktree prune

for candidate_path in \
  "$PLANK_WORK_ROOT/cargo-preflight-candidate" \
  "$PLANK_WORK_ROOT/client-build-candidate" \
  "$PLANK_WORK_ROOT/client-artifacts-candidate" \
  "$PLANK_WORK_ROOT/candidate-bundles"; do
  case $candidate_path in
    "$PLANK_WORK_ROOT"/*) ;;
    *) echo "refusing cleanup outside PLANK_WORK_ROOT" >&2; exit 1 ;;
  esac
  if [[ -e $candidate_path ]]; then
    find "$candidate_path" -depth -delete
  fi
done
```

Remove exact candidate-specific logs by the same guarded pattern.

The steady-state `linux-client-builder` state is defined by its path manifest and should
contain only these persistent classes:

```text
$PLANK_CANONICAL_ROOT
$PLANK_CLIENT_FFMPEG_WORK
$PLANK_CLIENT_SUBMODULE_CACHE
$PLANK_RUSTUP_ROOT
$PLANK_CARGO_ROOT
```

Create candidate worktrees, builds, artifact staging, preflight outputs, and
bundles only beneath `$PLANK_WORK_ROOT`, and remove their exact paths after
acceptance. Never use runtime settings or logs from a test Client as build
inputs.

Host-aware bookmark candidates run the `outputtopology` and `hostchoices`
Qt tests as part of package preflight. The former uses `PLANK_REPO_ROOT` for
protocol fixtures; the latter uses `PLANK_CLIENT_SOURCE` for the actual shared
QML chooser. Headless QML tests use offscreen/software rendering. These gates
cover capability filtering and native-pixel Mac matching, not hardware display
or input acceptance.

The client package gates also enforce absence of the removed workstation
details dump and legacy local Wake-on-LAN path. Packed BT.709 candidates also
run the exact tuple policy and actual EGL shader pixel tests offscreen on
linux-client-builder. This software-GL build gate does not replace Intel VA-API hardware
decode/import and live playback acceptance; see
`docs/architecture/vaapi-bt709-presentation.md`.

## Host RPM — linux-host-builder only

Host packaging selects `PLANK_TRANSPORT_CARGO_FEATURES=quinn-telemetry` by
default. The application datagram pacer and platform-specific fast-send switches
have been removed. All builds use the same 1 Gbps floor for the Host's
RTT-bounded Quinn window budget; encoder target, FEC, queues and MTU remain
independent. Quinn still schedules packets. There is no paced comparison build
to select, and the package always verifies its sender-budget marker.
The historical experiment is retained in `docs/development/plans/linux-fast-send.plan`;
do not reuse its removed feature flags. The simultaneous RaptorQ 2 upgrade
requires matching Host/Client builds; do not apply the old host-only deployment
assumption to that wire change.

Host packaging runs Rust unit tests and the real native/C ABI loopbacks against
its selected Cargo features in the same `plank-transport-cargo` target directory.
Packaging requires Rust unit tests, all three
native loss matrices with unchanged recovery/performance limits, and the C ABI
checks. A failure in the shipping policy stops packaging. No retired pacer
implementation or comparison selection remains.
Standalone loopback runners also accept `PLANK_TRANSPORT_CARGO_FEATURES`; an
unset value exercises default Cargo features with the same sender policy,
without the optional telemetry/source-first instrumentation.
The loss fixture uses controlled receiver-side omissions, not a real WAN.
Do not report its results as ten-minute or interactive hardware qualification.

`209/STDOUT` with `Failed to set up standard output: No such file or directory`
can mean `/var/log/plank` is missing, even when the unit has `LogsDirectory=plank`.
systemd 252 opens `StandardOutput=append:` before creating managed directories.
The Host RPM must install and own `/var/log/plank` as `root:root` mode `0700`;
`host_rpm_log_directory_gate=pass` verifies the finished RPM metadata. Do not
rely on an existing test machine's log directory to qualify a fresh install.
An `ExecStartPre=mkdir` in the same unit cannot repair this ordering, because
its standard output is set up first too.

To recover an affected installed Host, create that exact directory with
`sudo install -d -o root -g root -m 0700 /var/log/plank`, reset the failed Host
and PAM units, and start them. Do not restart GDM or reboot automatically.
Display preparation is a boot-layout operation; inspect current session state
before running it outside boot.

Build from a clean root worktree, build directory, and artifact directory under
`$PLANK_WORK_ROOT` on `linux-host-builder`; all of those paths must be local storage.
Give each build a private temporary directory inside its local build tree and
export it as `TMPDIR`; GCC otherwise places large assembler intermediates in
the shared `/tmp` namespace, where unrelated cleanup can invalidate a running
build. The package script defaults to eight jobs, and the current `linux-host-builder`
qualification uses eight. Keep the complete CUDA architecture set; do not
trade future hardware coverage for a shorter candidate build.

Reuse the prepared, Git-ignored Sunshine FFmpeg tree and the persistent,
root-owned local Boost 1.89.0 source at `$PLANK_HOST_BOOST_ROOT`. Both are
recreated once by `docs/development/build/builder-vm-bootstrap.md` and verified before reuse; do
not copy them from an old builder, compile from NFS, or make an ordinary clean
candidate download them again. A build spending many minutes with compiler
tasks in uninterruptible I/O indicates that one of those paths is not local.
The Host package preflight independently reverse-checks every tracked active
build-deps patch against the generated source at `$PLANK_HOST_FFMPEG_BUILD`.
Missing, partly applied, or source-incompatible patches are package-stopping
errors; installed static libraries alone are not sufficient provenance.

The PLANK native transport also uses the builder-retained Rust 1.89.0
toolchain and Cargo cache. Export them before configuration so CMake records a
stable Cargo path rather than a disposable `/tmp` shim:

```bash
export RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export CARGO_HOME="$PLANK_CARGO_ROOT"
export PATH="$CARGO_HOME/bin:$PATH"
test "$(rustc --version)" = "rustc 1.89.0 (29483883e 2025-08-04)"
test "$(cargo --version)" = "cargo 1.89.0 (c24e10642 2025-06-23)"
```

The host package script pins both `CMAKE_CXX_COMPILER` and
`CMAKE_CUDA_HOST_COMPILER` to GCC Toolset 14. Do not remove the CUDA host pin:
otherwise NVCC can auto-detect the Rocky system GCC 11 toolchain, add its
implicit library directory ahead of GCC 14, and make `-static-libstdc++` select
the incompatible GCC 11 archive at final link. Missing
`std::__cxx11::basic_string::_M_replace_cold` or `_Float128` `std::to_chars`
symbols are this compiler/library mismatch, not a source-code failure.

Standalone PAM descriptor tests must also use the Host's **C++23** language
mode. A `std::byteswap` error with GCC 14 can mean the test command still uses
`-std=c++20`; changing compiler versions or removing the test is not the fix.
The root CI policy checks this command against the PAM CMake suite's standard.

Do not validate a changed Host branch by directly rebuilding a canonical Host
build directory after switching branches. CMake's glob check can reconfigure
that directory without the root package script's PLANK transport include
path, producing a misleading `plank_transport.h: No such file or
directory` error. Use the clean root worktree and `build-host-rpm.sh` sequence
below; it supplies and validates the synchronized transport source explicitly.

Boost 1.89 exports its header-only target as `Boost::headers`, while the
retained Simple-Web-Server revision still requests the established
`Boost::boost` name. `cmake/dependencies/Boost_Sunshine.cmake` deliberately
provides that compatibility target after loading the prepared Boost source. A
CMake generation error saying that `simple-web-server` contains a missing
`Boost::boost` target means the candidate predates that integration fix; do
not redownload Boost or reuse an older configured build directory.

The `operator` account on `hardware-test-host` uses a C-shell login environment. When deploying
or validating there, invoke `/bin/bash -s` explicitly and send the script to
that shell. Do not pass Bash constructs such
as `set -euo pipefail`, `$(...)`, or Bash-style redirections directly to the
login shell. `Illegal variable name`, `Unmatched '"'`, or `Ambiguous output
redirect` from that wrapper means the intended command did not run; it is not
a build, package, or service failure.

The host package gates use ripgrep. Verify it before creating a candidate so a
missing search tool is not misclassified as a source or compiler failure:

```bash
command -v rg
```

On a newly prepared `linux-host-builder`, install EPEL and `ripgrep` once if that check
fails; do not reinstall it for every candidate.

This is a host-only build. Never run `git submodule update --init --recursive`
from the root candidate: it initializes the unrelated client and attempts a
remote fetch before a local unpublished host commit has been seeded. Record the
root gitlink first, make and verify a host bundle, populate the host submodule
from that bundle, and recursively initialize from inside the host only:

```bash
source_root="$PLANK_CANONICAL_ROOT"
root_commit=$(git -C "$source_root" rev-parse HEAD)
host_commit=$(git -C "$source_root" rev-parse HEAD:apps/host/linux)
root_worktree="$PLANK_WORK_ROOT/root-candidate"
host_bundle="$PLANK_WORK_ROOT/host-candidate.bundle"
host_bundle_ref=refs/heads/main
if ! git -C "$source_root/apps/host/linux" \
  show-ref --verify --quiet "$host_bundle_ref"; then
  host_bundle_ref=refs/remotes/origin/main
fi
test "$(git -C "$source_root/apps/host/linux" \
  rev-parse "$host_bundle_ref")" = "$host_commit"

git -C "$source_root/apps/host/linux" bundle create \
  "$host_bundle" "$host_bundle_ref"
sha256sum "$host_bundle"
git -C "$source_root/apps/host/linux" bundle verify "$host_bundle"

git -C "$source_root" worktree add --detach "$root_worktree" "$root_commit"
git -C "$root_worktree" config submodule.third_party/kyber-kymux.url \
  "$source_root/third_party/kyber-kymux"
git -c protocol.file.allow=always -C "$root_worktree" \
  submodule update --init third_party/kyber-kymux
test "$(git -C "$root_worktree/third_party/kyber-kymux" rev-parse HEAD)" = \
  "$(git -C "$root_worktree" rev-parse HEAD:third_party/kyber-kymux)"
git init "$root_worktree/apps/host/linux"
git -C "$root_worktree/apps/host/linux" fetch \
  --recurse-submodules=no "$host_bundle" \
  "$host_bundle_ref:refs/plank/candidate/host"
test "$(git -C "$root_worktree/apps/host/linux" \
  rev-parse refs/plank/candidate/host)" = "$host_commit"
git -C "$root_worktree/apps/host/linux" checkout --detach "$host_commit"
git -C "$root_worktree" submodule absorbgitdirs apps/host/linux
"$source_root/scripts/build/init-host-candidate-submodules.sh" \
  "$source_root/apps/host/linux" \
  "$root_worktree/apps/host/linux"

mkdir -p "$root_worktree/apps/host/linux/cmake-build-ffmpeg-x264rgb-install"
ln -s \
  "$PLANK_HOST_FFMPEG_ROOT" \
  "$root_worktree/apps/host/linux/cmake-build-ffmpeg-x264rgb-install/ffmpeg"

test -z "$(git -C "$root_worktree" status --porcelain)"
test "$(git -C "$root_worktree" rev-parse HEAD:apps/host/linux)" = \
  "$(git -C "$root_worktree/apps/host/linux" rev-parse HEAD)"
```

The local seeding script recursively maps each candidate dependency to the
corresponding initialized repository under the canonical host checkout. It
preserves a clean worktree and exact gitlinks without downloading all recursive
repositories again. If it reports that a canonical dependency is unavailable,
repair or initialize that one canonical dependency first; do not silently fall
back to a full network clone during an ordinary candidate build.

A fresh recursive clone normally has only the Host's
`refs/remotes/origin/main` ref, while an authoring checkout may also have
`refs/heads/main`. The explicit `host_bundle_ref` selection supports both
without creating a branch. Do not replace the `git init` plus exact-ref fetch
with `git clone <bundle>`: Git treats a bundle containing only a remote-tracking
ref as having no cloneable branch and can create an empty repository even
though the bundle contains the correct complete history.

The canonical repository and `$PLANK_WORK_ROOT` are both local on `linux-host-builder`, so
`git submodule absorbgitdirs` must not cross filesystems. An `EXDEV` error now
means the path manifest or mount layout is wrong; stop and fix it rather than
adding an archive or standalone-clone workaround.

Use new candidate, build, artifact, and bundle paths for every release. If the
host commit is already published, a host-only submodule update of
`apps/host/linux` may replace the bundle clone; still initialize recursive
dependencies from inside the host rather than from the root.

The Host application and RPM `Version` retain the exact shared product
version. RPM requires a separate `Release` value, so the first package of a
PLANK version uses release `1` (for example,
`plank-host-1.0.0-1.el9.x86_64.rpm`). Increment the RPM release only to
repackage the exact same PLANK source; normal builds advance
`packaging/VERSION` and return the packaging release to `1`. The RPM release is
not displayed as part of the PLANK application version.

```bash
root_worktree="$PLANK_WORK_ROOT/root-candidate"
host_build="$PLANK_WORK_ROOT/host-build-candidate"
host_artifacts="$PLANK_WORK_ROOT/host-artifacts-candidate"
host_tmp="$host_build/tmp"
boost_source="$PLANK_HOST_BOOST_ROOT"

test -z "$(git -C "$root_worktree" status --porcelain)"
test -f "$boost_source/CMakeLists.txt"
rg -Fxq 'project(Boost VERSION 1.89.0 LANGUAGES CXX)' \
  "$boost_source/CMakeLists.txt"
mkdir -p "$host_tmp"
TMPDIR="$host_tmp" \
PLANK_BUILD_JOBS=8 \
PLANK_BOOST_SOURCE_DIR="$boost_source" \
  "$root_worktree/scripts/package/build-host-rpm.sh" "$host_build" "$host_artifacts"

mapfile -t host_rpms < <(
  find "$host_artifacts" -maxdepth 1 -type f \
    -name 'plank-host-*.x86_64.rpm' -print
)
test "${#host_rpms[@]}" -eq 1
host_rpm=${host_rpms[0]}
host_rpm_sha_file="$host_rpm.sha256"
(
  cd "$(dirname "$host_rpm")"
  sha256sum "$(basename "$host_rpm")" > "$(basename "$host_rpm_sha_file")"
  sha256sum --check "$(basename "$host_rpm_sha_file")"
)
```

Do not install the RPM on `linux-host-builder`. Transfer the exact RPM and its SHA-256 to
`hardware-test-host`. After installing it there, reload systemd and restart the actual
packaged units. `plank-host-supervisor` is the executable run by
`plank-host.service`; there is no separate
`plank-host-supervisor.service` unit.

```bash
host_rpm=${PLANK_HOST_RPM:?set the transferred RPM path}
host_rpm_sha_file="$host_rpm.sha256"
test -f "$host_rpm" && test -f "$host_rpm_sha_file"
(
  cd "$(dirname "$host_rpm")"
  sha256sum --check "$(basename "$host_rpm_sha_file")"
)
sudo dnf install -y "$host_rpm"
sudo systemctl daemon-reload
sudo systemctl restart plank-pam-broker.service plank-host.service
systemctl is-active plank-pam-broker.service plank-host.service
```

Do not restart `plank-display-prepare.service` as part of a routine live
package upgrade. It is a boot-layout operation, not a media-worker reload;
leave its hardware qualification to a separately authorized maintenance/boot
test after inspecting the current desktop state. Never restart GDM here.

Use eight jobs as the qualified `linux-host-builder` baseline. Override it only with a
positive measured value and record the result; never compensate for pressure
by reusing a dirty build tree or narrowing the CUDA architecture list.

Do not treat an RPM as valid merely because `rpmbuild` produced it. The
packaging script must pass the runtime, manifest, single-configuration-file,
mDNS-default-off, and Web-UI-absence gates. The binary must not contain the
configuration HTTP server, and the RPM must not contain `/web/` assets or the
legacy `/etc/plank/host.env`. Copy only that gated artifact to
`artifacts/packages/`.

Validate an uninstalled candidate's absolute systemd executable paths against
the RPM manifest and extracted RPM payload, not against a hardware target's
currently installed root. Running `systemd-analyze verify` directly on candidate unit
files still resolves absolute `ExecStart` paths such as
`/usr/libexec/plank/plank-host-supervisor` against hardware-test-host's
live installation. It will therefore report a false missing-command failure
when the new candidate moves a binary that the older installed package does not
contain. The RPM builder's manifest gates are authoritative before install;
also extract with `rpm2cpio | cpio -idm`, require the referenced payload files
to be executable, and compare each unit's `ExecStart` to those exact paths.
Use live-root `systemd-analyze verify`, `systemctl daemon-reload`, and service
status checks only after installing the candidate. A `--root` verification is
valid only with a complete staged OS root, not an RPM-only extraction missing
the base system units and libraries.

The binary build also prints `host_gamepad_absence_gate=pass`. This gate keeps
controller packet dispatch, feedback routing, Linux virtual-gamepad bindings,
controller configuration, and gamepad-specific tests out of the PLANK
Linux host. Do not remove the shared `libvirtualhid` dependency: its keyboard,
mouse, and pen devices are still required. Generic gamepad code retained
inside that third-party dependency and dormant non-Linux upstream backends is
outside the Linux host product path.

The same build prints `host_remote_control_absence_gate=pass` and
`host_touchscreen_absence_gate=pass`. These keep client-controlled physical
display changes, remote application cancellation, generic direct-touch packet
routing, virtual touchscreen creation, and the obsolete combined pen/touch
configuration out of the Linux product. The normalized pen-tablet fallback
and raw-HID Wacom forwarding remain required; physical Wacom touch interfaces
forwarded within the raw HID device are not generic direct-touchscreen input.

The build also prints `host_raw_hid_fallback_exclusion_gate=pass`. This keeps
the normalized pen-tablet fallback mutually exclusive with an attached exact
raw-HID Wacom group. Raw focus/transport suspension retains exact ownership;
explicit detach or failed raw attachment restores the fallback. This gate is
model-independent and must not be replaced with Wacom product-ID, geometry, or
margin-value tables.

The build also prints `host_wake_on_lan_absence_gate=pass` and
`host_pc_color_range_gate=pass`. The first keeps host MAC lookup and serverinfo
MAC publication out of the product. The second requires FFmpeg's public
`"pc"`/`"tv"` name mapping and `PC`/`TV` log terminology. Internally FFmpeg
still represents `"pc"` with the historical `AVCOL_RANGE_JPEG` enum; do not
confuse that enum name with the administrator-facing value or log text.

The build also prints `host_upnp_absence_gate=pass` and
`host_rpm_upnp_absence_gate=pass`. PLANK has no
UPnP/NAT-traversal product path: the inherited router discovery, IPv4 port
mapping, IPv6 pinhole, configuration/CLI toggles, and miniupnpc dependency are
removed. The RPM gate additionally checks generated requirements, payload
paths, and the host ELF linkage. Routing and firewall policy are
administrator-managed; do not restore the dormant Sunshine implementation or
merely hide its preference.

The build also prints `host_legacy_network_probe_absence_gate=pass`. The
Host-specific common-c header remains an active source of protocol constants
and input structures, but its inherited `SimpleStun.c`,
`ConnectionTester.c`, WAN-address lookup, GameStream port tables, and generic
connectivity-test APIs are not PLANK capabilities. The gate requires
those sources and declarations to remain absent. Do not confuse this cleanup
with removal of the active `Limelight.h` protocol types.

`host_protocol_headers_only_gate=pass` additionally requires that the Host's
common-C dependency contain only `Input.h`, `Limelight.h` and `plank.h` under
`src/`, with a header-only CMake target. It has no recursive dependencies,
compiled library, ENet or nanors. Initialize this exact Host header branch,
not the Client implementation branch or an old upstream library checkout.
The preflight tests reject restored dependencies and compile the retained
headers as both C and C++. Historical builds are not a maintenance requirement.

The build also prints `host_auth_group_absence_gate=pass`. The branded PAM
service is `/etc/pam.d/plank-host`; the broker defaults
`security.allow_root_login` to false and delegates account authorization to the
host's PAM/SSSD policy, including FreeIPA HBAC. Enabling root does not bypass
active-desktop ownership. The root supervisor is the broker's only connector;
the media worker obtains connected sockets through its private inherited
descriptor channel rather than opening the broker path. Keep the broker
directory/socket and TLS private key remain `root:root` with modes
`0700`/`0600`. Do not restore the obsolete service-access group, sysusers
payload, or an application-specific human-user allowlist.

Host privilege-separation candidates also require the standalone
`pam-broker-channel-test`. Its regular run tests malformed and truncated
messages, descriptor cleanup, close-on-exec and peer rejection. On the hardware
target, a root invocation additionally forks a `nobody` child with no
supplementary groups and no-new-privileges, then proves the connected descriptor
works after dropping identity. It uses synthetic sockets only, never real PAM
credentials or a production broker. A reported root-probe skip is not a passed
privilege-drop test. PAM descriptor delegation is only the first stage; do not
describe the Host worker as unprivileged until runtime UID/capability and all
remaining resource gates pass.

Validate the PAM CMake suite with `RelWithDebInfo`, matching the package gate,
not only Debug or sanitizer builds. GCC 14's optimized bounds/uninitialized
diagnostics can expose issues that Debug does not compile-diagnose; keep
`-Werror` enabled and fix the source/test rather than weakening the gate.

The `host_x11_worker_exit_gate=pass` preflight exercises the fatal Xlib I/O
callback in a child thread, verifying immediate worker exit without C++/NVIDIA
exit handlers, descriptor closure and parent survival. This does not replace
live desktop logout qualification: verify that the supervisor starts a fresh
worker without the ten-second shutdown watchdog, closes PAM sessions and
restores display/input ownership. A fatal X connection is not an ordinary X
protocol error or a normal stream disconnect; those retain normal cleanup.

The `host_worker_control_eof_gate=pass` preflight uses real local record sockets
to verify idle reads, oversized-record rejection, final queued records, EOF
and permanent errors. EOF must retire the descriptor instead of generating
malformed-message logs or spinning in poll. Live logout must still reap the
worker and recover the display lease, without false malformed-request output.

The `host_encoder_probe_order_gate=pass` source gate requires codec/backend
eligibility checks before capture acquisition, while retaining actual supported
profile test encodes. It is not hardware qualification: compare advertised
profile support and real startup probe results on the NVIDIA target, and time
GDM-to-desktop login separately from logout. Do not skip exact-format validation
or reuse graphics handles across X-server generations to shorten startup.

The build also prints `host_wacom_udev_identity_gate=pass` and the RPM prints
`host_rpm_wacom_udev_identity_gate=pass`. The host rule is named
`70-plank-host-wacom.rules`, distinct from the client capture rule.
It grants active-session access to mirrored Wacom input/hidraw interfaces and
to `/dev/uhid`; do not restore the ambiguous pre-`.170` filename or merge the
host and client rule payloads.

Client lifecycle candidates require the `desktopstage` Qt tests and
`tests/packaging/test-client-reconnect-status.py`, both run by the Client
package preflight. They check authenticated greeter interpretation, video-
silence boundaries, certificate-pinned worker replacement, duplicate reconnect
requests, and frame-independent local status presentation. For live acceptance,
verify both login and logout with matching Host/Client packages: record last
old-worker video, replacement Host readiness, replacement detection and first
new frame. A normal network timeout or same-worker response must not trigger
early teardown. HTTPS worker probes carry no credentials, never run during
normal video flow and must not shorten the configured Wait/Disconnect policy.
These unit/source gates do not substitute for the user's visual test.

The build also prints `host_fixed_desktop_reservation_gate=pass` and
`host_rpm_fixed_desktop_gate=pass`. PLANK has one internal,
process-less Desktop identity with stable GameStream application ID
`881448767`; it does not load an application catalog. Do not restore
`apps.json`, `file_apps`, per-application or global preparation commands,
Steam/Low-Res launch entries, mutable box art, an application-art HTTP
endpoint, or the Linux arbitrary-command launcher. Launch/resume state remains
an in-memory Desktop reservation with the existing retained-input and display
cleanup hooks.

The build also prints `host_legacy_http_surface_absence_gate=pass` and
`host_secure_credential_write_gate=pass`. The host has no remote-file
downloader and therefore no libcurl dependency. First-run TLS credentials are
created only at their configured private location; private keys are opened
with symlink rejection and mode `0600` from creation rather than being written
with broad process defaults and tightened afterward. Do not restore the former
shared-temporary credential path.

The build also prints `host_legacy_x11_capture_absence_gate=pass`. This keeps
Sunshine's dormant generic `XGetImage` and generic MIT-SHM framebuffer readers
out of the first-party host, including their former world-accessible SysV SHM
mode and silent configured-source X11 fallback. Do not interpret this as
removing X11 support: XRandR discovery, XFixes cursor transport, and the
experimental Native X11/XShm depth-30 backend remain. Native capture must keep
its owner-restricted `0600` segment, checked XCB attach, and immediate
`IPC_RMID`; Linux CUDA startup probes must select NvFBC explicitly.
Its x264 mode must also retain the direct packed-RGB10-to-planar-GBR10 path,
the one-pass center-aligned scaler for differing encode sizes, and the strict
High 4:4:4 Predictive 10-bit identity SPS capability gate.

When `BUILD_TESTS=ON`, Sunshine currently builds `tests/test_sunshine` but does
not register it with CTest. `ctest` therefore reports `No tests were found`.
Run the binary directly. linux-host-builder has no GPU or `/dev/uhid`: exclude the two
CUDA execution tests there and accept the raw-HID endpoint tests only as
explicit skips. Run the CUDA tests on hardware-test-host as part of hardware qualification.
Other hardware-dependent audio/input/video fixtures can report platform
initialization failures over a non-graphical build shell; record those
separately and run this build-only-safe focused set:

```bash
ffmpeg_dir=$(sed -n \
  's/^FFMPEG_PREPARED_BINARIES:[^=]*=//p' \
  "$host_build/CMakeCache.txt")
test -f "$ffmpeg_dir/include/libavutil/pixfmt.h"
test -f "$ffmpeg_dir/lib/libavcodec.a"
package_version=$(<"$root_worktree/packaging/VERSION")
host_source_commit=$(git -C "$root_worktree/apps/host/linux" rev-parse HEAD)
env \
  BRANCH=plank-package \
  BUILD_VERSION="$package_version" \
  COMMIT="$host_source_commit" \
  cmake -S "$root_worktree/apps/host/linux" -B "$host_build" \
    -DFFMPEG_PREPARED_BINARIES="$ffmpeg_dir" \
    -DBUILD_TESTS=ON
cmake --build "$host_build" --parallel 8 --target test_sunshine

(
  cd "$root_worktree/apps/host/linux"
  build_only_filter='VideoColorspaceTest.*:InputConfigDefaults.*:'
  build_only_filter+='InputRetainedSessionTest.*:RawHidTablet.*:RawHidContactIo.*:'
  build_only_filter+='ConfigConsistencyTest.*-'
  build_only_filter+='VideoColorspaceTest.IdentityGbrCudaKernelProducesExact8BitPlanes:'
  build_only_filter+='VideoColorspaceTest.IdentityGbrCudaKernelProducesExact10BitPlanes'
  "$host_build/tests/test_sunshine" --gtest_color=no \
    --gtest_filter="$build_only_filter"
)
```

Run the binary from the Host source directory as shown. The configuration
consistency fixtures intentionally inspect `src/config.cpp` by repository-
relative path; launching the binary from another directory produces a false
empty-runtime failure with `Missing file: src/config.cpp`.

On hardware-test-host, run the two excluded tests from the exact same candidate build:

```bash
(
  cd "$root_worktree/apps/host/linux"
  cuda_filter='VideoColorspaceTest.IdentityGbrCudaKernelProducesExact8BitPlanes:'
  cuda_filter+='VideoColorspaceTest.IdentityGbrCudaKernelProducesExact10BitPlanes'
  "$host_build/tests/test_sunshine" --gtest_color=no \
    --gtest_filter="$cuda_filter"
)
```

The clean host-only candidate deliberately does not initialize the client
submodule. Do not run repository-root qualification or accumulated root
packaging tests such as `tests/packaging/test-host-supervisor-package.sh` from
that worktree: despite its historical name, that script also asserts client
session and input source. Use the host build/RPM gates and focused host binary
tests there. Run mixed-tree and hardware tests on `hardware-test-host` from a complete,
clean checkout at the exact root commit used by `linux-host-builder`.
The cross-tree protocol tests validate the client's exact
`Limelight.h`, `plank.h`, and packet-loss window implementation.
Pull a pushed commit or seed verified dependency-first bundles; do not copy a
source archive and do not compile the RPM on `hardware-test-host`. Keep the qualification
build directory on `hardware-test-host` local storage:

```bash
qualification_root=${PLANK_QUALIFICATION_ROOT:?set the exact clean root worktree}
qualification_build=/tmp/plank-root-qualification
qualification_report=/tmp/plank-host-qualification-report.md
nvfbc_include="$PLANK_NVFBC_SDK_ROOT/NvFBC/inc"

test -f "$nvfbc_include/NvFBC.h"
cmake -S "$qualification_root" -B "$qualification_build" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DNVFBC_INCLUDE_DIR="$nvfbc_include"
cmake --build "$qualification_build" --parallel 8
ctest --test-dir "$qualification_build" --output-on-failure
(
  cd "$qualification_root"
  PLANK_BUILD_DIR="$qualification_build" \
    ./scripts/test/run-host-qualification.sh "$qualification_report"
)
```

The qualification probes require the retained NVIDIA Capture SDK 9 header at
that exact path. Do not point them at
`apps/host/linux/third-party/nvfbc/NvFBC.h`: that inherited NvFBC 1.7 header
lacks the X11-backend and cursor-composition fields used by the current probes.
A compile failure mentioning missing `eBackend`, `NVFBC_BACKEND_X11`, or
`bCursorComposited` is an SDK-input mismatch, not a PLANK source or
package failure.

The root CMake configuration checks these client inputs up front and emits a
specific fatal error when the wrong source tree is used. Do not work around
that guard by recursively initializing the client inside a host candidate.

Reconfigure the already-gated production build as shown so its compilers,
feature flags, Boost source, and exact candidate FFmpeg link remain in the
CMake cache. Do not substitute a guessed `third-party/ffmpeg-*` path: the host
candidate's retained FFmpeg input is the linked
`cmake-build-ffmpeg-x264rgb-install/ffmpeg` tree, and a wrong directory can be
accepted at configure time but fail later when test-only targets compile.

The Codecov Vite plugin may emit three `400 - Bad Request` telemetry retries on
a local build. If Vite subsequently says `built`, the web target completes, and
all package gates pass, classify that message as non-build telemetry noise.

After an accepted Host package and its qualification evidence have been copied
to their retained locations, retire the exact Host candidate. Deinitialize only
the two submodules initialized for the Host-only root worktree; do not use
`submodule deinit --all`, because the deliberately uninitialized Client gitlink
has no worktree configuration to remove:

```bash
root_worktree="$PLANK_WORK_ROOT/root-candidate"
git -C "$root_worktree" submodule deinit -f -- \
  third_party/kyber-kymux apps/host/linux
git -C "$PLANK_CANONICAL_ROOT" worktree remove --force "$root_worktree"
git -C "$PLANK_CANONICAL_ROOT" worktree prune

for candidate_path in \
  "$PLANK_WORK_ROOT/host-build-candidate" \
  "$PLANK_WORK_ROOT/host-artifacts-candidate" \
  "$PLANK_WORK_ROOT/host-candidate.bundle"; do
  case $candidate_path in
    "$PLANK_WORK_ROOT"/*) ;;
    *) echo "refusing cleanup outside PLANK_WORK_ROOT" >&2; exit 1 ;;
  esac
  if [[ -e $candidate_path ]]; then
    find "$candidate_path" -depth -delete
  fi
done
```

Remove exact candidate-specific sidecars and logs by the same guarded pattern.
Never remove the canonical clone, prepared dependencies, accepted packages, or
retained qualification reports during candidate cleanup.

## Release recording

Keep the Client's bundled `apps/client/app/res/changelog.md` current. Use short,
plain-language bullets under separate Client and Host headings for each version;
omit empty sections. The current candidate's notes may use "This build" until
the release version is final. When releasing, name that section with the final
version and preserve prior release summaries. These are user-facing highlights,
not a Git log or a validation report. Do not list unmerged fixes or promise
unqualified hardware support. The version-button dialog uses this bundled file
offline; both Client build gates exercise its modal, keyboard and scrolling UI.

For macOS PKG signing, keep the authenticated interactive SSH session open
from `security unlock-keychain` through `build-macos-host-pkg.sh`; enter the
keychain password only at its hidden prompt. On the dedicated Mac, unlocking
in a short-lived SSH session and signing in another produced
`errSecInternalComponent`, while signing within the still-open unlocked
session succeeded. This is a signing-session failure, not a compiler failure.
Do not change the signing identity, key access policy, TCC grants, or global
keychain timeout to work around it. Preserve the failed output separately and
use the canonical package script with a new output directory.

Record exact root and recursive-submodule commits, bundle hashes, worktree and
artifact paths, package size and SHA-256, toolchain versions, and every passed
or failed gate in `HANDOFF.md`. Push dependency repositories before parent
gitlinks and create release tags only after the final package gates pass.
