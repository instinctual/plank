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
floor does not lower the builder SDK requirement or change the Host's26.7
minimum. Exact cache keys include the Client deployment policy; old
27-minimum dependencies are not reused. Native target-validation fixtures run
in the Client build, and PKG packaging checks every bundled binary and the app
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
tablet acceptance. A separate link-wrapped UHID fixture then exercises the real
input/reservation lifecycle for 25 shuffled repetitions without kernel devices.
It verifies endpoint retention/replacement and shutdown, not real hid-wacom
probing. Keep mouse/Wacom disconnect/reconnect qualification as a separate
hardware gate.

Feature builds retain their branch-qualified visible and package versions.
These jobs do not install products or perform live display, audio, input,
network-loss or hardware-decoder qualification. Existing hardware gates and
local builders remain available until hosted builds are qualified.

## Local downloads and cleanup

Use one task-specific staging directory under `build/` when downloading hosted
artifacts. Verify the original manifest and SHA-256, then collect packages with
`scripts/package/collect-package.py` into the versioned catalog and retain test
reports under `artifacts/qualification/`. Once verified, remove that exact
staging directory; do not leave duplicate installers or extracted payloads in
multiple download folders.

`build/worktrees/` is for active source worktrees, not a permanent archive of
reviews. Before retiring one, check its root and nested repositories for loose
edits and unpublished commits. Preserve unfinished native Apple work. Keep
private recovery copies outside Git, and never delete canonical Git metadata,
prepared dependencies, accepted package catalogs or qualification reports as
part of scratch cleanup.

## Ubuntu Qt Client qualification

Qt is the ordinary Ubuntu Client from 1.2.00. The `linux-client` job runs on
push/PR and through `bash scripts/ci/dispatch.sh linux-client false` from a
clean, pushed main or feature branch. It uses the verified Client dependency
caches/bootstrap, then runs package-upgrade fixtures, normal/sanitized component
tests and a private headless GNOME compositor at 100% and forced 125% scale.
It also checks selected-output retention on two differently sized virtual
monitors. Fullscreen startup and normal content-size restoration must pass
without treating a requested window state as proof of completed native sizing.

Toolbar tests and the standalone probe select the real launcher's Material
Dark/Dense style. Keep explicit content-size, rendered-glyph, idle/hover/press
and invisible-hit-target checks at both scales. The Linux raw-HID Wacom adapter
runs with wrapped device I/O normally and under ASan/UBSan/leak checks.
Evidence is in `wacom.log` and `wacom-asan.log`; coverage includes USB
renumbering, partial enumeration, pen evdev readiness, I/O loss and reconnects.
See the release runbook's fortified-I/O and stale-preflight failure signatures
before retrying a failed job; do not skip those gates.

The job builds one complete Client with all ordinary preflight checks, requires
native PipeWire playback rather than SDL audio, and checks three real
launcher/shutdown cycles with SDL video deliberately unavailable. It packages
that exact binary under `plank-client`, validates source/linkage and package
identity, and collects it in the normal mainline or candidate catalog.
Existing bookmarks, trust, policy and logs keep their ordinary PLANK locations.
The old independently installable `plank-client-qt` test app is retired.

Software Vulkan/GL and private PipeWire null-sink tests do not qualify Intel
VA-API decoding, physical input, audible playback, A/V sync or live performance.
Do not use the retained Ubuntu VM as a fallback builder. No product is installed
on the hosted builder; package-upgrade fixtures use disposable synthetic roots.

## macOS distribution credentials

Ordinary CI intentionally has no Apple credentials. Its unsigned results are
not end-user installers. Signed, notarized PKG publication requires a
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
enabled for explicitly reviewed branches; do not replace them
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

### Approved contributor Host test builds

Chris (`cnoellert`) can request a signed macOS Host candidate by posting a new
PR Conversation comment containing exactly:

```text
/build-macos-host
```

The project owner can use the same command. Account authorization uses immutable
GitHub user IDs. No repository write access, personal access token or Apple
credential is given to the requester. A reply links the build and its artifact;
after success, download the signed Host PKG from that run. Artifacts expire
after seven days. This command does not merge, release or install anything.

Before enabling a PR, a maintainer must review its source, including executable
build/test scripts and dependencies. Prepare a candidate from current main and
that reviewed PR revision, assign a new candidate version, run portable checks,
and push it to `macos-host-test` (or an explicitly reviewed
`macos-host-test-...` branch). Add only that exact branch to `macos-signing`'s
deployment branch policies. Record its full SHA, the reviewed PR head SHA, PR
author ID and fork repository ID in `.github/macos-host-test-approvals.json` on
main. The PR feature itself need not be merged to main.

`request-macos-host-build.yml` handles newly created PR comments using only the
default branch's controller and approval registry. It does not check out PR
code or receive signing secrets. It rechecks the live comment, open PR identity,
reviewed head and exact candidate branch SHA, then dispatches the existing
`build.yml` with fixed inputs: `macos-host`, signed, minimum26.7, exact source SHA,
and ordinary dependency-cache reuse. The existing build policy checks the SHA
again before the environment-protected signing job. Its limited Actions token
can dispatch a workflow; this event is one of GitHub's documented exceptions to
token-triggered workflow suppression. See [GitHub's workflow trigger rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).

An updated PR or moved test branch requires a fresh maintainer review and
approval-registry commit. Approval of one revision is not approval of future
changes. Editing a comment or rerunning a request job does not authorize another
build: post a new command. Concurrent requests reuse an already-running build
for the same source. Retiring the candidate means removing its registry entry
and its exact environment branch permission. Do not use wildcard branches or
`pull_request_target` to execute contributor code with credentials.

Hosted builds qualify compilation, component checks, signing and packaging.
Chris still owns installed macOS26.7 testing; the identical package needs the
ordinary macOS27 regression checks before feature acceptance.

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
| Ubuntu Client | Rust toolchain; Cargo downloads; FFmpeg libraries/source/archive; private SDL libraries/source/archive |
| macOS Host | Rust toolchain; Cargo downloads (capture/encoding/audio use Apple frameworks) |
| macOS Client | Rust toolchain; Cargo downloads; native-library install/source/download tree; Qt |

The Linux Host FFmpeg/x264/x265 build tree is one coupled cache.
Ubuntu's patched SDL has a separate native-library cache, keyed to its pinned
archive, repair, verifier, regression test and build recipe. Restore verifies
the patched source tree and installed bytes; application/package preflight
verifies them again. No system library is replaced.

Mac FFmpeg, OpenSSL, SDL, FreeType, Opus and pkgconf remain a coupled group because
their current bootstrap shares one installation prefix. Never restore
overlapping directories from independent keys. Qt is outside that prefix.

`scripts/ci/dependencies/` contains the existing build recipes, split so each
fingerprint hashes only its own preparation commands, versions, flags and
required patches. Keep such inputs in the relevant recipe, not in the shared
`bootstrap.sh` orchestration wrapper. The Host FFmpeg group additionally hashes
the build-deps Git pin, tracked files and source gitlinks. Both Client library
groups retain all FFmpeg patch inputs and build-path/sanitization helpers.

Rust toolchain changes invalidate Rust and Cargo downloads; transport and
vendor-test manifests/locks invalidate only their Cargo group. Linux Host
library keys retain the exact installed package inventory; Mac keys retain
SDK/compiler/build tools. Ubuntu keys use the qualified OS/architecture, actual
compiler/build-tool versions, development packages and relevant ABI/protocol
packages, not the runner image date or unrelated desktop/runtime packages.
Native development packages remain conservative inputs because FFmpeg and SDL
auto-detect optional libraries. Unrelated PHP SDK packages are excluded: neither
library uses them, and GitHub image updates can change PHP independently.
Downloads/source-only groups do not depend on those C/C++ build tools.
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
and compiled target objects. Dependency caches never contain application,
package or signing state. Ubuntu's separate per-object compiler cache is
described below; the other product jobs still compile application sources fresh.

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

### Ubuntu compiler-output reuse

The Ubuntu job additionally uses the distro `sccache` tool for C/C++ and Rust.
Job-local compiler-name wrappers point to the real `/usr/bin/` compilers through
sccache; no system compiler, user machine or shipped runtime is replaced.
Rust uses `RUSTC_WRAPPER` with incremental compilation disabled. Cache entries
are compiler results, not reused build trees, complete executables or installers.
Cargo's cc-rs also recognizes that wrapper, so `HOST_CC`/`HOST_CXX` name the
real `/usr/bin/` compilers rather than wrapping the PATH wrappers a second time.
A small hosted compile check validates both invocation forms before the suite.
Every run creates clean sources/build directories, runs the existing tests,
links and packages the selected version, and verifies the finished DEB.

Only the bounded job-local `compiler-cache` directory is archived. The wrapper,
server socket, reports, Cargo configuration/credentials and signing material are
not included. Caches restore within GitHub's existing branch/default-branch
boundaries; public pull requests cannot save them. Save occurs only after a
successful build and tests. A unique run key permits updating immutable cache
snapshots. Prefix restores are permitted **only for this compiler cache**:
sccache independently checks each compiler/source/header/flag input. Prepared
dependency caches still require an exact receipt and source/patch verification.

`clean_bootstrap=true` bypasses both kinds of cache. Compiler hit/miss statistics
are retained in the Qt qualification artifact and job summary, including failed
builds when setup succeeded. A second identical hosted run must demonstrate
actual C/C++ and Rust hits and unchanged qualification gates; a successful cache
upload alone does not qualify reuse. A first build after this policy change is
expected to populate new keys once. Do not bypass branch isolation to import
feature-branch artifacts into main.

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
`macos-host` or `macos-client`.
A selected-product run has an independent
concurrency group, so retrying it does not cancel other platforms. Inspect the
failed job's first error, not the final nonzero-exit summary.

Use `bash scripts/ci/dispatch.sh linux-host` (or another product) after pushing.
It requires a clean, fully pushed branch and passes its exact expected SHA.
The policy job rejects a stale dispatch revision before costly bootstrap.

### macOS 26.7 Host build

The standard Host package now targets **26.7** and runs on 26.7 and newer.
Normal push/PR builds, mainline dispatch and signed Host packaging all use this
minimum. The runner stays Apple Silicon macOS27/SDK27, so the same binary and
component tests continue to exercise macOS27. Keep newer APIs behind runtime
availability checks. Client minimum15.0 and Linux policies are independent.
Chris (cnoellert) owns 26.7 installed qualification; validate the identical
signed package on both 26.7 and 27 before recording shared-package acceptance.

From a clean, pushed main checkout, use the ordinary signed Host dispatch:

```sh
bash scripts/ci/dispatch.sh macos-host true
```

`--macos-host-min-os=26.7` remains an explicit equivalent. For a regression
comparison only, a reviewed candidate branch may request
`--macos-host-min-os=27.0`. That alternative is rejected for main, tags,
other products and ordinary push/PR runs; it does not create a second release
package. Both targets still require SDK27. Workflow concurrency separates the
targets, and Host cache entries contain toolchains/downloaded sources rather
than compiled Host objects. Every run rebuilds the transport for its target.

Mainline retains the ordinary filename, such as `plank-host_1.2.05_arm64.pkg`,
with `target_os=macos-26.7` in the manifest. Candidates retain their branch and
floor suffix, allowing a comparison pair without overwrite. Historical 27-only
packages keep their exact names, bytes and original metadata. The collector
rejects conflicting bytes or provenance, including changing an existing
package's claimed OS floor. Never retarget or relabel signed installers.

The dispatch helper checks the exact pushed source commit. Protected signing
still requires explicit dispatch and a permitted branch; public push/PR jobs
receive no signing credentials. Main is already permitted. For candidate
signing, allow only the reviewed exact branch and remove that permission when
retiring it. Do not broaden the environment to every branch.

Download with the normal runbook, verify the original checksum and source
manifest, and collect the installer without changing its identity. Passing
component, signing, notarization and package gates is not installed session
acceptance. See the [Host plan](../plans/macos26-host-backport.md) for remaining
26.7/27 validation and the distinction from the earlier baseline candidate.

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
