# Dependency Patch Inventory

PLANK treats dependency patches as versioned source inputs. A candidate build
must not depend on an old builder directory having been modified manually.
For every active patch, bootstrap applies it explicitly and package preflight
independently proves that the prepared source contains it.

SDL and SDL_ttf are retired Client dependencies. The former Wayland
cursor-retirement patch, its bootstrap and SDL-only fixtures are no longer
active inputs. Historical evidence remains in Git; current source and package
gates require no SDL APIs or linkage. See [the removal plan](../plans/client-no-sdl.plan).

## Active product patches

### Client private FFmpeg

`apps/client/app/deploy/linux/ffmpeg-patches/0001-hevc-enable-hwaccel-for-identity-gbr.patch`
allows FFmpeg's HEVC hardware decoder selection to retain VA-API for PLANK's
identity-matrix GBR/GBR10 streams. It is required for the qualified HEVC Rext
10-bit 4:4:4 Y410/XR30 path.

- `scripts/build/build-client-ffmpeg.sh` checksum-verifies and applies it. A patch
  that is neither applicable nor already applied is fatal.
- The macOS Client bootstrap applies the same patch to its pinned FFmpeg source;
  it does not introduce a VA-API dependency on macOS.
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

Vulkan Loader/Headers are pinned together at 1.4.367. The Loader now includes
upstream ID-filter allocation checks, error propagation and cleanup. The local
production patch is removed; package preflight requires the exact unmodified
upstream production source. The retained test patch expands fault injection to
both allocations in each filter (24 cases), with an intentionally broken
negative control in a disposable worktree. Run the hosted
`dependency-qualification.yml` workflow and
`tests/packaging/test-host-dependency-patches.py`; build checks do not replace
hardware acceptance. The [earlier qualification record](../reviews/vulkan-loader-qualification.md)
retains the actual results for the prior Loader, not this upgrade.

The active selection is controlled by the pinned build-deps CMake options and
therefore may include patches for FFmpeg CBS, Vulkan, x264 integration,
NV codec headers, libva, or SVT-AV1. The PLANK Host
bootstrap configuration is the authority for which members are selected; no
selected member may be silently skipped.

## Present but inactive for qualified RPM/DEB packages

- `apps/client/app/deploy/linux/appimage/` contains an AppImage
  libplacebo patch. PLANK does not build or publish AppImages; the Ubuntu DEB
  uses its qualified system libplacebo.
- Patch files embedded inside third-party source repositories, such as
  SVT-AV1's own CI/plugin examples, are upstream project content and are not
  PLANK build inputs unless the pinned build-deps configuration selects them.

If any currently inactive packaging path becomes supported, move its patches
into the active inventory and add both an application check and an independent
package preflight before shipping it.

## Pinned dependencies without PLANK patches

- Boost 1.92.0 is extracted from its SHA-256-pinned release archive and is not
  patched. Its archive hash and prepared-source version are checked during
  bootstrap and package preflight.
- Rust dependencies resolve from committed lockfiles and the retained Cargo
  cache with `--locked --offline`; there is no post-fetch source mutation.
- Kymux, common-c, qmdnsengine, and Host recursive dependencies are exact Git
  links. Candidate setup seeds those commits from canonical repositories or
  verified bundles and requires clean worktrees.
- Qt, libplacebo, and the remaining Ubuntu Client development/runtime inputs
  are qualified Ubuntu packages. Their versions and runtime closure are
  package gates; PLANK does not patch their installed files.

The absence of a patch does not permit a manually modified prepared source.
If a dependency needs a product change, add a tracked patch (or a maintained
fork commit), document it here, and add an independent package gate in the
same change.
