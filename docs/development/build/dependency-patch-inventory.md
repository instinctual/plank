# Dependency Patch Inventory

PLANK treats dependency patches as versioned source inputs. A candidate build
must not depend on an old builder directory having been modified manually.
For every active patch, bootstrap applies it explicitly and package preflight
independently proves that the prepared source contains it.

## Active Linux product patches

### Client private SDL

`apps/client/app/deploy/linux/sdl-patches/0001-wayland-detach-the-tablet-cursor-surface.patch`
repairs cursor retirement in SDL 3.4.2's Wayland backend. When a tablet tool
uses the retiring cursor, detach that tool's surface, not the independent
mouse surface, which may be null or belong to another cursor.

- `scripts/build/build-client-sdl.sh` uses the checksum-pinned official SDL
  archive and applies the exact patch, or proves it is already applied.
- `scripts/build/client-sdl.sh` compares the entire prepared source against a
  fresh extraction plus the patch and verifies the installed-file receipt.
  Bootstrap, dependency-cache restore, application build and packaging all
  require this check.
- `scripts/test/check-client-sdl.py` loads the actual library without starting
  SDL and requires the qualified version and native PipeWire, Wayland and X11
  drivers. CMake's requested `ON` value does not establish that missing headers
  did not silently disable a driver.
- `tests/input/test-sdl-cursor-retirement.py` compiles the actual patched
  retirement function against independent tablet/pointer surface fixtures.
  The unpatched function fails the null-mouse-surface negative control.
- The DEB installs SDL only in `/usr/lib/plank`, retaining the upstream license
  and patch. Its loader gate requires that private library with
  `LD_LIBRARY_PATH` unset. No system SDL files are replaced. Mac SDL inputs are
  unchanged; this patch is specific to Wayland.

### Client private FFmpeg

`apps/client/app/deploy/linux/ffmpeg-patches/0001-hevc-enable-hwaccel-for-identity-gbr.patch`
allows FFmpeg's HEVC hardware decoder selection to retain VA-API for PLANK's
identity-matrix GBR/GBR10 streams. It is required for the qualified HEVC Rext
10-bit 4:4:4 Y410/XR30 path.

- `scripts/build/build-client-ffmpeg.sh` checksum-verifies and applies it. A patch
  that is neither applicable nor already applied is fatal.
- `scripts/build/build-client-package-binaries.sh` checksum-verifies it again and
  proves it reverses cleanly from the prepared FFmpeg source before qmake.
  Both stages reject patch backup (`*.orig`) and reject (`*.rej`) residue.
  Package preflight also compares the complete prepared source against the
  checksum-pinned FFmpeg archive, permits only the patched `hevcdec.c`, and
  verifies the exact expected post-patch hash of that file.

### Host build-deps FFmpeg family

`apps/host/linux/third-party/build-deps/patches/` contains the patches
selected by the retained Host FFmpeg dependency configuration. Its
`APPLY_GIT_PATCH` helper performs a forward check and application, or proves
the exact patch is already present with a reverse check. Any other result is
fatal. `scripts/build/build-host-package-binaries.sh` independently requires this
fail-closed contract before configuring a package build.
`scripts/build/verify-host-dependency-patches.sh` also proves that the generated
dependency worktrees contain exactly the tracked files named by those patches,
with no additional tracked source modifications or patch residue.
The Loader source copy intentionally omits its upstream `tests/` directory;
the verifier allows only tracked deletions there, not modified tests or deleted
production source. NUL-delimited Git paths preserve upstream Unicode filenames.

Vulkan Loader 1.4.362 requires
`patches/FFmpeg/Vulkan-Loader/01-handle-id-filter-allocation-failure.patch`.
It propagates ID-filter allocation failure as `VK_ERROR_OUT_OF_HOST_MEMORY`
through both physical-device enumeration APIs and their cleanup paths. It is
applied even when optional FFmpeg patches are disabled. Bootstrap, cache and
package preflight independently verify the generated Loader source; the separate
upstream-framework test patch is not applied to production dependency sources.
Run `tests/packaging/test-host-dependency-patches.py` to check that stale,
unpatched, incompatible or unexpectedly modified prepared sources are rejected.
See [the qualification record](../reviews/vulkan-loader-qualification.md) for
the original clean build, fault-injection tests and hardware-check limits.

The active selection is controlled by the pinned build-deps CMake options and
therefore may include patches for FFmpeg CBS, AMF, Vulkan, x264 integration,
x265 integration/source, NV codec headers, libva, or SVT-AV1. The PLANK Host
bootstrap configuration is the authority for which members are selected; no
selected member may be silently skipped.

## Present but inactive for qualified RPM/DEB packages

- `apps/client/app/deploy/linux/appimage/` contains an AppImage
  libplacebo patch. PLANK does not build or publish AppImages; the Ubuntu DEB
  uses its qualified system libplacebo.
- `apps/host/linux/packaging/linux/patches/{aarch64,x86_64}/` contains CUDA
  compatibility patches for inherited generic/COPR packaging. The canonical
  PLANK RPM build does not invoke those packaging paths.
- Patch files embedded inside third-party source repositories, such as
  SVT-AV1's own CI/plugin examples, are upstream project content and are not
  PLANK build inputs unless the pinned build-deps configuration selects them.

If any currently inactive packaging path becomes supported, move its patches
into the active inventory and add both an application check and an independent
package preflight before shipping it.

## Pinned dependencies without PLANK patches

- Boost 1.89.0 is extracted from its SHA-256-pinned release archive and is not
  patched. The 2026-09-02 audit compared the retained source recursively with
  a fresh extraction and found no differences.
- Rust dependencies resolve from committed lockfiles and the retained Cargo
  cache with `--locked --offline`; there is no post-fetch source mutation.
- Kymux, common-c, qmdnsengine, and Host recursive dependencies are exact Git
  links. Candidate setup seeds those commits from canonical repositories or
  verified bundles and requires clean worktrees.
- Qt, SDL3_ttf, libplacebo, and the remaining Client development/runtime inputs
  are qualified Ubuntu packages. Their versions and runtime closure are
  package gates; PLANK does not patch their installed files.

The absence of a patch does not permit a manually modified prepared source.
If a dependency needs a product change, add a tracked patch (or a maintained
fork commit), document it here, and add an independent package gate in the
same change.
