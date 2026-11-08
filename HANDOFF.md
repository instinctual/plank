# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Machine inventory,
credentials and private captures stay outside Git. This file records current
state; older detailed results remain in Git history and the artifact catalog.

The parent and Linux Host checkouts are on `main`. The operator approved merging
`native10-buffer-reuse` and `host-build-iteration`; parent main includes their
tested checkpoint `5db5e16e`, with Linux Host `c71333d7`. This was a fast-forward
of the qualified changes, with no new production-code edits. Client main remains
`d8cdba22`. Earlier metrics/provisioning work is already merged; the private
appliance repository remains on `master`.

The operator paused the Native10 tearing investigation on November 8 and
requested deletion of `native10-coherence`. That branch is removed locally and
on GitHub; its experimental probes and capture changes were not merged. The
accepted buffer-reuse and build improvements remain on main.

Known limitation: real numbered playback can contain mixed raw frames before
encoding. Extra copies, GPU/X11 fences, refresh alignment and temporary NVIDIA
composition changes did not reliably fix it. The matched source-fence control
still mixed 5/450 frames; the composition option also failed. Do not present
earlier short clean samples as acceptance or silently substitute 8-bit capture.
Detailed evidence is retained in private notes and the local qualification
catalog. All observers/staging are removed, the exact original display settings
are restored, and Host/Flame processes were preserved. Resume only with operator
direction and a concrete new lead. Native Apple and approved contributor
test/signing branches remain retained; none depended on the retired branch.

Mainline Hosted `42467203193` passed all four products; Clipboard `42467203177`
passed. Privacy `42467203179` passed on its third unchanged attempt after two
HTTP 504 failures downloading Gitleaks before scanning. These build checks are
separate from installed-session acceptance and signed release packaging.

Package base version is 1.4.14; the latest published release remains 1.4.12.
No new manual package build, installation or release was requested for this
merge. Existing branch-qualified artifacts retain their original provenance.

## Fast Host iteration — qualified and merged

The operator authorized a fast component path and Host compiler-output caching.
Root/Host branch `host-build-iteration` starts from buffer candidate root `b57e0796`
/ Host `35a44af8`; Host `c71333d7` scopes package version/commit definitions to the
only two translation units that consume them. Candidate base version is 1.4.14.
No Client or macOS product source changed.

`linux-native10-tests` runs normal/sanitized capture tests, actual version-policy
compilation and exports hardware probes without preparing FFmpeg/Boost/Rust or
building an RPM. The full Host job adds pinned sccache C/C++/CUDA/Rust output reuse,
with clean source/build trees, final linking, all tests, full CUDA architecture
coverage and trusted-success cache saves preserved. Ubuntu and dependency cache
keys are unchanged. See [the plan](docs/development/plans/host-build-iteration.plan).

138 local CI policy tests and the real CMake version-bump fixture pass. Hosted
fast run `42452469409` finished in 50 seconds on the worker, with 13 seconds for
component work. Its two GPU probes are byte-identical to the hardware-tested pair.
Host source preparation fetches exact shallow revisions instead of full fork
histories; dependency source pins, keys and patch validation remain unchanged.

Cold run `42453181286` and warm run `42454396831` both passed all full Host gates
at root `eb2f8c3855454e6b71b1fe6af7fce80e97bea7b5` / Host `c71333d7`:
worker duration **15m58s → 6m43s**, build/test/package step **11m52s → 3m07s**.
Warm reuse: C/C++ 339 hits/57 misses, Rust 151/1, NVCC 6/0. Both jobs report four
C++ cache-error counters; the counter also includes expected preprocessing
failures, reproduced with a negative fixture. Cache read/write errors and
timeouts were zero. The complete diagnostics are retained. All three installed
Host binary digests are identical between cold and warm RPMs.

Verified warm package:
`artifacts/packages/candidates/1.4.14-host-build-iteration/linux/plank-host-1.4.14-0.host_build_iteration.1.el9.x86_64.rpm`,
SHA256 `cf75408a0873d22d30587037f6c4674d5e53a63cb4ce0fd4427cad4d3fac08a2`.
It is not installed; the tested buffer-only 1.4.13 package remains on the hardware
Host. Manifests, statistics, timings and binary comparisons are retained in
`artifacts/qualification/host-build-iteration-1.4.14/`. A first cache-build attempt
`42452541232` was cancelled during dependency restore to correct the Rust smoke
command before application compilation; that diagnostic run produced no candidate.

## Native10 buffer reuse — merged; installed HEVC session accepted

The operator approved buffer reuse first and explicitly skipped unchanged-screen
filtering. GPU-resident capture remains a later investigation. Root/Host branch
`native10-buffer-reuse` starts at root `6e0c96de` / Host `8ca14f4e`; candidate
version is `1.4.13-native10-buffer-reuse`. Client and transport pins are unchanged.

Native10 lazily retains reusable SHM within a 256 MiB floor, preferring existing
CUDA registrations. The twelve-slot ceiling, CUDA pin cap, frame queues, actual
capture cadence, x264/NVENC conversion and synchronization remain unchanged.
Pool/registration timing now exposes costs previously excluded from capture
measurements. See [scope and qualification](docs/development/plans/native10-buffer-reuse.plan).

Normal and ASan/UBSan behavioral fixtures pass, including burst reuse, failed
allocation, owned-buffer safety, pageable overflow and display replacement.
131 CI policy tests pass. Standalone hardware probes from exact root `e54e5639`
/ Host `35a44af8` passed real SHM/CUDA comparisons: at 5120x2160, four real-time
idle/burst cycles used six initial allocations/no retirements, versus 21/15 with
the prior policy. Warm acquisition median was 0.002335 ms versus 10.146 ms. All
uploaded RGB10 bits matched and the pin budget returned to zero. This isolates
buffer work; it is not a frame-rate or whole-stream latency claim. The active
Host process remained unchanged, with no installation or session restart.

The first GitHub run `42448939300` restored all four existing dependency caches,
then stopped before application compilation because the newly enabled sanitizer
gate lacked GCC 14 sanitizer development libraries. CI now installs these test-only
prerequisites after dependency bootstrap; the product source is unchanged.
Replacement run `42449585395`, attempt 1, passed Native10/ASan/UBSan and compiled
probes, then hit the same pre-existing zero-before-FEC-loss loopback assertion as
mainline 1.4.12: exact video recovery followed by 174 missing source symbols.
One unchanged job retry (attempt 2) passed all Host/package/input/audio/transport
gates. No limits, tests or product code were changed for that retry.

The verified package is
`artifacts/packages/candidates/1.4.13-native10-buffer-reuse/linux/plank-host-1.4.13-0.native10_buffer_reuse.1.el9.x86_64.rpm`,
SHA256 `0d6ee311beb97bab58fd2c5ac7d9fddbf47ad3a2cb8849f8c5eb37c2455033a4`,
from root `b57e079663fad965d7b4ac6321dd85fff9e794fe` / Host `35a44af8`.
Original manifests/probe hashes are retained and download staging is removed.
The exact RPM is installed on the authorized test Host. All three private
binaries and the running supervisor match the package; administrator configuration
is unchanged. Flame stayed open. The completed Native10/HEVC NVENC 5120x2160
session captured 68,450 frames over approximately 19 minutes, averaging 16.6674 ms
between encoded packets (approximately 60 fps). It used two pool allocations,
with zero retirements, unavailable polls or allocation failures. Pool acquisition
p95 was 0.000741 ms; initial allocation accounts for the 9.44843 ms maximum.

Six-minute CPU/GPU/log observation found no extra allocations or capture
reinitializations, stable Host RSS and continuing transient compositor load.
After the requested reconnect, only the two current SHM segments remain. The
operator reported **playback normal**. This supports avoiding repeated buffer
allocation stalls; it does not establish a matched-workload FPS, CPU or total
latency improvement. XShm readback remains dominant. Installed x264 acceptance
was not repeated; its buffer/color fixtures pass. No Client update is required.

Remote observation and installation scratch were removed; a root-only config
rollback backup remains. Sanitized evidence is in
`artifacts/qualification/native10-buffer-reuse-1.4.13/`; operational records and
deployment details remain private. Do not resume damage filtering (#2); GPU-
resident capture (#3) remains separate future work.

## Mainline 1.4.12 — published

[PLANK 1.4.12](https://github.com/instinctual/plank/releases/tag/v1.4.12) is the
latest published release. Tag `v1.4.12` points to the exact package source below.
All six uploaded assets (four installers, checksums and manifest), their sizes
and GitHub SHA-256 digests match the verified local files. Release notes are in
[docs/releases/1.4.12.md](docs/releases/1.4.12.md). The published checksums and
manifest use flat download filenames; the local catalog keeps platform folders.

All four packages were rebuilt on GitHub from exact main source
`0cf0923b952685f918ceed53c8f39391de0e0651`. Client pin `d8cdba22` adds only the
1.4.12 changelog to tested production source `821e77da`; Linux Host remains
`8ca14f4e`, Kymux `9e1a7e30` and Client common-C `c7d1b831`.

| Product | Successful workflow | Package |
| --- | --- | --- |
| Linux Host | `42430611389`, attempt 2 | `linux/plank-host-1.4.12-1.el9.x86_64.rpm` |
| Ubuntu Client | `42430613670` | `linux/plank-client_1.4.12_amd64.deb` |
| macOS Host | `42430616032` | `macos/plank-host_1.4.12_arm64.pkg` |
| macOS Client | `42430618497` | `macos/plank-client_1.4.12_arm64.pkg` |

Catalog: `artifacts/packages/releases/1.4.12/`. All four original builder hashes,
source commits and gitlinks match; the combined `SHA256SUMS` check passes. Both
Mac PKGs are signed, notarized and stapled, with Gatekeeper verification passed.
Host minimum is 26.7; Client minimum is 15.0. Exact-input dependencies were reused
for all four products, including Host FFmpeg/Boost and Client FFmpeg/Qt.

The first Linux Host attempt failed the initial-lane loopback assertion expecting
zero missing source symbols before FEC: it observed 42 after the entire video
payload had already recovered byte-for-byte. The same test passed in the separate
transport run. One unchanged retry passed the full Host gate, including that
assertion and all three loss matrices. No source, test or threshold was changed.
This suggests transient loopback loss/timing; kernel loss was not measured in
that failing case. Retain the first-failure record rather than presenting it as
a first-attempt pass.

Transport workflow `42430620413` passed on Linux and macOS. Its exact Mac test
binary, SHA256 `999dd66f6d26a8aaf00019fa4c50aadf573472ec47f8fd4aaedc2bfafbb5942b`,
also passed three 900-frame, 150 Mbps matrices on the authorized development Mac:
zero unrecovered frames, maximum delivery 21.853 ms, worst p95 11.152 ms and
maximum receive gap 30.431 ms. Host/Terminal processes were preserved and scratch
was removed. Mac kernel drop counts remain unavailable.

Original manifests, recursive source pins, cache/signing checks, Qt/input test
reports and sanitized performance/failure records are retained in
`artifacts/qualification/mainline-1.4.12/`. Raw operational logs stay private.
Package gates and loopback qualification do not replace installed hardware
acceptance. Publication did not install or upgrade any endpoint. Existing branch
candidates retain their original provenance.

## Metrics / Telegraf — merged into main; Linux collection verified

Current branch: **`main`**. The operator authorized merging the completed metrics
and provisioning work. Parent merge `d2dd86af` matches the `metrics-telegraf` tree
at `702782fa` exactly. Client `main` is now `d8cdba22`, a changelog-only follow-up
to tested production source `821e77da`; Linux Host `main` is `8ca14f4e`.
Kymux and common-C pins are unchanged. The private provisioner's
completed branch is merged into its default branch as well. No product code was
changed while merging. Native Apple development and contributor Host test/signing
branches remain separate from this work.

The requested mainline 1.4.12 package rebuild and subsequent publication are
complete as recorded above. Further endpoint installation is separate work.

The initial 1.4.11 baseline uses product source `816b1e18`. The 1.4.12 follow-up
at `ffa0f92d` adds Ubuntu pen-activity metrics and is installed on both authorized
Ubuntu Clients. Real movement and tip-down records are verified on one endpoint;
the other has been reopened for its next connection. The input wire is unchanged.
The operator selected **InfluxDB 2**, existing **InfluxQL** Grafana queries,
and existing local Telegraf agents for Linux Hosts/Clients. Macs need a separate
agent installation. Deployment addresses, data-source identity and tokens remain
in private notes/provisioning. The operator authorized Linux-only installation;
no Mac package or agent was installed.

### Ubuntu pen activity — built and installed; activity data verified

The operator selected active PLANK sessions only and Ubuntu Clients first,
including sessions to either Host OS. Client pin `821e77da` observes the kernel's
decoded pen events from existing raw-HID evdev handles and the existing normalized
libinput path. Forwarded reports, pressure/clicks, grabbing policy and persistent
Host tablet identity are unchanged. Observation is bounded and optional; evdev
overflow/attachment rebases cannot synthesize activity. Disabled metrics do not
create an observer. No additional reader thread or per-motion disk logging.

The shared exporter accepts only movement/tip-down counts and observation status.
It adds aggregate fields to `plank_transport`, including last-activity age and
state 0/1/2 for unavailable/idle/recent activity. Recent means within one minute.
These are interaction observations, not productivity or attendance conclusions.
Coordinates, strokes, pressure values and tool identifiers are not exported.

Ten Rust metrics tests, actual Telegraf parsing of eight fixture datagrams,
131 CI policy checks, seven policy-upgrade tests and warnings-denied Clippy for
default/diagnostic features pass. Hosted run `42417299525` passes Ubuntu package,
Qt/input/launcher/compositor and normal/sanitized Wacom gates, including the real
adapter's USB/reconnect fixtures and new hover, tip, idle-report and observation
resynchronization checks. The first run exposed stale Qt link-time doubles;
updating those signatures did not change production behavior. Mac Client compile
checks also pass. Mac Host functional recheck `42417299697` passes at the same
Host source after an earlier C loopback timeout reported 91 lost QUIC packets.
No limits were relaxed. A broader local unit run had two `/proc/net/udp` lookup
failures in the test loss proxy; all five proxy tests pass in isolation/serial.
Do not report that broader local parallel run as a complete pass.

The operator removed the generic activity tiles and requested finer detail.
Grafana now has eleven panels and 25 visual queries: ten performance views plus
**Wacom Tablet Activity**, using movement/tip counts in one-second buckets with
no activity hold. Missing samples are separate from measured idle. The revised
query is accepted and returns genuine tablet records; no synthetic activity was
written to the live database. This checkpoint records the final dashboard and
documentation; the installed program does not need another rebuild for it.

Verified package:
`artifacts/packages/candidates/1.4.12-metrics-telegraf/linux/plank-client_1.4.12-metrics-telegraf_amd64.deb`
from root `ffa0f92d44d439bdd0dcc8e5b23b09182d214156`, Client
`821e77da8589a6f8d594b9d7a8b372791407f23f`.
Package SHA256 `81b7d615ced79b7eb9f6b6c052a4afc28be970c1175bfc8009caa30ded359d3a`;
installed/running Client SHA256 `5094ed287608b7f74bbcd6849f213b26261ec5476181cc082e59ae679acac9dc`.
Original hosted manifest and normal/sanitizer/component reports are retained in
`artifacts/qualification/pen-metrics-1.4.12/`. Both installed/running binaries
match and saved settings are preserved. The second activation needed a later
observation to see the process; no reinstall or duplicate launch was needed.
Physical pen movement and tip contacts reach InfluxDB from the first Client.
This verifies activity collection, not a new complete color/audio/input/pressure
acceptance sweep. Endpoint inventory, root-only backups and credentials are private.

Candidate **1.4.11** adds one shared, optional IPv4-loopback UDP exporter in the
transport crate; policy wiring on both operating systems; actual Client decoder
statistics windows; the standard Telegraf socket-listener input; and an InfluxQL
dashboard. Metrics default off. Client upgrades preserve existing policy values.
There is no new product dependency, transport lane, database credential or remote
metrics listener in PLANK. New C APIs are additive; existing ABI layouts and the
wire protocol are unchanged. See [configuration/schema](docs/user/metrics.md)
and [the plan](docs/development/plans/metrics-telegraf.plan).

Installed 1.4.11 pins: Client `8afbbcec` (including discovered-Host identity handling), Linux Host
`8ca14f4e`. Kymux `9e1a7e30` and Client common-C `c7d1b831` remain unchanged.
All four original installers, manifests and hashes are verified in
`artifacts/packages/candidates/1.4.11-metrics-telegraf/`:

| Product | Source root | Successful GitHub run |
| --- | --- | --- |
| Linux Host | `47cd9501` | `42402245179` |
| Ubuntu Client | `816b1e18` | `42403727172` |
| macOS Host, signed/stapled | `47cd9501` | `42402260256` |
| macOS Client, signed/stapled | `816b1e18` | `42403746821` |

Host code is identical at both roots; the later root updates only the Client
pin and notes. Do not relabel or overwrite the collected installers. The earlier
Mac Host failure was a strict-POSIX test-fixture loopback constant; portable
`inet_pton` corrected it. No build gate was bypassed. The final Client follow-up
uses the server UUID for discovered entries and the separately authenticated
server UUID for manual bookmarks. Both Client builds pass at that final pin.

Validation:

- 131 CI policy tests and seven portable policy-upgrade tests pass. Rust's 75
  default-feature unit tests and warnings-denied Clippy pass; macOS shipping
  features and hosted platform/component/package checks also pass.
- Eight metrics tests cover escaping, bounds, reset-safe rates, timing jitter,
  accumulated windows, lock contention and absent/non-reading collectors.
  Actual Telegraf 1.40.3 parses all eight generated fixture datagrams. No database
  writes are involved in that test. C media/teardown fixtures pass with metrics
  disabled and with a non-reading collector; retained media handles safely reject
  observations after endpoint teardown. Mac configuration and Client policy
  fixtures pass in their hosted builds, not inferred from Linux-only skips.
- Hosted transport run `42402057626` passes parser/cancellation/reliable-data
  checks, delayed-ACK/receiver-pause tests and three 900-frame loss matrices at
  150 Mbps, with zero unrecovered frames.
- Its exact Mac shipping-feature test executable passes the same three matrices
  on the authorized development Mac: zero unrecovered frames, maximum delivery
  15.603 ms, p95 maximum 10.879 ms and maximum receive gap 25.347 ms. Binary SHA256
  `0c8111ed818a2548acb22f59e7ee04f8ba77dc5e0d2d1b3a14026d3c258be43c`.
  Terminal and Host processes were preserved; remote scratch is removed. Kernel
  drop counts are unavailable there. This is isolated transport qualification,
  not acceptance of installed collection or an interactive A/V session.

The dedicated PLANK Grafana data source is healthy. The baseline performance view
is applied live and saved in the repository: ten performance panels,
24 direction-specific visual InfluxQL queries, `fill(none)`, Table legends with
Last non-null values, and separate Hosts/Clients menus populated with machine
names. Role, workstation UUID and bookmark selectors/grouping are removed.
Video/audio graphs show Host send and Client receive. Host Encoder Target is
a separate Host-only panel next to the video section. Observation, event, statistics-age and both application-queue panels
are removed from the main view; telemetry remains available for diagnosis.
All final query models executed successfully and the saved dashboard was read
back. Before the requested fill/grouping changes, all 31 visual conversions
matched their raw-query results across 2,928 returned rows. This is dashboard
configuration only; installed application bytes and exporter schema are unchanged.
This checkpoint includes the final dashboard and source documentation.
The dashboard remains in the existing metrics folder. The temporary setup account was returned to
Editor, with Admin capabilities absent and dashboard access still working.
The operator then requested a dedicated PLANK bucket and unified private
appliance provisioning. The new bucket retains the previous three-day retention
policy and has its own InfluxQL mapping. Telegraf uses a bucket-scoped write
token; Grafana uses a separate read-only token. Deployment credentials stay out
of this public repository; the private provisioner policy is described below.
All 24 visual queries pass against that
new data source and return current Host and Client observations. Historical
buckets and data sources remain intact. The operator retained full-resolution
samples for three days; no downsampling was added. The supplied replacement
write token is installed on both Linux collectors, with fresh writes verified.
PLANK sessions were not restarted for that credential change.
The verified Linux Host RPM and
Ubuntu Client DEB are installed on the authorized test endpoints; package and
running-executable hashes match the originals. Both localhost Telegraf inputs
are listening, and PLANK metrics are enabled. Client bookmarks/settings compare
unchanged and the Client was reopened successfully. The existing Host session
reconnected and its desktop application remained running.

Real Host RTT, video cadence, encoder target, capture/profile and resolution
records now reach the dashboard. Existing test-endpoint system outputs retain
their original buckets; application metrics use separate filtered outputs.
The Host originally needed a separate, measurement-filtered output:
its system metrics use another bucket, and the initially supplied overlay URL
was unreachable there. The new output now uses its existing LAN route to the
same InfluxDB instance, verified against Grafana's configured data source.
Both existing system outputs exclude only the three PLANK measurement names.
Real Client media metrics are now verified through Grafana as well, including
network/decode/render rates, decode timing and the hardware-decoder flag.
Client system-metric delivery is also healthy. This verifies metric collection
and queries, not a new interactive audio/video/input acceptance claim.

Evidence is in `artifacts/qualification/metrics-telegraf-1.4.11/`. The branch's
signing permission is `65875659`; remove it when retiring this branch.
Root-only rollback backups are retained on both endpoints; transferred package
and credential-bearing staging files are removed. Access details, raw live
metrics and configuration backups are private, outside Git. The optional public
Telegraf input now accepts only the three PLANK measurements; its real-parser
fixture passes. This deployment configuration update does not change the
already verified installers.
The private appliance repository's `plank-unified` branch removes obsolete
product selection, duplicate branding/output profiles and retired launcher
aliases. It retains Production/Beta channels, the effective network and tuning,
and optional vendor helpers. Fresh Client/Relay provisioning uses the PLANK
bucket for system and application metrics. At the operator's explicit request,
the permanently private appliance repository now holds one ordinary shared
Telegraf output file containing its bucket-scoped write-only token. Installation
copies that file as `root:telegraf`, mode `0640`. The Python generator, separate
token store, token prompts and token CLI options are removed. Administrator and
Grafana read tokens remain outside Git; no credential enters this public repo.
`--channel production|beta` and `--help` remain. There is no upgrade-only option;
normal installation still performs full appliance provisioning.

The operator's latest private-repository commits were pulled before this change;
their updated ping targets/process inputs and removed ZeroTier overrides are
preserved. Five isolated installer CLI tests, shell syntax and real Telegraf
parsing of both Client/Relay profiles pass without database writes. No full
provisioner was executed, no fleet migration was performed, and package pins
remain at their existing available versions. Application metrics require 1.4.11
or newer; Wacom observations require Client 1.4.12 or newer. This provisioning
simplification needs no Host/Client rebuild or runtime change.

Global `nodetype` now identifies the Linux test endpoints as `plank-host` and
`plank-client`; fresh Client/Relay provisioning uses `plank-client` and
`plank-relay`. The application `role` still drives the Host/Client session
menus. Existing system-dashboard filters use the new labels only, following
the operator's instruction to update endpoints without old-label alternatives.
Fresh application and system samples with both new labels are verified.
Only Telegraf was restarted; PLANK processes were preserved.

Remaining provisioning acceptance is a fresh-appliance installation using an
available metrics-capable package. Mac installation remains out of scope.
The source merge does not replace those remaining checks. Existing candidates
retain their original versions/provenance. Mainline packages are now built,
verified and published. Further installations and hardware acceptance remain
separate work.

## Code review hardening — accepted and merged into main

On November 7, 2026, the operator reported successful candidate testing and
authorized commit, push and merge. **`code-review-hardening`** is merged into
main at `2b4b935f23dd07bad7d63b2ee8f2d89eaa3891eb`. The merge tree exactly matches the
accepted branch; no production code or dependency pin changed during merging.
Version remains **1.4.10**. Client, Linux Host and Kymux are on their pushed
`main` branches; common-C is on its maintained `plank/client` branch. The
accepted baseline remains on `main`; the current work is described above. No release publication was requested.
See [the implementation checklist](docs/development/plans/code-review-hardening.md).

Accepted hardening baseline pins:

- Client `669b792e70150b8f679a90a273059e2190ded7dc`.
- Client common-C `c7d1b83143be1511735526ae8ce75a6d5c25f63c`.
- Linux Host `539f58b057da36124800837d49896b940de218bb`.
- Kymux `9e1a7e304abe4ad6b42a7a10ef41eae2b16fb31f`.

Implemented:

- Bound Linux HTTPS buffering/admission before dispatch; correct the fallback 404.
- Bound KyProto control records and propagate fatal control/router failures.
  Datagram backpressure is isolated per endpoint; retired endpoints are safe.
- Replace detached common-C failure callbacks with synchronous once-only
  notification on the producing thread. Qt queues teardown/recovery and joins
  producers before retiring the session. Native Apple uses its direct bridge.
- Release all held mouse buttons and mapped keys; clear transient Alt/modifier,
  repeat and scroll state while preserving persistent tablet identity.
- Use bounded, cancellable caller-owned PulseAudio capture/control on Linux.
- Remove Sunshine directory migration, unsupported AV1 and unused utilities;
  retire unused Client toolbar/pointer/focus/color helpers, artwork/game metadata,
  polling and audio statistics that always returned zero.
- Remove the unused alternate setup lifecycle. Local C ABI is 14; the shipping
  wire format is unchanged. HTTPS handles authentication/topology, QUIC handles
  launch and active traffic. Rebuild static consumers against matching headers.
- Assemble video metadata/payload once and reuse that owned allocation in FEC.
  Source-first submission, repair policy and packet bytes are unchanged.
- Cache Native X11 geometry behind checked root/overlay structure subscriptions.
  Every capture still validates depth/SHM size and rejects racing display changes.
- Select affected CI products and fingerprint dependencies independently. Schema 3
  required one new cache population; verified dependencies now reuse those keys.

GitHub package builds and original installers:

| Product | Source root | Build | State |
| --- | --- | --- | --- |
| Ubuntu Client | `1576ed26` | `42318113500` | Passed, downloaded and verified |
| Mac Client | `3b0550bf` | `42318465953` | Signed/stapled, downloaded and verified |
| Mac Host | `49897540` | `42317158306` | Signed/stapled, downloaded and verified |
| Linux Host | `91fd5954` | `42321629509` | Passed, downloaded and verified |

Catalog: `artifacts/packages/candidates/1.4.10-code-review-hardening/`.
Original builder manifests, logs and reports are in
`artifacts/qualification/code-review-hardening-1.4.10/`. Client production code
is identical at `c3e2b670` and `669b792e`; the latter only synchronizes a UI test
with Qt layout. Later root differences are test fixtures/documentation or other
products, not unrecorded modifications to already collected packages. Preserve
each original manifest and hash; never relabel a package.

Verification passed:

- 131 CI policy tests, eight portable root packaging/privacy tests, common-C
  component suites and 941 lifecycle assertions pass. Common-C and Native10
  AddressSanitizer/UndefinedBehaviorSanitizer checks pass. Local ThreadSanitizer
  could not link because its runtime is absent; do not claim a TSan pass.
- Linux HTTPS/PAM bounds and lifecycle tests pass. Input/crypto fixtures pass
  25 shuffled repetitions. The actual PulseAudio backend captures a synthetic
  tone, cancels within 500 ms while the daemon is stopped, cleans up within 1s,
  and captures again after it resumes. This isolated fixture passed in 4.082s.
- Default and diagnostic-feature Rust Clippy pass with warnings denied.
  Actual KyProto parser/state tests and native encrypted media/data/cancellation
  fixtures pass. Exact integration filters now reject a zero-test result.
- Linux hosted transport run `42316773288` passed three 900-frame, 150 Mbps loss
  matrices through 5%, with zero unrecovered frames and zero unintended kernel
  drops; all four ACK-hold/receiver-pause cases passed and recovered in place.
- The exact Mac test executable from that run, with shipping `sender-timing`
  features and target 26.7, passed three matrices on the authorized development
  Mac: 2,700 frames, 150 Mbps throughout, zero unrecovered frames, worst delivery
  16.796 ms, p95 maximum 11.827 ms and receive-gap maximum 23.610 ms. Its SHA256 is
  `1ca3222cb35cad8b84c16829064df143ba3a10905984634198d9eab5787fa1e8`.
  Mac kernel-drop counters are unavailable. Terminal and Host were preserved;
  all temporary remote files are removed. This is isolated transport qualification.
- Read-only Native10 capture at 5120×2160 / depth 30 passed geometry and SHM checks.
  Median 6.07 ms batched versus 5.99 ms cached does not establish a material FPS gain.
  Two geometry queries per steady frame are removed. No saved screen pixels,
  service restart, display/input change or installed session test occurred.
- Ubuntu passed Qt input/rendering, ASan/UBSan, compositor/launcher, real PipeWire
  playback and package gates. Both Mac products passed their component and
  signing/notarization/package gates; these do not establish installed acceptance.

Superseded failures were corrected rather than waived: stale setup packet/test
expectations; leftover Client declaration/include dependencies after artwork
removal; a UI assertion sampling delegates before layout; and an isolated
PulseAudio fixture inheriting an unsuitable CI home directory. The latest Host fixture gives its daemon private runtime/state/cookie paths
without changing HOME, uses a synthetic tone and allows bounded source startup
separately from unchanged cancellation/teardown deadlines. A standalone daemon
check measured first PCM at about 2.1s; an immediate one-second expectation was
incorrect. Component tests now run before the full media/RPM build. The preceding Host run passed compilation, HTTPS, input/crypto, transport
and RPM checks but failed daemon startup before exercising audio recovery.
The corrected fixture and all final gates passed in run 42321629509. No test
was disabled and no cancellation, loss or latency threshold was relaxed.

All four original manifests and package hashes match the local catalog. Both
Mac PKGs are signed, notarized and stapled. Downloads are cleaned up; logs,
original manifests and qualification evidence remain. Operator testing is now
accepted and the code is merged. These installers retain their candidate names
and original hashes. A mainline rebuild must create new artifacts; do not
relabel the accepted candidates. This instruction did not request publication.

## Previous mainline packages — 1.4.09, publication held

The preceding main baseline was `b8a0f1a8`. All four 1.4.09 packages are built from exact source
`6c9bf535338c72d40b5193b8c112282b2ffa591b` and retained in
`artifacts/packages/releases/1.4.09/`; no release/tag or installation was made.
The catalog's `releases` name denotes mainline provenance, not publication.

Pins: Client `1c54da5d0cfae834c9484c67c3519bad8024d263`, Linux Host
`2281c3ed6dbf5779ec75dba15a8a4f165efba1fa`, Kymux
`079e56477a0577c74fb643400668ac983662d3e4`.
Successful runs: Linux Host 42309328630, Ubuntu 42309335146, signed Mac Host
42309339041, signed Mac Client 42309343325. Transport 42309346962 passed;
its exact Mac test binary matched the qualified candidate. Original manifests,
checksums and reports remain in `artifacts/qualification/mainline-1.4.09/`.

Main includes shared source-first FEC and the 4 MiB outgoing datagram queue,
2 MiB minimum in-flight window and 1 Gbps controller budget. There is no application
pacer or unbounded queue. Reliable-data pressure pauses and resumes reads instead
of ending a session; explicit takeover/security failures remain terminal.
Earlier installed 1.3.16 testing recovered through 8% induced loss and recovered
after an 8.5% FEC exhaustion event without reconnecting; a later 7% one-minute test
also remained normal. Those historical results do not accept new candidates.

Dependencies remain FFmpeg 9.0.2, Qt 6.10.2, Boost 1.92, JSON 3.12, Vulkan 1.4.367,
Kymux/Kyproto 0.29, Quinn 0.11.12 / proto 0.11.19 / udp 0.5.16, Rustls 0.23.46,
RaptorQ 2.0.1 and Rust 1.99.1. NVIDIA 595.104.02 / CUDA 13.2 Update 2 / NVENC SDK 13.0.19
and the full CUDA architecture list remain. Transport ALPN is `plank-native/2`.
Older package provenance is preserved in the catalog, plans and Git history;
see the [cleanup inventory](docs/development/reviews/desktop-cleanup-inventory.md)
and [simplification plan](docs/development/plans/code-simplification.plan).

## Separate work and remaining acceptance

Native Apple/AVP work is on `avp-dual-display` in both parent and Client, at
`f96a1b81` and `7580c06f`. Its worktree directory is still named
`build/worktrees/native-builds`. Earlier `apple-native-integration` and
`native-builds` checkpoints are fully contained in that branch. Vision TestFlight
0.1.0 (13.1) was delivered; actual headset acceptance remains pending. Consult
that branch's HANDOFF before resuming and retain its own protocol pin. When
rebasing to C ABI 14, remove the native bridge's obsolete `config.session_mode`
assignment and `SETUP_READY` allowance. Do not merge or delete this work as part
of desktop cleanup.

The operator explicitly confirmed retaining both contributor Host test branches:

| Branch | Retained purpose |
| --- | --- |
| `codex/macos26-host-test` | Chris's macOS 26.7 qualification baseline; still permitted in `macos-signing`. |
| `macos-host-test` | Reviewed Host candidate used by the `/build-macos-host` approval workflow; still permitted in `macos-signing`. |

Their source changes are already represented in main, but that does not retire
their testing role. The live signing allowlist and approval registry were checked
on November 7. Neither branch, its worktree nor its signing permission was
removed. Keep them during branch cleanup; future candidate revisions still need
the exact-SHA review/registry checks in the [build runbook](docs/development/build/github-builds.md).
Main protection was discussed, not enabled.
The hardening branch's signing permission is 65803900; retain it until retirement.

The authorized development Mac is identified in private notes. Preserve Terminal
and active sessions. Reference Macs are read-only unless reassigned. No active
remote collector, loss injection or temporary probe remains from this pass.
No package installation, reboot or service restart was performed by the agent.
The operator accepted the candidate testing without enumerating hardware or OS
combinations. Retain the following platform-specific qualification matrix; the
acceptance does not expand supported platforms or replace Chris's 26.7 checks:

- Capture/encode and exact-format hardware decode/presentation, 10-bit color,
  4K/5K, fullscreen/window scaling, Retina/notch and multiple displays.
- Wacom pressure/clicks/Tablet Margins, mixed local/remote models, USB reconnect
  and network recovery; preserve the persistent-tablet contract.
- Real A/V listening/synchronization soak, audio-device changes, microphone,
  camera, clipboard, disconnect/reconnect and desktop transitions.
- Mac setup/permissions/uninstall and login/locked takeover; the identical Host
  package on 26.7 and 27, and Client on 15 and 27. Chris owns 26.7 session validation.

Intel NUC Gen11 is unqualified; no runtime blacklist was added. Its repeated
video-engine hangs remain unexplained despite passing isolated controls. Do not
resume that investigation without operator direction. See
`docs/hardware/intel-nuc-client-qualification.md`. A separate earlier surface-timeout
investigation is paused; packet-loss snapshots do not establish its cause.
Wallpaper/Screen Saver pointer lag, Linux physical-display provenance,
application hotkeys and immediate-paste stress remain separate deferred work.
