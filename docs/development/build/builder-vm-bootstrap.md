# PLANK Builder VM Bootstrap

This document reconstructs the qualified PLANK build inputs on clean builder
VMs. It complements `release-build-runbook.md`: this document prepares a
canonical builder once; the release runbook creates a clean worktree for every
candidate.

Do not copy an old build directory, dependency tree, Cargo cache, or source
working tree to a replacement VM. Recreate each from its pinned source and
verify it. `linux-host-builder` and `linux-client-builder` are the canonical package builders.
`hardware-test-host` and `client-test-machine` are hardware-test/install targets and
must not be used as fallback package builders.

## Builder roles

- Host builder: `linux-host-builder`, Rocky Linux 9.7, x86-64, GCC Toolset 14, CUDA 13,
  RPM tooling, and local build storage. It is build-only and has no GPU.
- Client builder: `linux-client-builder` (`192.0.2.42`), Ubuntu Desktop 26.04,
  x86-64, Qt 6.10.2, SDL3, SDL3_ttf, PipeWire development files, and the
  Intel/Wayland client stack. It is build-only; its virtual display and Dummy
  Output are not product qualification devices.
- Host hardware target: `hardware-test-host`, including licensed NvFBC headers, NVIDIA GPU,
  real desktop, audio, and input devices.
- Client hardware target: `client-test-machine`, including the qualified
  Intel/Wayland presentation and Wacom environment.
- End-User NUCs remain manual-install test targets. Never build on them.

## Path contract

Repository relocation does not move every embedded dependency path. For an
existing builder, inspect its manifest before switching to the new layout.
The Linux Host's prepared FFmpeg moves with the Host submodule; update the
two `PLANK_HOST_FFMPEG_*` paths. Generated dependency `.git` files and `.pc`
prefixes may still name the former location. Correct their path metadata
only, retaining library bytes and patched source, then run the independent
eight-patch/source gate. Do not reuse an old configured CMake product build.
Fresh candidate worktrees are the validation of the new path contract.

When a canonical clone is still on the pre-layout main branch, read each
submodule's working path with `git config -f .gitmodules submodule.NAME.path`
before importing bundles. Import into that actual existing repository; create
the new-layout candidate as a separate worktree. Do not copy it into another
ad hoc canonical clone or delete its retained dependencies to force a move.

Paths are machine configuration, not repository constants. Both current
builders use the following local-storage contract in
`~/.config/plank-builder/paths.env`:

```bash
export PLANK_CANONICAL_ROOT=~/dev/plank
export PLANK_SOURCE_ROOT=~/dev/plank
export PLANK_DEP_ROOT=~/.cache/plank-build
export PLANK_WORK_ROOT="$PLANK_DEP_ROOT/work"
export PLANK_PACKAGE_ROOT="$PLANK_CANONICAL_ROOT/artifacts/packages"
export PLANK_RUSTUP_ROOT="$PLANK_DEP_ROOT/rustup-1.89.0"
export PLANK_CARGO_ROOT="$PLANK_DEP_ROOT/cargo"

# Client builder only
export PLANK_CLIENT_FFMPEG_WORK="$PLANK_DEP_ROOT/client-ffmpeg-9.0.1"
export PLANK_CLIENT_SUBMODULE_CACHE="$PLANK_DEP_ROOT/client-submodules"

# Host builder only
export PLANK_HOST_FFMPEG_BUILD="$PLANK_CANONICAL_ROOT/apps/host/linux/third-party/build-deps/build"
export PLANK_HOST_FFMPEG_ROOT="$PLANK_CANONICAL_ROOT/apps/host/linux/cmake-build-ffmpeg-x264rgb-install/ffmpeg"
export PLANK_HOST_BOOST_ROOT="$PLANK_DEP_ROOT/boost-1.89.0"
```

Do not redefine `HOME`, `CODEX_HOME`, or another system variable to represent
a build path. Record final values and filesystem types in `HANDOFF.md`. The
canonical clone and all build/work directories must use local storage; NFS is
not a build filesystem.

## Clock synchronization

Configure the VM's real-time clock as UTC before installing build packages.
Local-time RTC mode can stamp newly installed libraries in the future and make
Make report misleading clock-skew warnings even when NTP is synchronized:

```bash
sudo timedatectl set-local-rtc 0
sudo timedatectl set-ntp true
test "$(timedatectl show --property=LocalRTC --value)" = no
test "$(timedatectl show --property=NTPSynchronized --value)" = yes
```

If this is corrected after packages were installed, do not broadly rewrite
system-library timestamps. Let the clock catch up or reinstall only the
affected owned packages, then start the candidate from a new build directory.

## Fresh canonical clone

`PLANK_SOURCE_ROOT` is the trusted authoring checkout used to create bundles
for unpublished commits. It may be the same path as `PLANK_CANONICAL_ROOT`
only when the candidate is already pushed and the builder clone is current.

Clone from Git. Do not copy the old work folder and do not use an archive:

```bash
git clone --recurse-submodules=no \
  https://github.com/instinctual/plank.git "$PLANK_CANONICAL_ROOT"
git -C "$PLANK_CANONICAL_ROOT" checkout main
git -C "$PLANK_CANONICAL_ROOT" submodule update --init \
  third_party/kyber-kymux apps/host/linux apps/client
git -C "$PLANK_CANONICAL_ROOT/apps/host/linux" \
  submodule update --init --recursive
git -C "$PLANK_CANONICAL_ROOT/apps/client" \
  submodule update --init \
  moonlight-common-c/moonlight-common-c qmdnsengine/qmdnsengine

git -C "$PLANK_CANONICAL_ROOT" status --short
git -C "$PLANK_CANONICAL_ROOT" submodule status
git -C "$PLANK_CANONICAL_ROOT/apps/host/linux" \
  submodule status --recursive
git -C "$PLANK_CANONICAL_ROOT/apps/client" submodule status
"$PLANK_CANONICAL_ROOT/scripts/maintenance/verify-upstream-pins.sh"
```

All repositories must be clean. Every submodule status must begin with one
space, not `-`, `+`, or `U`. Ordinary candidate builds seed from these local
canonical repositories; they do not repeat this network bootstrap.

The maintained Host/Client repositories are public; anonymous HTTPS is sufficient
for a clean build. GitHub authentication is needed only for authorized pushes,
not dependency downloads. On a trusted authoring builder, configure it separately:

```bash
gh auth login
gh auth setup-git
gh auth status
git ls-remote https://github.com/instinctual/plank.git HEAD
git config --global user.name "Your Name"
git config --global user.email "YOUR_GITHUB_NOREPLY_ADDRESS"
git config --get user.name
git config --get user.email
```

Do not place a GitHub token in a clone URL, shell history, path manifest, or
repository configuration. GitHub authentication and Git commit identity are
separate settings; configure and verify both before a builder needs to commit
in the root, Host, Client, or another nested repository.

## Rust 1.89 and locked Cargo cache

Both builders use exactly Rust/Cargo 1.89.0. Install and populate the cache
once, then prove an offline build:

```bash
mkdir -p "$PLANK_RUSTUP_ROOT" "$PLANK_CARGO_ROOT" "$PLANK_WORK_ROOT"
export RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export CARGO_HOME="$PLANK_CARGO_ROOT"
export PATH="$CARGO_HOME/bin:$PATH"
rustup_bootstrap="$PLANK_WORK_ROOT/rustup-bootstrap"
mkdir -p "$rustup_bootstrap"
curl --fail --location --output "$rustup_bootstrap/rustup-init" \
  https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init
curl --fail --location --output "$rustup_bootstrap/rustup-init.sha256" \
  https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init.sha256
(cd "$rustup_bootstrap" && sha256sum -c rustup-init.sha256)
chmod 0755 "$rustup_bootstrap/rustup-init"
RUSTUP_INIT_SKIP_PATH_CHECK=yes "$rustup_bootstrap/rustup-init" \
  -y --no-modify-path --profile minimal --default-toolchain 1.89.0
rustup default 1.89.0
test "$(rustc --version)" = "rustc 1.89.0 (29483883e 2025-08-04)"
test "$(cargo --version)" = "cargo 1.89.0 (c24e10642 2025-06-23)"
cargo fetch --locked --target x86_64-unknown-linux-gnu \
  --manifest-path \
  "$PLANK_CANONICAL_ROOT/protocol/plank-transport/Cargo.toml"
CARGO_TARGET_DIR="$PLANK_WORK_ROOT/cargo-bootstrap-check" \
  cargo build --release --locked --offline \
    --target x86_64-unknown-linux-gnu \
    --manifest-path \
    "$PLANK_CANONICAL_ROOT/protocol/plank-transport/Cargo.toml"
```

The bootstrap intentionally uses the network. Candidate builds use the pinned
lockfile and `--offline`.

On the Linux Host builder only, also fetch the separately pinned test dependencies
for the vendored Quinn boundary/accounting gate. They are never product link
inputs:

```bash
cargo fetch --locked --target x86_64-unknown-linux-gnu \
  --manifest-path "$PLANK_CANONICAL_ROOT/third_party/quinn-proto-0.11.17/Cargo.toml"
```

## linux-client-builder inputs

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake curl gh git make nasm ninja-build nodejs openssl patch \
  pkg-config python3 python3-venv ripgrep xz-utils \
  qt6-base-dev qt6-declarative-dev qt6-svg-dev qt6-svg-plugins qt6-wayland \
  libsdl3-dev libsdl3-ttf-dev libpipewire-0.3-dev libdecor-0-dev libdrm-dev libinput-dev \
  libopus-dev libplacebo-dev libssl-dev libudev-dev libva-dev \
  libvdpau-dev libwayland-dev libx11-dev zlib1g-dev
```

APT installs transitive development packages. Record the resulting package
versions during cutover. Do not satisfy a missing dependency with an untracked
local library.

```bash
test "$(/usr/bin/qmake6 -query QT_VERSION)" = 6.10.2
node --version
pkg-config --modversion sdl3
pkg-config --modversion sdl3-ttf
```

Recreate private Client FFmpeg from the pinned archive and checksum in the
repository script:

```bash
ffmpeg_bundle_stage="$PLANK_WORK_ROOT/client-ffmpeg-bundle-stage"
mkdir -p "$ffmpeg_bundle_stage"
"$PLANK_CANONICAL_ROOT/scripts/build/build-client-ffmpeg.sh" \
  "$ffmpeg_bundle_stage" \
  "$PLANK_CLIENT_FFMPEG_WORK"
test -x "$PLANK_CLIENT_FFMPEG_WORK/install/bin/ffmpeg"
test "$(LD_LIBRARY_PATH="$PLANK_CLIENT_FFMPEG_WORK/install/lib" \
  $PLANK_CLIENT_FFMPEG_WORK/install/bin/ffmpeg -version \
  | sed -n '1s/^ffmpeg version \([^ ]*\).*/\1/p')" = 9.0.1
test "$(PKG_CONFIG_PATH="$PLANK_CLIENT_FFMPEG_WORK/install/lib/pkgconfig" \
  pkg-config --variable=prefix libavcodec)" = \
  "$PLANK_CLIENT_FFMPEG_WORK/install"
```

The script pins FFmpeg 9.0.1 archive SHA-256
`cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`.
It also verifies and applies the tracked identity-GBR hardware-decode patch
from `apps/client/app/deploy/linux/ffmpeg-patches/`. This patch is
required for HEVC Rext 8/10-bit 4:4:4 matrix-coefficient-0 streams to expose
their VA-API formats. This prepared tree is reusable but reproducible; recreate
it from the pinned archive and tracked patch rather than copying it from
another machine.

Create the persistent local Kyber mirror used to seed clean root candidates.
The initialized qmdnsengine and common-c repositories inside the canonical
Client clone are the local sources for those two Client submodules:

```bash
mkdir -p "$PLANK_CLIENT_SUBMODULE_CACHE"
git clone --mirror "$PLANK_CANONICAL_ROOT/third_party/kyber-kymux" \
  "$PLANK_CLIENT_SUBMODULE_CACHE/kyber-kymux.git"
```

Update mirror refs explicitly after dependency-first pushes. Never replace a
mirror with an ad hoc source copy.

## Host build inputs

Enable the Rocky 9 development, EPEL, GCC Toolset 14, and NVIDIA CUDA 13
repositories, then install the direct build dependencies:

```bash
sudo dnf install -y \
  autoconf automake clang cmake curl gh git libtool make nasm ninja-build patch \
  pkgconf-pkg-config ripgrep rpm-build wget xz \
  gcc-toolset-14-gcc gcc-toolset-14-gcc-c++ cuda-toolkit-13-0 \
  glib2-devel libcap-devel libdrm-devel libevdev-devel libva-devel \
  libX11-devel libxcb-devel libXcomposite-devel libXcursor-devel \
  libXfixes-devel libXi-devel libXinerama-devel libXrandr-devel \
  libXtst-devel libxkbcommon-devel mesa-libgbm-devel mesa-libGL-devel \
  numactl-devel openssl-devel opus-devel pam-devel pipewire-devel \
  pulseaudio-libs-devel python3-devel python3-jinja2 systemd-devel \
  vulkan-loader-devel wayland-devel wayland-protocols-devel
```

Repository enablement is administrator-owned because mirror and entitlement
configuration differs by site. These compiler paths and the complete CUDA
architecture set are hard requirements:

```text
/opt/rh/gcc-toolset-14/root/usr/bin/gcc
/opt/rh/gcc-toolset-14/root/usr/bin/g++
/usr/local/cuda/bin/nvcc
```

Recreate Boost from the URL and checksum pinned in
`Boost_Sunshine.cmake`:

```bash
boost_archive="$PLANK_DEP_ROOT/boost-1.89.0-cmake.tar.xz"
mkdir -p "$PLANK_DEP_ROOT" "$PLANK_HOST_BOOST_ROOT"
curl --fail --location --output "$boost_archive" \
  https://github.com/boostorg/boost/releases/download/boost-1.89.0/boost-1.89.0-cmake.tar.xz
printf '%s  %s\n' \
  67acec02d0d118b5de9eb441f5fb707b3a1cdd884be00ca24b9a73c995511f74 \
  "$boost_archive" | sha256sum --check
tar -xJf "$boost_archive" --strip-components=1 \
  -C "$PLANK_HOST_BOOST_ROOT"
rg -Fxq 'project(Boost VERSION 1.89.0 LANGUAGES CXX)' \
  "$PLANK_HOST_BOOST_ROOT/CMakeLists.txt"
```

Recreate static Host FFmpeg from the exact recursive gitlinks in the PLANK
`instinctual/plank-build-deps` fork. Do not use the Client FFmpeg tree:

```bash
host_build_deps="$PLANK_CANONICAL_ROOT/apps/host/linux/third-party/build-deps"
expected_build_deps=$(git -C "$PLANK_CANONICAL_ROOT/apps/host/linux" \
  rev-parse HEAD:third-party/build-deps)
test "$(git -C "$host_build_deps" rev-parse HEAD)" = "$expected_build_deps"
git -C "$host_build_deps" submodule update --init --recursive
cmake -S "$host_build_deps" -B "$PLANK_HOST_FFMPEG_BUILD" \
  -DBUILD_ALL=OFF -DBUILD_FFMPEG=ON \
  -DBUILD_FFMPEG_SVT_AV1=OFF \
  -DCMAKE_C_COMPILER=/opt/rh/gcc-toolset-14/root/usr/bin/gcc \
  -DCMAKE_CXX_COMPILER=/opt/rh/gcc-toolset-14/root/usr/bin/g++ \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DFFMPEG_INSTALL_PREFIX="$PLANK_HOST_FFMPEG_ROOT" \
  -DPARALLEL_BUILDS=24
cmake --build "$PLANK_HOST_FFMPEG_BUILD" --parallel 24
cmake --install "$PLANK_HOST_FFMPEG_BUILD"
for library in avcodec avutil cbs swscale x264 x265; do
  test -f "$PLANK_HOST_FFMPEG_ROOT/lib/lib${library}.a"
done
```

PLANK has no negotiated AV1 profile. Keep `BUILD_FFMPEG_SVT_AV1=OFF` explicit:
the build-deps upstream default is on, and statically linking its unused
encoder materially bloats the Host binary and RPM.

The build directory is intentionally nested at `third-party/build-deps/build`.
The build-deps project copies recursive Git worktrees whose `.git` files use
relative paths; an arbitrary external build directory breaks those paths and
can silently skip the required PLANK patches. `CMAKE_INSTALL_LIBDIR=lib` keeps
the prepared static libraries and pkg-config metadata in the exact prefix
layout consumed by the Host build. A candidate is invalid if its configure
output does not show the FFmpeg, x265, and other enabled patches being
applied.

The patch helper must either apply every selected patch or prove that the
exact patch is already present; a mismatch is fatal. Run the independent
prepared-source gate after configuration and before accepting the retained
libraries:

```bash
"$PLANK_CANONICAL_ROOT/scripts/build/verify-host-dependency-patches.sh" \
  "$PLANK_HOST_FFMPEG_BUILD"
```

That gate reverse-checks every tracked Host build-deps product patch against
the generated FFmpeg/x265 source. Do not preserve a dependency build that
cannot pass it.

The retained gitlink currently resolves FFmpeg `38b88335` (8.1.2), NV codec
headers `e844e5b2` (13.0.19.0), x264 `b35605ac`, and x265 `1d117bed` (4.1).
Recursive gitlinks, rather than this prose, are authoritative after an
intentional update.

Root hardware qualification on `hardware-test-host` also needs NVIDIA Capture SDK 9's
`NvFBC.h`. This is a hardware-target input, not a requirement for `linux-host-builder` to
produce an RPM. Obtain it from NVIDIA under its license; do not substitute the
inherited NvFBC 1.7 header. The qualified header is 79,813 bytes with SHA-256
`b079b8d672e9ef34e358ded5e40592971ef290a972ccb831f46b38c691ed9ee1`:

```bash
nvfbc_header="$PLANK_NVFBC_SDK_ROOT/NvFBC/inc/NvFBC.h"
test "$(stat -c %s "$nvfbc_header")" = 79813
printf '%s  %s\n' \
  b079b8d672e9ef34e358ded5e40592971ef290a972ccb831f46b38c691ed9ee1 \
  "$nvfbc_header" | sha256sum --check
```

## Codex continuity

Git reconstructs the repository, not conversation history. Preserve the
trusted user's Codex `sessions/`, `config.toml`, `auth.json`, custom `skills/`,
and non-repository notes. Treat `auth.json` as a credential secret. Downloaded
packages, caches, temporary files, locks, and shell snapshots are disposable.

After restoring that state, start Codex from `$PLANK_CANONICAL_ROOT`, resume
this conversation, and read `AGENTS.md` followed by `HANDOFF.md`. A session's
old recorded working directory is not authoritative after the move.

## Builder qualification baseline

The current builders passed clean source, pinned-input, offline Rust,
compilation, package, manifest, and uninstalled runtime-closure gates on
2026-09-01. Exact commits and hashes are in `HANDOFF.md`. For every future
candidate:

1. Verify hostname and source the machine's path manifest before creating any
   worktree.
2. Keep all source, work, temporary, and dependency paths on local storage.
3. Produce the RPM or DEB from fresh worktrees using the release runbook.
4. Do not install the product package on its builder. Inspect and execute the
   staged package tree with the package scripts instead.
5. Transfer the exact package and its SHA-256 to the matching hardware target.
   Install and verify it there before functional acceptance.
6. Run NvFBC/NVENC/display/input gates on `hardware-test-host` and Client
   video/audio/Wayland/Wacom/reconnect/takeover gates on
   `client-test-machine`.
