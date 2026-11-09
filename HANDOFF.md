# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. This file is the current
checkpoint, not a chronological transcript. Private machine inventory, credentials
and captures remain outside Git. Earlier detailed results are preserved in
[the preceding checkpoint](https://github.com/instinctual/plank/blob/5f2d700c/HANDOFF.md),
the focused plans and the artifact catalog.

## Current state

PLANK **1.4.15 is published** at
[GitHub Releases](https://github.com/instinctual/plank/releases/tag/v1.4.15).
The root is on `macos-shared-directory`, based on main `df1ba7ba`; Linux Host,
Client and Kymux remain on main. The operator authorized a macOS Host correction
and installation on the affected Mac. Candidate version is 1.4.16. The earlier
startup correction from `macos-startup-config` is already merged and published.

## Active work — shared system directory permissions

Read-only diagnosis found a third-party installer changed
`/Library/Application Support` to root:admin 0775. PLANK's strict ancestor check
then rejected system identity loading when the desktop worker restarted. The
PLANK directories, keys and administrator configuration were correctly protected.
The older deployed candidate and current 1.4.15 contain the same check.

The correction allows only root:admin 0775 on that exact parent while opening
the canonical `/Library/Application Support/PLANK` system state. Protected leaf
directories, config/key ownership, no-symlink traversal and file/link checks
remain enforced. The installer/uninstaller shell preflight has a second
permission check; it receives the matching narrow exception. Neither path
changes the shared directory's permissions. Rejections now name the directory
and its metadata. Metrics remain disabled by default.

Candidate source is `ee30bffa3fd3fd4d137d619e3e9c43017155576f`. Signed Host run
`42691123177` passed native path-policy, real configuration-filesystem,
complete-startup, permissions and installer gates. Signing, notarization,
stapling and Gatekeeper checks passed. Native fixtures cover the accepted parent
and unsafe owners, groups, modes, lookalike paths and leaves; filesystem fixtures
retain the negative writable-ancestor and link checks. Portable installer tests
pass 41 checks; local source-policy tests pass 138 checks. Mac-only fixtures
skipped locally ran on the hosted Mac worker.

Package:
`artifacts/packages/candidates/1.4.16-macos-shared-directory/macos/plank-host_1.4.16-macos-shared-directory_arm64.pkg`.
SHA256: `733095c2dc0154c7ba43370cb67512c9553362f5ed7453c5acdbae78d48eac5a`.
Installed executable SHA256:
`87c3821be72409607134f9fb8613cafdba1a94e72ddc4fe3e0ccb11a3915d787`.

The exact signed package is installed on the authorized affected Mac. FileVault
was unexpectedly enabled; the operator separately authorized disabling it, and
the installer ran only after the OS reported it off. No reboot or logout was
performed. The desktop worker remains running on its first launch, and local
and network `/serverinfo` requests return HTTP 200. Configuration, workstation
identity and machine/user private-key hashes are unchanged. The shared parent
remains root:admin0775 and the PLANK leaf root:admin0755. This directly exercises
the repaired condition without modifying another application's shared directory.

Installed interactive-session acceptance is still pending. Evidence and builder
manifests are in `artifacts/qualification/macos-shared-directory-1.4.16`; raw
machine/CI data and access details remain private. Local and target staging are
removed. No merge or release is requested. Preserve the affected user's desktop
and never reboot automatically. The temporary exact-branch signing permission
remains until this branch is retired.

The annotated release tag points to the exact package source
`529f4ce2fffc9fdef2f9f09ec981844a742149d3`. Later root commits update documentation;
do not move the tag or relabel installers to match them.

| Source | Release revision |
| --- | --- |
| Linux Host | `c71333d72cf43843a79a77df82f521547682d6c5` |
| Client | `8faa3274b9258789ad714b8d16c5ff72e13afe5c` |
| Kymux | `9e1a7e304abe4ad6b42a7a10ef41eae2b16fb31f` |
| Client common-C | `c7d1b83143be1511735526ae8ce75a6d5c25f63c` |

The Client changes after accepted runtime `821e77da` are release notes only.
Native Apple/AVP development remains separate; see the retained-branches section.

## Published packages and validation

All four packages are in `artifacts/packages/releases/1.4.15/` and attached
to the GitHub release. Original builder manifests, package/source hashes and
combined checksums match. All build jobs passed on their first attempt.
Both Mac PKGs are signed, notarized, stapled and Gatekeeper-accepted.
The public manifest/checksums use download basenames; the local catalog retains
platform-relative paths. All six published asset sizes and digests were verified
before and after publication.

| Product | Successful workflow | Package |
| --- | --- | --- |
| Linux Host | `42538556286` | `linux/plank-host-1.4.15-1.el9.x86_64.rpm` |
| Ubuntu Client | `42538556286` | `linux/plank-client_1.4.15_amd64.deb` |
| macOS Host | `42538578630` | `macos/plank-host_1.4.15_arm64.pkg` |
| macOS Client | `42538581633` | `macos/plank-client_1.4.15_arm64.pkg` |

Host targets remain Rocky 9.7 and macOS 26.7+; Clients remain Ubuntu 26.04
and macOS 15+. Apple packages are Apple Silicon. SDK27 build/regression gates
remain; Chris owns macOS 26.7 installed validation.

Privacy and clipboard gates passed. Linux transport passed three 900-frame,
150 Mbps loss matrices with zero unrecovered data and zero proxy kernel drops.
Hosted Mac functional checks and the complete-configuration startup regression
passed. Transport sources are unchanged from 1.4.12; its retained Mac hardware
qualification covered three identical-load matrices with zero unrecovered frames.
That exact test executable's SHA256 is
`999dd66f6d26a8aaf00019fa4c50aadf573472ec47f8fd4aaedc2bfafbb5942b`;
evidence remains in `artifacts/qualification/mainline-1.4.12/`.
No new Mac performance soak or mainline package installation was performed.

Current evidence, recursive source pins, Qt compositor/input reports and
publication metadata are in `artifacts/qualification/mainline-1.4.15/`.
Raw CI logs remain private. Download staging has been removed.
[Release notes](docs/releases/1.4.15.md) describe the startup fix, Native10 buffer
reuse, faster builds and the unresolved tearing limitation.

## Installed macOS startup correction

The authorized development Mac last had the signed
**1.4.15-macos-startup-config** candidate installed, not the later mainline PKG.
Installation succeeded without rebooting. The installed executable matches the
package payload, its signature passes, machine/sign-in workers stay running and
the control endpoint responds HTTP 200. Configuration and workstation identity
hashes are unchanged. Interactive login-to-desktop/session acceptance has not
yet been recorded for this correction.

Candidate source: `f837e8786665f55d0e07cb5463a0913c49ca3b85`.
Signed build: `42531269265`.
Package:
`artifacts/packages/candidates/1.4.15-macos-startup-config/macos/plank-host_1.4.15-macos-startup-config_arm64.pkg`.
Package SHA256:
`1714ae12436a20a5cdffb3e5469895e2d2bb38cad73822606e13978729c2774c`.
Installed executable SHA256:
`4b9702ed3fe0ef88b0b97124408265ca0778197c88e3ba1c117c5f90ab963131`.

Cause: metrics commit `510ccae1` added a defaulted internal configuration field.
The complete dictionary gained an eighth field, including UUID, while graphical
startup still required exactly seven. The worker rejected valid configuration
even with metrics off. Host 1.4.11–1.4.14 are affected; do not deploy or publish
the older Mac Host installers based on their earlier successful package checks.

The fix validates startup-required fields instead of dictionary size. Existing
type, integer-port, file-permission, identity and strict INI checks remain.
The native filesystem fixture now tests the complete reader/identity/startup
boundary, including omitted, disabled, enabled and invalid optional metrics.
Both candidate and mainline builds report
`startup_configuration_pass=1 metrics_default_off=1`.

**Metrics must default off on macOS Host and Client.** Both implementations and
templates already do, and the fix preserves that behavior. The target's metrics
configuration was disabled. Metrics use UDP export to a local Telegraf listener;
a closed TCP port is not evidence about that UDP collector.

Access details, installed-state observations and pending session acceptance are
in private notes. Installation staging is removed and the supplied sudo password
was not persisted. No additional deployment or reboot is queued.

## Build workflow to preserve

Use the [release runbook](docs/development/build/release-build-runbook.md) and
[hosted-build guide](docs/development/build/github-builds.md).
All four products reuse verified dependency caches. Linux Host and Ubuntu Client
also reuse validated compiler outputs; Mac application/transport objects compile
fresh. Clean source/build directories, fresh linking, tests, package verification,
signing and full CUDA architecture coverage remain mandatory.

For 1.4.15, compiler hits were Host **337 C/C++, 151 Rust, six CUDA** and
Client **250 C/C++, 66 Rust**. Earlier matched Host cache qualification reduced
worker time from **15m58s to 6m43s**, with identical Host binary digests.
These are observations, not promised build durations. The four Host C/C++ cache
error counters include expected negative preprocessing checks; cache I/O errors
and timeouts were zero in the qualification.

Inspect existing workflow runs at the exact source SHA before dispatching more.
For this release, the automatic main push supplied both Linux packages; only
signed Mac builds needed separate dispatch. Do not duplicate an applicable
running/successful Linux job merely to call it a release build. Documentation-only
checkpoints do not require rebuilding the already verified source.
Use clean-bootstrap only for explicit bootstrap/dependency qualification.

For a future authorized Native10 component experiment, use
`linux-native10-tests` before a full Host package build. It qualifies the actual
production headers and exports GPU probes without rebuilding the media stack.
It does not replace full package or installed-stream acceptance.
Details and measurements are in
[the build iteration plan](docs/development/plans/host-build-iteration.plan).

## Native10 state

Bounded buffer reuse and timing are accepted and merged. The last verified
hardware-test Host installation was **1.4.13-native10-buffer-reuse**, from root
`b57e0796` / Host `35a44af8`; private inventory holds deployment details.
The operator reported normal playback after a Native10/HEVC NVENC 5120×2160
session of 68,450 frames over approximately 19 minutes, averaging 16.6674 ms
between encoded packets. It used two initial pool allocations with no retirements
or allocation failures. Reconnect left only the two current SHM segments.
Configuration was preserved and the desktop application stayed open.

This supports reducing allocation/registration stalls, not a matched FPS, CPU
or whole-stream latency gain. XShm readback still dominates. Installed x264
acceptance was not repeated; buffer/color fixtures passed. See
[the buffer plan](docs/development/plans/native10-buffer-reuse.plan) and
`artifacts/qualification/native10-buffer-reuse-1.4.13/`.

**The tearing investigation is paused by the operator.** Mixed frames were
observed before encoding; extra copying, fences, refresh alignment and temporary
NVIDIA composition settings did not reliably fix it. The final source-fence
control still mixed 5/450 frames. The `native10-coherence` diagnostic branch was
deleted without merging experimental capture code. Original display settings
were restored; observers, loss injection and remote probe staging were removed.
Do not resume without operator direction and a concrete new lead. Unchanged-
screen filtering was explicitly excluded; GPU-resident capture remains deferred.

## Metrics and provisioning

Metrics/Wacom observation work is merged. The shared optional exporter sends
bounded Influx line-protocol datagrams over IPv4 loopback to Telegraf, normally
UDP 28991. PLANK contains no database token, remote collector listener, new
transport lane or Telegraf service installation. Disabled metrics create no
activity observer. Schema/configuration: [metrics guide](docs/user/metrics.md);
implementation and evidence: [metrics plan](docs/development/plans/metrics-telegraf.plan).

The operator selected InfluxDB 2, existing InfluxQL Grafana queries and local
Telegraf on Linux Hosts/Clients. Linux collection and real Client/Host metrics
were verified. Macs have no separately installed Telegraf agent for this work.
Addresses, bucket/data-source identities, credentials and the private provisioner's
current state remain outside this public repository.

Ubuntu Wacom activity covers active PLANK sessions only, to either Host OS.
It records movement/tip-down counts and observation availability, not coordinates,
strokes, pressure values or tool identities. Physical workstation-only use is
excluded. Dashboard Wacom reporting uses one-second buckets with no activity hold;
missing observations remain distinct from measured idle. The exporter's separate
recent-activity state retains its one-minute definition. These are interaction
observations, not conclusions about productivity or attendance.

The final dashboard has eleven panels and 25 visual queries, separate Hosts and
Clients selectors, no bookmark grouping, `fill(none)`, and Table legends using
Last non-null values. Encoder Target is Host-only. Generic activity, queue,
observation/event and statistics-age panels were removed. Real pen records and
queries were verified; no synthetic activity was written to the live database.

The private appliance repository owns its provisioning/credential policy.
Public builds never depend on it. Fresh-appliance provisioning acceptance remains
separate; consult that repository's current handoff rather than old deployment
instructions here. No fleet rollout is queued.

## Shared baseline and retained work

Accepted hardening is on main; see
[the completed checklist](docs/development/plans/code-review-hardening.md).
Shared video FEC is source-first, with a 4 MiB outgoing queue, 2 MiB minimum
in-flight window and 1 Gbps controller budget. There is no application datagram
pacer or unbounded queue. Reliable-data pressure pauses/resumes reads; explicit
takeover and security failures remain terminal. Local C ABI is 14 and ALPN is
`plank-native/2`; rebuild static consumers against matching headers.

Native Apple/AVP work remains on parent `avp-dual-display` at `f96a1b81` and
Client `7580c06f`, in `build/worktrees/native-builds`. Earlier
`apple-native-integration` and `native-builds` checkpoints are contained there.
Vision TestFlight 0.1.0 (13.1) was delivered; headset acceptance remains pending.
Read that branch's HANDOFF and retain its protocol pin when resuming. Rebasing to
C ABI 14 requires removing the obsolete `config.session_mode` assignment and
`SETUP_READY` allowance. Do not merge or delete this work as desktop cleanup.

Retain `codex/macos26-host-test` and `macos-host-test`: both serve approved
contributor testing/signing workflows even though their source changes are in
main. Their signing/approval policies were checked on November 8. Main protection
was discussed, not enabled. `macos-startup-config` is fully merged but its branch
and temporary signing permission remain; inspect live policies before retiring it.
The 31 previously approved obsolete branches and the old #26/#13 dependency
branches were deleted; neither dependency PR is unfinished work.

## Next work and qualification limits

Wait for the operator's next task. No rebuild, remote probe or rollback is
required to complete this checkpoint. The useful remaining check for the startup
fix is a normal interactive connection through login into the desktop, when the
operator chooses to test it. Preserve Terminal and active sessions on the
authorized development Mac; never reboot automatically.

Package/loopback results are not blanket installed hardware acceptance. Retain
the platform-specific gates in [acceptance criteria](docs/development/acceptance-criteria.md):
capture/encode and exact-format 10-bit decoding/presentation, 4K/5K and multi-display
modes, Wacom/Tablet Margins and recovery, A/V listening/synchronization, microphone,
camera, clipboard, Mac permissions/uninstall and login/locked takeover.
Chris owns the identical Host package's macOS 26.7 session validation; Client
compatibility remains macOS 15 and 27.

Intel NUC Gen11 is unqualified and its GPU-hang investigation remains stopped;
do not restore it to acceptance or add a runtime generation blacklist.
The earlier surface-timeout investigation is also paused. Wallpaper/Screen Saver
pointer lag, Linux physical-display provenance, application hotkeys and
immediate-paste stress remain separate deferred work. Earlier detailed release
and failed-test records remain in Git history and their qualification directories;
they are evidence, not instructions to publish superseded packages.
