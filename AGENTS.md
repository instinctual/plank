# Repository Guidelines

## Mac Client compatibility scope

The operator authorized one Apple Silicon Client package for macOS 15 and newer,
built with SDK27 or newer and a 15.0 deployment target. Bootstrap, application,
and PKG packaging use that same policy; do not reuse dependencies built with a
newer minimum OS. Use runtime availability checks for APIs newer than macOS15,
not compile-time removal of macOS27 capabilities. The operator authorized one
macOS Host package for 26.7 and newer, built with SDK27 and exact dependency
pins. `PLANK_MACOS_HOST_MIN_OS` defaults to 26.7. The optional 27.0 target is
only for candidate regression comparisons, not a second release package.
Chris (cnoellert) owns macOS 26.7 hardware and session validation; the operator
does not need a 26.7 test machine. This target is not experimental. Preserve
the macOS 27 build/regression gates and distinguish uninstalled build checks
from installed session acceptance. See `docs/development/plans/macos26-host-backport.md`.
Linux qualification rules are unchanged. Qualify the identical
Client package on both macOS15 and macOS27; compilation alone is not streaming,
audio, input or tablet acceptance.

## Project Structure & Module Organization

This repository is in late integration and production hardening. It has a
packaged Host/Client vertical slice, but the remaining gates in
`docs/development/acceptance-criteria.md` still apply. This file defines repository policy
and supported product scope; `protocol/` and the focused architecture/security
documents define current subsystem contracts. Read `HANDOFF.md` after this file
for the exact current commits, artifacts, machine state, validation results,
and next test. The layout is:

- `apps/host/linux/` — RHEL/Rocky host, capture, encoding, authentication, and input helpers.
- `apps/host/macos/` — native macOS Host and platform integration.
- `apps/client/` — shared Linux/macOS client, decoding, presentation, and login UI.
- `protocol/` — shared schemas, feature negotiation, and test vectors.
- `packaging/<product>/<os>/` — platform installation metadata and integration.
- `tests/` — authentication, color, network, Wacom, and end-to-end suites.
- `docs/` — architecture, protocol, security, color-pipeline, and test-plan details.
- `probes/` and `scripts/` — standalone qualification binaries and report runners.

Keep host/client protocol changes synchronized. Preserve the upstream history and license notices of both forks.

Only Host and Client products belong here. Do not add private infrastructure
repositories as submodules or require their code or credentials to build.
Optional wake requests default off and require administrator policy. Do not
add a user preference or restore Client-side magic packets or MAC storage.

The submodule working paths changed; their Git section names remain
`host/sunshine-fork` and `client/moonlight-qt-fork`. Do not derive a working
path from a section name or rename `.git/modules` as a cosmetic cleanup.
Scripts are grouped under `scripts/build`, `scripts/package`, `scripts/test`
and `scripts/maintenance`; consult `docs/README.md` for documentation routing.
Keep private deployment notes outside Git. HANDOFF contains current state and
remaining gates, not an accumulating session transcript.

Treat tracked files and commit messages as public-facing. Keep passwords in a
password manager/OS Keychain and private deployment notes in
`~/.local/share/plank/private-notes/` (directory `0700`, files `0600`). Private
audits belong alongside it in `private-audit/`, never inside an ignored checkout
directory. Read the private notes' local README before machine-specific work;
do not copy account names, addresses, credentials or private captures back into
Git. Public documentation uses role names, environment-driven paths and reserved
examples. See `docs/security/private-information.md` for hook setup, CI scope,
private denylist handling and publication limitations. Never print secret matches
in tool output, reports, commit messages or CI logs.

The Linux product input scope is keyboard, absolute-position mouse with buttons
and scrolling, normalized pen-tablet fallback, and raw-HID Wacom forwarding.
Do not restore gamepad/controller support, direct generic-touchscreen
forwarding, touchscreen-as-trackpad emulation, or a relative/absolute mouse
mode preference. Physical Wacom touch interfaces remain part of raw-HID Wacom
device forwarding and are distinct from generic direct-touchscreen input.

UPnP/NAT traversal is not a PLANK capability. Do not restore the
removed miniupnpc dependency, automatic gateway port mappings, IPv6 pinholes,
or UPnP configuration and command-line toggles. Routing and firewall policy
remain administrator-managed.

ENet and the inherited GameStream transport are not current build inputs.
The Host common-C branch is header-only (Input.h, Limelight.h and plank.h),
with no recursive dependencies or compiled library. Do not restore ENet,
nanors, retired transport source or their build wiring. Historical builds are
not supported; preserving attribution/history does not require unused code in
the current checkout.

The qualified default client video profile is H.264 High 10 4:4:4 identity.
Decoder selection is internal, not a user preference: test exact-format
hardware decoding first, then fall back to the FFmpeg software path for the
same selected bookmark profile. A hardware path is acceptable only after a
real profile-specific test frame proves the requested codec profile, bit depth,
chroma sampling, range, and identity mapping. On the qualified Intel NUC, HEVC
Rext 10-bit 4:4:4 identity is hardware-decoded through VA-API to a Y410 surface
and presented through the EGL Y410/XR30 identity path. H.264 High 10 4:4:4 is
not supported by that VA-API implementation and therefore uses the exact-format
FFmpeg software path. Never silently substitute H.264 High 8 4:4:4, 4:2:0,
another codec, or any other profile. If neither exact hardware nor exact
software decoding works, fail the connection clearly.

## Build, Test, and Development Commands

macOS Host builds use **SDK 27 or newer** and a **26.7 deployment target** for
one package covering 26.7 and newer. Hosted compilation and component regression
tests continue on macOS27. Qualify the identical signed package on 26.7 and 27
before treating the shared package as accepted; use the validation ownership
above. No broader older-OS support is implied. The reference Mac used to inspect
PCoIP is read-only. Build and run
macOS probes only on the user-authorized dedicated development Mac.
Beta results require revalidation against the final
OS release. This work does not change the supported Linux release gates below.

Experimental macOS Client builds use the same authorized dedicated development
Mac, Apple Silicon, SDK27 or newer and deployment target15.0. See
`docs/development/plans/macos-client.plan` and `docs/development/build/macos-client-build-runbook.md`. This is not
permission to compile Linux packages on the Mac or restore inherited prebuilts.

Builder and hardware-test roles are deliberately separate:

The Ubuntu Client uses the Qt session frontend and direct PipeWire playback
under the ordinary `plank-client` identity. Build and test it on GitHub-hosted
Actions, not the retained Ubuntu VM. Use `linux-client` for the component,
sanitizer, compositor, launcher and package-upgrade gates and the resulting DEB.
There is no separate Qt product or experimental configuration namespace.
Preserve existing bookmarks, Host trust, administrator policy and log paths.
macOS retains its existing SDL/Metal frontend; Linux selection must not change it.
Do not ask the operator to repair VM prerequisites or distribute a standalone
probe as the Client.
Hosted tests do not replace exact-candidate hardware/session acceptance. Read
HANDOFF and the private notes for current test-target availability and results.

The workflows in `.github/workflows/build.yml` also authorize disposable
GitHub-hosted builders for the same target OS/toolchain contracts: Rocky 9.7
container, Ubuntu 26.04 and Apple Silicon macOS/SDK 27. These are compile/package
workers, never installation or hardware-test targets. Public pull requests
must not receive signing/deployment credentials or run on internal machines.
See `docs/development/build/github-builds.md`; local builders remain qualified
until the hosted replacements pass their clean-build gates.

- Build Host binaries and RPMs only on the Linux Host builder (Rocky Linux 9.7).
- Build Client binaries and DEBs only on the Linux Client builder (Ubuntu
  26.04), using Qt 6.10.2 and the pinned private FFmpeg 9.0.1 tree.
- Install Host candidates and run NVIDIA/display/input hardware qualification
  on the authorized hardware test Host; do not compile release packages there.
- Install Client candidates and run interactive video/audio/input/Wacom tests
  on the authorized Development NUC; do not compile release
  packages there.
- End-User NUCs are clean manual-install/test targets. Do not build there or
  remotely install packages unless the user explicitly authorizes it.

The builder VMs are build-only appliances. Do not install an ordinary
candidate RPM or DEB on its builder. Validate uninstalled package contents,
dependency closure, version, hashes, private runtime paths, and
service/autostart absence there. Install the exact transferred package on the
corresponding hardware test target and verify its installed version and binary
hash before functional acceptance. The Client is interactive and must not
ship, enable, or start a systemd user service or any other autostart entry.

Read `docs/development/build/release-build-runbook.md` before every candidate package build. It
is the canonical command sequence and failure-signature reference. In
particular, Qt client validation over headless SSH must use
`QT_QPA_PLATFORM=offscreen`; a display-plugin abort from an ad hoc invocation
is not a compiler or packaging failure.

Read `docs/development/build/builder-vm-bootstrap.md` before preparing or replacing either build
machine. Builder paths come from its documented `PLANK_*` path contract and
must not be inferred from an old session or hardcoded for a new VM. Recreate
the canonical Git clone, Rust/Cargo cache, Client FFmpeg, Host FFmpeg, Boost,
local submodule sources, and qualification SDK input from pinned sources; do
not copy old prepared trees. The Linux Host and Client builders are the canonical
package builders. The hardware test Host and Development NUC are installation and
hardware-test targets, not fallback build machines.

Use clean Git worktrees as source snapshots. Reuse the prepared, Git-ignored
host and client FFmpeg trees; creating a worktree does not recreate those build
inputs. The Ubuntu Client also requires prepared, patched SDL through
`PLANK_CLIENT_SDL_WORK`. Verify its source, installed bytes and actual compiled
PipeWire/Wayland drivers; an SDL CMake `ON` setting alone does not prove those
drivers were included. Bundle SDL privately, never replace the OS library.
Every product dependency patch is a required, reproducible build
input. A dependency bootstrap must either apply each selected patch or prove
that the exact patch is already applied; a source/patch mismatch must stop the
build. The package preflight must independently verify the patched prepared
source. Never rely on an old builder tree having been patched manually. On
the Linux Client builder, redirect every current Linux client submodule
to its retained local canonical repository before the first submodule update:
qmdnsengine and common-c. Common-c has no recursive Linux dependencies.
h264bitstream is vendored, libsoundio is removed, and the Windows/macOS
prebuilts repository is not a Linux candidate input. Do not restore the stale
submodule list or redownload already-present dependencies for each clean
worktree. When a
candidate contains unpublished root or submodule commits, seed
the Linux Client builder from verified local Git bundles before creating its
worktree. Import the client bundle before the root bundle and pass
`--recurse-submodules=no` to both fetches; never rely on repository fetch
configuration. Set `PLANK_BUILD_BRANCH` explicitly for every detached candidate
worktree: use `main` for an unqualified release, otherwise use the lowercase
kebab-case feature branch name. The effective version in package filenames and
the visible application version must include that feature branch; detached
builds must never guess or silently omit it. Do not use `pgrep -f` loops as completion watchers because they
can match themselves. Do not fall back to archive-based source snapshots.
Retain exact root and recursive-submodule commit provenance in `HANDOFF.md`.

Keep the Linux Client builder minimal after an accepted candidate is copied to
`artifacts/packages/` and all commits are pushed. Retain only the canonical
clone and prepared dependency/cache paths named by its `PLANK_*` manifest.
Remove exact old candidate worktrees, builds, artifacts, and bundles; do not
accumulate ad hoc top-level source copies, package extracts, logs, captures,
or reproduction trees. Runtime settings and persistent logs belong on the
hardware-test targets and are not build inputs.

For a host-only candidate on the Linux Host builder, initialize only
`apps/host/linux` and its recursive submodules. Do not run a recursive
submodule update from the root worktree: that needlessly initializes the client
tree and will fail if the root gitlink names an unpublished host commit. Create
and SHA-256-verify a host Git bundle first, clone or fetch that bundle into the
host submodule path, check out the exact host gitlink, and only then initialize
the host's recursive dependencies. Seed those dependencies from the canonical
host repository with `scripts/build/init-host-candidate-submodules.sh`; do not clone
all recursive repositories from GitHub for every candidate. Link the
canonical prepared host FFmpeg directory into the Git-ignored path in that
clean worktree. The exact commands are maintained in
`docs/development/build/release-build-runbook.md`.

Use a Host-builder-local build directory under `$PLANK_WORK_ROOT`. Host
packaging defaults to eight build jobs; override it only with a positive
`PLANK_BUILD_JOBS` value after
considering local CPU, memory, and storage behavior. Pass the retained exact
Boost 1.89.0 source through `PLANK_BOOST_SOURCE_DIR` as documented in
the release build runbook; a clean candidate must not download Boost again.
Keep final packages in the version/platform catalog under `artifacts/packages/`.
Use `scripts/package/collect-package.py` (called by package builders) to retain
checksums and source provenance. Never write flat copies or relabel an existing
candidate after merging; rebuild from main instead. See `artifacts/README.md`.

The Host RPM must install and own `/var/log/plank`
as `root:root` mode `0700` before services start. systemd 252 opens `append:`
log output before creating `LogsDirectory=`, so that directive alone cannot
bootstrap a fresh installation. Require the finished-RPM directory gate and
an installation test with the log directory absent when changing this path.

The host has one administrator-owned INI configuration file at
`/etc/plank/host.conf`; do not restore `host.env`, shell
continuations, or a second configuration source. Keep mutable workstation
identity in `/var/lib/plank/plank-state.json`, separate from
configuration and TLS material. There are no deployed legacy installations,
so do not add old Sunshine configuration/state migration or compatibility
paths unless the user explicitly changes that product rule.

The host PAM service is `/etc/pam.d/plank-host`. The broker reads
`security.allow_root_login` from `host.conf`, defaults it to `false`,
and otherwise delegates account authorization to the host's PAM/SSSD policy,
including FreeIPA HBAC; do not restore an application-specific user allowlist.
Enabling root does not bypass active-desktop ownership. The root supervisor is
the only PAM-broker connector; the media worker receives a connected descriptor
over a private inherited channel and exchanges credentials directly with PAM.
Do not add a direct-connect fallback or forward passwords through the supervisor. Keep the
broker directory/socket and TLS private key `root:root` with modes `0700`/`0600`
and do not restore a service-access system group or sysusers entry.

Run the current Host hardware qualification from a complete clean checkout at
the exact package root commit on the hardware test Host, not on the GPU-less builder:

```bash
qualification_build=${PLANK_BUILD_DIR:-"${PLANK_WORK_ROOT:-${XDG_CACHE_HOME:-${HOME}/.cache}/plank-build/work}/qualification"}
cmake -S . -B "$qualification_build" -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build "$qualification_build" --parallel
ctest --test-dir "$qualification_build" --output-on-failure
./scripts/test/run-host-qualification.sh
```

The report runner verifies NvFBC X11-to-CUDA capture without changing Xorg,
inventories KMS, and performs a real 2160p60 NVENC HEVC Rext 10-bit 4:4:4
encode. NvFBC 1.9 is an 8-bit source path and must be labeled
`8-bit-source/up-converted`; native 10-bit capture is not a gate for this
baseline. Treat hardware qualification results as gates for the affected path,
and record incomplete or unavailable hardware checks honestly.

## Coding Style & Naming Conventions

Follow the established style and formatter of the upstream Sunshine or Moonlight-Qt subtree being changed. Keep C/C++ names descriptive and preserve surrounding conventions. Use lowercase kebab-case for documentation (for example, `color-pipeline.md`) and group tests by subsystem. Avoid broad privilege: isolate PAM, DRM/KMS, and input-device operations in narrowly scoped helpers.

## Testing Guidelines

Every protocol change requires host and client tests, updated version/feature negotiation, and compatible test vectors. Add focused tests under the matching `tests/<subsystem>/` directory. Validate security failures as well as success paths. Hardware-sensitive work must exercise `docs/development/acceptance-criteria.md`, including packet loss, 10-bit pixel checks, session cleanup, and real Wacom events.

## Commit & Pull Request Guidelines

The root and both maintained forks have usable PLANK history. Follow
their established short, imperative subjects with an optional subsystem prefix,
such as `protocol: negotiate source bit depth`. Keep commits focused, commit
nested dependencies before their parent gitlinks, and push in dependency order.
Retain upstream commit references when cherry-picking. Pull requests should
describe affected host/client behavior, security implications, target hardware
tested, commands or procedures run, and any known fallback. Include screenshots
for UI changes and link the relevant plan phase or issue.
