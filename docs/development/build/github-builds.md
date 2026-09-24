# GitHub-hosted builds

`Hosted builds` compiles all four public products from clean Git worktrees.
It runs on pushes, pull requests and manual dispatch. No self-hosted machine,
deployment credential, private repository or signing secret is available to
these jobs. Actions are pinned to commit IDs and receive read-only permissions.

When reviewing an Actions dependency update, update the exact reviewed hashes
in `tests/ci/test_context.py` and `tests/ci/test_dependency_cache.py` alongside
the workflow pins and version comments. Verify upstream runtime/input changes
and run all four platform jobs. Do not remove pin assertions or weaken
credential/cache restrictions just to accept a Dependabot update.

| Product | Environment | Result |
| --- | --- | --- |
| Linux Host | Pinned Rocky 9.7 container on Ubuntu runner | RPM and provenance catalog |
| Linux Client | Ubuntu 26.04, Qt 6.10.2 | DEB and provenance catalog |
| macOS Host | `xcode-27`, arm64, SDK/OS 27+ | Unsigned compile and portable tests |
| macOS Client | `xcode-27`, arm64, SDK/OS 27+; deployment minimum15.0 | One unsigned developer build for macOS15+ |

Runner labels are not substitutes for version checks. Unsupported OS, Qt or
SDK versions stop the build. The Rocky repositories are fixed to the 9.7 vault;
CUDA compilation retains the existing complete architecture set. Runtime GPU
drivers are not installed. `scripts/ci/` creates the path contract, bootstraps
pinned dependencies, then invokes the normal build/package scripts. Existing
patch, payload, version and clean-source gates remain mandatory.

The Mac Client uses one package on macOS15 and macOS27. Its lower deployment
floor does not lower the builder SDK requirement or change the Host's27.0
minimum. Exact cache keys include the Client deployment policy; old
27-minimum dependencies are not reused. Native target-validation fixtures run
in the Client build, and DMG packaging checks every bundled binary and the app
plist. Live acceptance of the identical package on both OS versions is a
separate gate; newer APIs require runtime availability checks.

The initial policy job has a root-only checkout, with no initialized submodules.
Keep its assertions limited to tracked root files. Dependency-source checks
belong after product bootstrap: `build.sh` requires the Kynet datagram-sender
check for all four products and fails if the pinned dependency is absent.

Linux package artifacts expire after seven days and do not publish releases.
The Linux Host job also builds the fake-backend input tests after packaging and
runs the input/raw-HID suites 25 times in shuffled order. Tests use the exact
candidate sources and prepared dependencies. The RPM remains the production
`BUILD_TESTS=OFF` payload; missing `/dev/uhid` cases are explicit skips, not live
tablet acceptance. Keep real mouse/Wacom disconnect/reconnect qualification as
a separate hardware gate.

Feature builds retain their branch-qualified visible and package versions.
These jobs do not install products or perform live display, audio, input,
network-loss or hardware-decoder qualification. Existing hardware gates and
local builders remain available until hosted builds are qualified.

## macOS distribution credentials

Ordinary CI intentionally has no Apple credentials. Its unsigned results are
not end-user installers. Signed, notarized PKG/DMG publication requires a
separate branch-restricted release environment with Developer ID
Application and Installer certificates/private keys and notarization authority.
Do not copy a developer's entire keychain or reuse personal GitHub credentials.
Do not weaken existing signing/notarization gates to make an unsigned CI job
produce a release. Credential provisioning and release automation are a
separate gate.

`build.yml` has a separate signing job selected with `signed=true` for one Mac
product. The job requires manual dispatch and directly names the protected
`macos-signing` environment. At the operator's request, this environment has no
required reviewers or wait timer: an explicitly dispatched signed build on an
allowed branch proceeds automatically. Keep custom deployment branch policies
enabled (currently `main` only after merged-branch cleanup); do not replace them
with an all-branches wildcard. Remove a temporary branch's signing permission
when retiring that branch. Review source, workflow and dependency changes before
dispatching or adding a candidate branch. Public push/PR jobs have no signing
authority. This removes the approval gate itself, not through a bot/token that
approves each run; it does not enable signing on every push.

Environment secrets (never repository files):

- `PLANK_DEVELOPER_ID_APPLICATION_P12`, `PLANK_DEVELOPER_ID_INSTALLER_P12`:
  base64-encoded encrypted exports including the matching private keys.
- `PLANK_DEVELOPER_ID_APPLICATION_PASSWORD`,
  `PLANK_DEVELOPER_ID_INSTALLER_PASSWORD`: the respective export passwords.
- `PLANK_MACOS_HOST_PROVISION_PROFILE`: base64 Developer ID provisioning profile
  for `la.instinctual.PLANK.Host`, authorizing system-extension installation and
  the selected application signing identity. Required only for signed Host
  builds; the earlier camera probe profile cannot be reused.
- `PLANK_APPLE_ID`, `PLANK_APPLE_APP_PASSWORD`: notarization account and its
  Apple app-specific password, not its ordinary login password.

Set environment variable `PLANK_MACOS_TEAM_ID` to the Developer Team ID.
Certificate type, private-key presence and team are validated on the runner.
Keep Developer ID distinct from Apple Development and Mac App Store identities.

For the Host camera, an Account Holder or Admin must enable **System Extension**
on the explicit App ID `la.instinctual.PLANK.Host` in Apple Developer's
Certificates, Identifiers & Profiles. Create a **Developer ID** provisioning
profile for that App ID using the existing Developer ID Application certificate
used by the signing job. Download the profile outside the checkout and provide
its base64 contents through `PLANK_MACOS_HOST_PROVISION_PROFILE` in the protected
environment. The package gate verifies the exact app/team, signing certificate,
expiration and `com.apple.developer.system-extension.install = true` before
embedding the profile. The probe's App ID/profile does not authorize the Host.
See [Apple's capability setup](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/).
The build uses a Team-ID-prefixed macOS app group, which does not need separate
portal registration; its entitlement is added to the signed Host and extension.
See [Apple's app-group formats](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups).

This provisioning step does not replace notarization credentials or the Mac's
extension activation approval. The installed Host exposes explicit camera
enable/disable actions; signing a package does not activate the extension.

After a clean committed/pushed source is qualified, request signing with
`bash scripts/ci/dispatch.sh macos-host true` (or `macos-client true`). The job
starts without a separate approval prompt on an allowed branch. Only its
signing step receives secrets. Separate credential-free steps bootstrap and
save verified dependencies first. The signing helper checks secret presence and
removes secrets from child environments, then imports into a temporary 0700 runner
directory/keychain with narrowly allowed Apple signing tools, and stores
notarization credentials in that keychain. It restores the prior search list
and deletes temporary material on completion/failure; an always-run cleanup step
also handles interruption. Only the gated package catalog is uploaded, never
signing scratch, keys or keychains. Artifacts expire in seven days; this does
not publish a release or install on any machine.

This isolated-runner automation uses GitHub's per-step secret environment and
Apple CLI password arguments during import/profile setup. They are not echoed;
tool output/exception arguments are suppressed at that boundary. They may be
visible to another process under the same runner account, which is why this is
restricted to disposable GitHub-hosted machines running approved source, never
an operator's Mac, shared runner or public PR. Local interactive keychain rules
remain unchanged. See [GitHub's signing guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Initial qualification

The protected direct Host job passed signing, notarization, stapling, final
package permission checks and temporary-keychain cleanup in
[run 35011167754](https://github.com/instinctual/plank/actions/runs/35011167754)
at source `ca36e48123d58cc84104f6fab5df59c35d14f05e`. This is not live
installation/recovery acceptance or qualification of the signed Client job.
The initial reusable-workflow version received empty secret values despite
environment metadata being present; the direct environment-protected job is
the qualified path. Do not restore that indirection or broaden secret access.

All four 1.0.105 release packages were subsequently rebuilt from mainline
`78e068edf9240de44e2aea5949dd94df713468b0` on hosted runners. The signed Client
job passed in [run 35018367944](https://github.com/instinctual/plank/actions/runs/35018367944),
including package launch/version, dependency closure, signing, notarization,
stapling, Gatekeeper and temporary-keychain cleanup. Both Mac release jobs
started without reviewer approval under the branch-restricted policy. This
qualifies the hosted packaging path, not live hardware behavior.

Clean bootstrap runs qualify the public-clone path and expose missing
prerequisites. Do not silently
switch to paid larger runners, older SDKs or reduced CUDA architectures when a
standard runner is insufficient; record the resource limitation first.

### Exact-input dependency caches

All four products support dependency caching (including unsigned and signed
Mac jobs). Version 2 uses independent exact keys, receipts, restore and save
operations for each dependency group. A Cargo lockfile change must not rebuild
FFmpeg or Boost, and a Mac FFmpeg patch must not redownload Qt.

| Product | Independent cache groups |
| --- | --- |
| Linux Host | Rust toolchain; Cargo downloads (including vendor-test dependencies); FFmpeg/codec build tree; Boost sources |
| Ubuntu Client | Rust toolchain; Cargo downloads; FFmpeg libraries, patched source and pristine archive |
| macOS Host | Rust toolchain; Cargo downloads (capture/encoding/audio use Apple frameworks) |
| macOS Client | Rust toolchain; Cargo downloads; native-library install/source/download tree; Qt |

The Linux Host FFmpeg/x264/x265 build tree is one coupled cache. Mac FFmpeg,
OpenSSL, SDL, FreeType, Opus and pkgconf also remain a coupled group because
their current bootstrap shares one installation prefix. Never restore
overlapping directories from independent keys. Qt is outside that prefix.

`scripts/ci/dependencies/` contains the existing build recipes, split so each
fingerprint hashes only its own preparation commands, versions, flags and
required patches. Keep such inputs in the relevant recipe, not in the shared
`bootstrap.sh` orchestration wrapper. The Host FFmpeg group additionally hashes
the build-deps Git pin, tracked files and source gitlinks. Both Client library
groups retain all FFmpeg patch inputs and build-path/sanitization helpers.

Rust toolchain changes invalidate Rust and Cargo downloads; transport and
vendor-test manifests/locks invalidate only their Cargo group. Native library
keys still include exact installed Linux packages or Mac SDK/compiler/build
tools. Downloads/source-only groups do not depend on those C/C++ build tools.
All keys remain product/platform/path-specific; Mac Client native/Qt keys
retain the explicit deployment-target policy. Changes to the shared cache
implementation itself invalidate all groups conservatively. Application-only
changes do not invalidate dependency keys. OS packages are still installed by
the package manager on each disposable runner; CUDA architecture coverage and
all dependency versions/build flags are unchanged.

The composite action `.github/actions/dependency-cache` handles the same
restore/verify and seal/save sequence for all four products. Each group can hit
or miss independently. Save skips exact hits, and job-local hit bookkeeping is
not cached. The narrow Rust/Cargo allowlist excludes credentials/configuration
and compiled target objects. There are no application, package or signing caches.

Mac Host's cache avoids Rust installation/downloads, not application or
transport compilation. Do not promise the same improvement as caching FFmpeg.
Cache selection is exact, with no fallback restore keys. A receipt must match
the selected key, required outputs must exist, and Linux FFmpeg patches are
checked independently before bootstrap (including Mac FFmpeg). Existing package/source gates still
run. A mismatched/incomplete cache fails closed rather than silently using
unverified dependencies. Use a clean-bootstrap build to diagnose such a failure.

The new `plank-<product>-<dependency>-v2-<digest>` keys intentionally cannot
restore the old monolithic v1 caches. The first build needs to populate them
once; subsequent changes invalidate only affected groups. Local isolation,
mixed-hit, receipt and workflow-policy tests pass. Hosted v2 cold population
passed for all four products at
`ad1a4a40e429e7712a4c01dd1aa4d74e68e5c3bb` in
[run 35654558827](https://github.com/instinctual/plank/actions/runs/35654558827).
The Ubuntu package passed but artifact finalization returned HTTP 403. Its
same-source [recovery run 35655809810](https://github.com/instinctual/plank/actions/runs/35655809810)
restored and verified all three groups in 24 seconds, bootstrapped in two
seconds and passed application/package checks and artifact upload. This proves
Ubuntu warm reuse, not partial-hit or all-platform warm qualification. Linux
Host passed packaging and all six strengthened loss matrices on its first
hosted attempt; Mac results are unsigned, not distribution installers.

#### Historical v1 four-product qualification

All listed runs passed full application build/tests after dependency bootstrap;
Linux jobs also passed package gates. Mac runs here were unsigned, not deployment
or signing qualification. Existing signed release gates remain unchanged.

| Product | Cold run | Warm run | Bootstrap cold / warm | Warm restore |
| --- | --- | --- | --- | --- |
| Linux Host | 35144970937, attempt 1 | 35144970937, attempt 2 (Host job only) | 4m29s / 23s | 12s |
| Ubuntu Client | 35146540028 | 35147537196 | 5m06s / 3s | 4s |
| macOS Host | 35144970937, attempt 1 | 35145530809 | 11s / 2s | 4s |
| macOS Client | 35144970937, attempt 1 | 35145993419 | 6m26s / 16s | 14s |

These are dependency-phase times, not total-job benchmarks. OS package
installation, source checkout/key selection, fresh application builds/tests
and packaging still take time. Linux Host dependency-source checkout was about
4m19s in both runs, outside the bootstrap times shown.

Host and initial Mac runs used `478edad0ee302c22c713df1cb67b4c4c185340a5`;
the Mac Client warm run used docs-only successor `265fba442d690a18f85e7d232dae36241947c789`.
Ubuntu used `64f368a4fdb58cc0de267bc8f59ec108a8f43be8`, which adds its original
FFmpeg archive to the cache and required-file checks. That Ubuntu-only content
correction invalidates new cache keys without changing Host cache logic or
paths; Mac Host also passed cold run 35146543166 at that source.

The first Ubuntu warm experiment (35146202369) correctly failed the pristine-
source audit: patched sources and libraries alone are insufficient. Always
retain the original checksum-verified FFmpeg archive, which packaging extracts
for its full-source comparison. Do not disable that audit to accept a cache hit.

#### Historical v1 Mac Client qualification

The original Mac Client cache bundled native libraries and Qt under one key.
The historical runs below qualified that layout, not the new split groups.
Sources needed for licenses and independent patch verification are still
retained by v2; normal build and package checks remain mandatory.

GitHub also scopes cache access by branch. A cache saved only on one feature
branch is not available to a sibling feature branch, even with an identical
input key. Build main to populate the default-branch cache for future branches;
otherwise the first build on a new branch is cold. Do not weaken key matching
or change dependency pins to work around a normal scope miss.

PLANK and its tests build fresh. Application build trees, packages, Cargo objects,
signing material and credentials are not cached. Public pull requests may read
dependency caches but cannot save them through this workflow. Trusted jobs save
immediately after successful dependency bootstrap and independent cache sealing,
before application compilation, tests or packaging. A later product/test/notary
failure must not discard already verified dependencies. A failed bootstrap or
failed dependency verification still prevents saving; this is not an always-run
failure cache. Signed jobs bootstrap and save before injecting signing secrets
or creating a keychain, then retain their always-run signing cleanup. The signing
helper does not repeat product bootstrap. Cold-bootstrap bypass applies to every
product. The standalone fullscreen probe has no dependency cache.

To prove a fresh bootstrap, dispatch with `clean_bootstrap=true`, or use:

```bash
bash scripts/ci/dispatch.sh macos-client false --clean-bootstrap
```

This bypasses both cache restore and save. Omitting the option enables caching;
the first run for a new key is naturally cold. Cache availability and retention
are optimizations, not build requirements.

Qualification: cold unsigned run 35070457888 saved the cache after passing;
signed run 35071410245 restored the identical key after a Client-only change,
verified the required patch and completed all build/package gates. Bootstrap
took 6m32s cold versus 19s warm plus 29s restore. Do not compare total durations
as equivalent workloads: the second job additionally signed and notarized.

## Diagnosing a hosted build

Manual dispatch accepts `product=all`, `linux-host`, `linux-client`,
`macos-host` or `macos-client`. A selected-product run has an independent
concurrency group, so retrying it does not cancel other platforms. Inspect the
failed job's first error, not the final nonzero-exit summary.

Use `bash scripts/ci/dispatch.sh linux-host` (or another product) after pushing.
It requires a clean, fully pushed branch and passes its exact expected SHA.
The policy job rejects a stale dispatch revision before costly bootstrap.

Diagnostic-only `macos-fullscreen-probe` additionally requires `signed=true`.
It builds the standalone AppKit probe, not either product, and uses the same
protected environment/cleanup. It skips product dependency bootstrap entirely
and uploads a separate `diagnostics/` catalog with source/hash evidence. See
`probes/macos/fullscreen-window.md`; no ordinary push/PR signs this diagnostic.
Always compare a run's `headSha` with the intended commit: an immediate dispatch
after pushing can otherwise select the prior revision during ref propagation.

- Rocky container ownership: checkout is runner-owned while the container runs
  as root. `context.py` trusts only the exact workspace. Never use a wildcard
  `safe.directory` exception.
- Rocky minor-release drift: a 9.7 image's ordinary mirror configuration can
  follow the next 9.x release. Pin the 9.7 vault **before the first package
  transaction**, including Git/Python installation. The container's existing
  `curl-minimal` is sufficient; do not conflict with it by installing `curl`.
- `glad: jinja2 not found`: `python3-jinja2` is an explicit Host bootstrap
  prerequisite. Do not depend on a previous builder's Python environment or
  let CMake install ad hoc dependencies late in the build.
- Download HTTP 502/503: use bounded retries of the pinned input, retaining its
  SHA-256 gate. Do not change versions or accept a partial download.
- Node.js 20 deprecation: the Node runtime embedded in a GitHub Action is
  separate from the OS `node` executable. Current pinned checkout/artifact
  actions use Node.js 24; installing a newer OS Node does not update an old
  Action.
