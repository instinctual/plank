# Dependency maintenance

Dependabot proposes updates; it does not qualify or merge them. Keep automatic
merging disabled. The packaged release's exact gitlinks and lockfiles remain
the source of truth, not a dependency repository's newest branch tip.

## Repository coverage

| Repository | Version-update target | Inputs |
| --- | --- | --- |
| `instinctual/plank` | `main` | GitHub Actions, three product submodules, transport and probe Cargo manifests/locks |
| `instinctual/plank-host-linux` | `main` | Allowlisted build/runtime submodules; no inherited Windows/gamepad/Flatpak updates |
| `instinctual/plank-client` | `main` | Common-C and qmdnsengine submodules |
| `instinctual/plank-kymux` | `main` | Cargo workspace |
| `instinctual/plank-build-deps` | `plank/main` | FFmpeg release/8.1, x264/x265, NV headers, AMF, paired Vulkan Headers/Loader |
| `instinctual/plank-libvirtualhid` | `plank/main` | Build/documentation submodules |
| `instinctual/plank-common-c` | `plank/client`, `plank/host` | Source review only: no dependency manifests/recursive dependencies on either maintained branch |

Version checks run weekly on Monday, with at most three open version PRs per
update entry. Vulkan Headers and Loader are grouped for coordinated review.
GitHub Actions updates are grouped; retain full commit-SHA pins. Other runtime
updates remain individual proposals. Security updates have GitHub's separate
limits and are not delayed until the weekly version check.

GitHub loads `.github/dependabot.yml` from the default branch. Build-deps and
libvirtualhid retain `master` as their inherited default; their configuration
is present on both `master` and `plank/main`, with `target-branch: plank/main`.
Common-C's inherited `atomics` default is not a PLANK build input. Do not schedule
its old ENet/nanors dependencies. Host and Client `.gitmodules` explicitly track
`plank/host` and `plank/client`, respectively. Root submodules track `main`.
These branch hints affect update proposals; ordinary checkouts stay at exact
committed gitlinks. Do not use `git submodule update --remote` for releases.

Repository security alerts and automatic security-fix PRs are enabled for all
seven repositories. They cover supported, recognized manifests, not arbitrary
vendored C/C++ sources, shell downloads or everything in a submodule. GitHub
security-update PRs target the default branch; `target-branch` is for version
updates only. Consequently the maintained non-default branches need manual
advisory review too. No security-alert finding is automatically accepted.

Companion repositories' inherited Actions build workflows remain disabled.
Dependabot does not require re-enabling those obsolete product builds. Use the
root's qualified hosted builds to validate integration. No public PR receives
signing credentials, deployment access, private registry credentials, or an
internal runner. Inherited Renovate policies are disabled where Dependabot now
owns updates, avoiding a second bot following an unrelated upstream policy.

## Inputs Dependabot does not update

Review this inventory weekly and before a release, including upstream security
advisories. Versions below describe the setup baseline, not a promise that they
are latest. Change the owning source and all corresponding checks/cache inputs
together; do not treat this table as another build manifest.

| Input / baseline | Owning source and required related checks |
| --- | --- |
| Rust/Cargo 1.89.0; rustup 1.28.2 | `rust-toolchain.toml`, `scripts/ci/bootstrap.sh`, Host/Client package builders and Mac transport builder; update exact-toolchain assertions together |
| Qt 6.10.2; aqtinstall 3.3.0 | `scripts/ci/bootstrap.sh`, `scripts/ci/install-linux-deps.sh`, Mac Client builder and dependency-cache scripts; Ubuntu's Qt is distribution-provided |
| Boost 1.89.0 | `scripts/ci/bootstrap.sh` URL/checksum, Host `cmake/dependencies/Boost_Sunshine.cmake`, Host package preflight and cache paths |
| Client FFmpeg 9.0.1 | `scripts/build/build-client-ffmpeg.sh`, `scripts/build/bootstrap-macos-client-deps.sh`, `apps/client/app/deploy/linux/ffmpeg-patches/`, package preflight and cache verification; mandatory identity patches must apply or be proven applied |
| Mac Client OpenSSL 3.5.5, Opus 1.5.2, SDL 3.4.2, SDL_ttf 3.2.2, FreeType 2.14.1 | URLs and SHA256 values in `scripts/build/bootstrap-macos-client-deps.sh`; Linux variants come from its distribution packages |
| Host libva 2.24.1 and CMake-fetched dependencies | Build-deps `package-lock.cmake`; Host dependency CMake files and package lock; inspect fetched tags/URLs/checksums, including test-only inputs |
| Qualified OS, compiler, CUDA and Apple SDK | `.github/workflows/build.yml`, `scripts/ci/install-linux-deps.sh`, bootstrap and runbooks; do not silently change the platform support contract |
| OS libraries and build tools | Distribution installs in `scripts/ci/install-linux-deps.sh` and macOS workflow setup; keep package inventories from builds, and verify runtime dependency closure |
| Downloaded CI utilities (including Gitleaks) | URLs/checksums and package installs embedded in `.github/workflows/`; Actions monitoring updates `uses:` references, not arbitrary commands inside `run:` blocks |
| Vendored libraries/headers | Client h264bitstream, Host NvFBC headers and other non-submodule sources; review upstream security/source changes manually |

### Quinn and Vulkan exceptions

Quinn/Quinn-proto automatic PRs are intentionally excluded from the root and
Kymux schedules, including automatic security fixes. Security alerts remain
enabled; these dependencies require manual advisory triage and repairs.
Production and probes share the repaired
`third_party/quinn-proto-0.11.17` source via Cargo patches. Review upstream
security advisories manually, including RustSec reports, and upgrade the fork,
callers, both lockfiles and documented repairs together. Never remove that path
override merely to make a bot PR compile. The vendored crate's own Cargo.lock
is not the production dependency lockfile.

The pinned Vulkan Loader is 1.4.362, commit
`b8b96a2862bff1eed468e602d43f706beae89cf1`, with the required ID-filter
allocation repair in build-deps. It returns `VK_ERROR_OUT_OF_HOST_MEMORY` and
propagates failure through both enumeration APIs and cleanup. Bootstrap, cache
validation and package preflight require that patch; a newer Loader must not
silently drop it. Twelve fault-injection cases failed on the unpatched candidate
and passed with the repair; the repaired candidate passed 713 Loader tests.
Retain/reproduce those negative controls when upgrading the changed allocation
code. The [qualification record](reviews/vulkan-loader-qualification.md) records
the clean Host build and hardware checks without implying new Vulkan encoding
support or complete interactive acceptance. NVIDIA remains capped at 595.91.07.

## Upgrade sequence and acceptance

RaptorQ upgrades require a coordinated Host/Client wire qualification, not just
a passing Cargo build. The 1.x-to-2.x transition changes repair-symbol IDs;
mixed versions can reconstruct incorrect bytes. Native generation
`plank-native/2` rejects the old `kymux` ALPN during TLS, with no compatibility
fallback. Keep the exact KyProto dependency pin, both product/probe lockfiles,
FEC validator and byte-level vectors synchronized. See the
[native transport contract](../../protocol/plank-transport/README.md#native-wire-generation-and-raptorq)
and [RaptorQ qualification record](reviews/raptorq-2-qualification.md).

1. Triage security advisories first. Determine whether the affected version and
   feature are actually shipped; absence of a GitHub alert is not proof of safety.
2. Update build-only tools/Actions separately from runtime dependencies. Keep
   version and source hashes reproducible; no floating dependency downloads.
3. Update runtime dependencies in small batches. Preserve required patches,
   codec precision, RGB identity, ABI and supported OS contracts. Bot PRs against
   component repositories are not automatically release-ready.
4. Commit/push nested dependencies before parent gitlinks. Refresh both transport
   and probe locks when the shared Rust graph changes. Verify `cargo ... --locked`
   succeeds with the qualified compiler; do not accept an implicit MSRV increase.
5. Follow the release runbook for clean bootstrap builds of affected products,
   cache invalidation/verification, package dependency closure and patch gates.
   Media/input/network changes also require the matching hardware, color,
   audio/video sync, Wacom and intentional-loss acceptance tests.
6. Manually merge only after those checks, then rebuild from main. Do not relabel
   candidate packages. Record the exact release commits and remaining gates in
   HANDOFF. Never turn on auto-merge as a substitute for these gates.

At setup time no production gitlink, Cargo lockfile, library version or package
was changed. The next work is advisory triage and focused upgrade proposals,
not an unqualified all-dependencies update.

References: [Dependabot configuration](https://docs.github.com/en/code-security/concepts/supply-chain-security/about-the-dependabot-yml-file),
[configuration options](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference),
[supported ecosystems](https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories),
[Dependabot runners](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependabot-on-actions).
