# Building a fork from source

PLANK's build inputs must be reproducible without a maintainer's prepared
dependency directories or signing keys. A product rebuild and a dependency
bootstrap are different checks: bootstrap starts with empty dependency,
Rustup/Cargo and product build directories. OS compilers, platform SDKs and
distribution development packages remain prerequisites, not projects rebuilt
by PLANK. macOS Qt is downloaded from its pinned official release archives.

## Choose a platform

| Product | Required build platform | Start here |
| --- | --- | --- |
| Linux Host | Rocky/RHEL 9.7, x86-64; GCC Toolset 14, CUDA 13 | [Linux bootstrap](builder-vm-bootstrap.md) |
| Linux Client | Ubuntu 26.04, x86-64; Qt 6.10.2 | [Linux bootstrap](builder-vm-bootstrap.md) |
| macOS Host / Client | Apple Silicon builder, macOS 27, Xcode/SDK 27; Host minimum26.7, Client minimum15 | [Host](macos-build-runbook.md), [Client dependencies](macos-client-build-runbook.md) |

The named internal builders in the operational runbooks identify where project
releases are qualified. They are not required computer names for a contributor.
Choose your own absolute paths for the documented `PLANK_*` variables. Do not
copy a maintainer's `paths.env`, certificates, Cargo cache or prepared FFmpeg.
Windows is not yet a supported build target.

The macOS Host uses Apple's system capture/encoding frameworks and the Rust
transport. The private Qt/SDL/FFmpeg dependency stack is needed for the macOS
Client, not for a Host-only build.

## Source and dependencies

Clone your fork, select its intended commit, and initialize only the relevant
product and shared transport before bootstrapping. For example:

```bash
git clone --recurse-submodules=no YOUR_FORK_URL plank
cd plank
git submodule update --init --recursive apps/client third_party/kyber-kymux
```

The submodule section names intentionally differ from their working paths.
For a Linux Host build, initialize apps/host/linux instead of apps/client.
Read `.gitmodules`; do not invent new names when overriding clone URLs.
Required FFmpeg/build-deps patches are tracked source inputs. Missing patches
are build failures, not optional optimizations.

Use the bootstrap runbooks to obtain the pinned source archives, verify their
checksums and build the dependencies. Then use a clean Git worktree and new
product build directory for the [package runbook](release-build-runbook.md).
Set `PLANK_BUILD_BRANCH` explicitly: `main` for a mainline package, otherwise
the lowercase kebab-case feature name. Never replace a finished package under
the same version with different bytes.

## macOS: compilation is separate from distribution

Our certificates and Apple account are **not** build dependencies. Never copy
or commit a signing private key, keychain, password or notarization credential.

For compilation and uninstalled component checks:

```bash
unset PLANK_MACOS_SIGNING_IDENTITY PLANK_MACOS_INSTALLER_IDENTITY
unset PLANK_MACOS_TEAM_ID PLANK_NOTARY_PROFILE
# Set source, dependency/cache and output paths as in the Mac runbooks.
source "$PLANK_SOURCE_ROOT/scripts/package/package-version.sh"
plank_load_package_version "$PLANK_SOURCE_ROOT"
PLANK_MACOS_SOURCE_FIRST=1 bash "$PLANK_SOURCE_ROOT/scripts/build/build-macos-transport.sh" \
  "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/transport"
PLANK_MACOS_HOST_VERSION="$PLANK_PACKAGE_VERSION" \
  bash "$PLANK_SOURCE_ROOT/scripts/build/build-macos-host.sh" \
  "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/host-build" \
  "$PLANK_WORK_ROOT/transport/release/libplank_transport.a"
bash "$PLANK_SOURCE_ROOT/scripts/build/build-macos-client.sh" \
  "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/client-build"
```

The Host emits an ad-hoc-signed, uninstalled executable for assembly checks;
without an Apple signing identity it does not produce the deployable Host app.
The Client build is a developer app linked to that machine's dependency paths,
not a portable distributable. The non-posting Host pen fixture needs a logged-in
desktop on the build Mac; it does not inject input or grant permissions.

Do not equate a successful ad-hoc build with a fully provisioned remote Host.
Installed Host worker authentication and durable privacy permission identity
require the signed-app workflow. Use your own Apple signing identity for live
development. Do not remove same-team peer checks or alter TCC databases to run
an unsigned fork. Replacing an existing installation signed by a different team
is not an ordinary upgrade and must not bypass the installer's identity checks.

For public PKG distribution, obtain your own Developer ID Application
certificate and a Developer ID Installer certificate for either product. Set
the signing identity fingerprints and Team ID through the documented build
environment. Store notarization credentials in your own Keychain profile using
`notarytool store-credentials`; only its profile name enters the build command.
Developer ID issuance requires Apple Developer Program membership. Apple's
[Developer ID guidance](https://developer.apple.com/developer-id/) and
[notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
describe this distribution layer; open-source licensing does not replace it.

The production packaging scripts intentionally require signing, notarization,
stapling and Gatekeeper validation. Do not disable those checks to publish a
development executable. PLANK privacy permissions remain separate from signing.
