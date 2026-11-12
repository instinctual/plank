# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. This is the current
checkpoint; private deployment data stays outside Git. Earlier detailed results
are preserved in [the preceding checkpoint](https://github.com/instinctual/plank/blob/af3b5e2d/HANDOFF.md),
the focused plans and the artifact catalog.

## Current state

**PLANK 1.4.18 is published** at
[GitHub Releases](https://github.com/instinctual/plank/releases/tag/v1.4.18).
The operator authorized commit, push and release. `macos-display-sleep` is merged
into main; root, Linux Host, Client and Kymux canonical checkouts are on main.
All four packages were freshly built from main and published. The Client update
is bundled release notes only; Linux Host and transport runtime sources are
unchanged. No additional deployment is queued.

The annotated release tag points to package source
`cd8b6936f9215b69e18918a3161ba4300c0284ff`.
Tag object: `7829ba31cc7019b4136f5202e41db661eaa2edf0`.
Later commits update documentation; never move the tag or relabel installers.
Release ID: `442328108`.

| Source | Release revision |
| --- | --- |
| Linux Host | `c71333d72cf43843a79a77df82f521547682d6c5` |
| Client | `121ed3eb6daffb116f33194074109e2bdad9a38c` |
| Kymux | `9e1a7e304abe4ad6b42a7a10ef41eae2b16fb31f` |
| Client common-C | `c7d1b83143be1511735526ae8ce75a6d5c25f63c` |

The Client changes after accepted runtime `821e77da` are release notes only.
Native Apple/AVP remains separate; retain its branches as described below.

## Display wake correction and installed candidate

Authenticated preparation now wakes the console before creating or changing
displays, waits for active/non-sleeping output, and bounds retries of the same
virtual-display identity. A failed first setup can still wake the desktop and
allow topology/preparation to retry. Preparation and active streams hold scoped
idle-display-sleep protection, released on all exit paths before capture drain.
Power preferences, screen-lock security, identity and protocol are unchanged.
See [the focused plan](docs/development/plans/macos-display-sleep.md).

The exact **1.4.18-macos-display-sleep** candidate remains installed on the
authorized affected Mac; publication did not replace it with the mainline PKG.
Candidate source: `fb5cff4b63004c387313dbbf68cbaf3420737d64`.
Package:
`artifacts/packages/candidates/1.4.18-macos-display-sleep/macos/plank-host_1.4.18-macos-display-sleep_arm64.pkg`.
Package SHA256:
`ae8912f49f009bae948d7b6eb7c4aed96b6da62bf0f9fe5bd9efc9bbec3eca4a`.
Installed executable SHA256:
`1fc88609f2b3ce5cad69670bde0584fba74801e27bb0731c411bab59166ac02e`.

The operator authorized installation and PLANK restart. Both services restarted,
HTTPS serverinfo returned 200, and logs showed successful resolution preparation.
Configuration and machine-key hashes, console user, WindowServer and boot time
were preserved. No logout, reboot or global power setting change occurred.
A later read-only observation found the 5120×2160 session still running with the
PLANK idle-display assertion held for 10m58s and no logged display failure or
stream stop. This does not prove a deliberately idle or asleep-reconnect test.

Interactive sleep/reconnect/idle-timer acceptance and assertion release after
an installed disconnect remain unrecorded. Do not induce logout/reboot or explicit
sleep without authorization. A pre-fix five-second OS wake cleared the stale
registration without restarting the old worker. Raw evidence and access are
private; use the private notes README. Remote install staging is removed.

## Published packages and validation

All four installers are in `artifacts/packages/releases/1.4.18/` and attached
to the release with the source manifest and checksums. All six asset sizes and
SHA-256 digests were verified before and after publication. Public checksums and
manifest use basenames; the local catalog retains platform-relative paths.
Both Mac packages are signed, notarized, stapled and Gatekeeper-accepted.

| Product | Successful workflow | Artifact attempt |
| --- | --- | --- |
| Linux Host | `43121785326` | `linux-host-43121785326-2` |
| Ubuntu Client | `43121785326` | `linux-client-43121785326-1` |
| macOS Host | `43121831964` | `signed-macos-host-43121831964-2` |
| macOS Client | `43121836018` | `signed-macos-client-43121836018-1` |

Host targets remain Rocky 9.7/macOS 26.7+; Clients remain Ubuntu 26.04/macOS 15+.
Apple packages are Apple Silicon. SDK 27 gates remain; Chris owns macOS 26.7
installed validation. New 26.7 acceptance was not recorded for this correction.

Native Mac tests passed 37 display recovery scenarios, nine readiness cases
(378 checks) and 26 real-QUIC/synthetic capture session scenarios (941 checks).
The 138-test CI source policy, privacy, clipboard, package and Client
compositor/input/launcher gates passed. Linux transport passed three 900-frame
150 Mbps loss matrices with zero unrecovered frames and zero proxy kernel drops.

Initial Linux Host and signed Mac Host jobs failed the unchanged native round-trip
test at `native.rs:583`: payload recovery was exact, but a zero-missing-source-symbol
assertion observed 45 and seven symbols before FEC. One targeted retry per failed
job passed with identical source, assertions and limits; successful sibling jobs
were retained. The independent unsigned Mac Host also passed. The cause remains
unestablished. No test was weakened or automatic retry loop added. Preserve this
as an unresolved test-reliability observation, not a proven runner defect.

Transport sources are unchanged from 1.4.12, whose retained development Mac
qualification passed three identical-load matrices with no unrecovered frames.
Its exact executable SHA256 is
`999dd66f6d26a8aaf00019fa4c50aadf573472ec47f8fd4aaedc2bfafbb5942b`.
No new Mac transport performance soak or mainline package installation occurred.
Evidence is in `artifacts/qualification/mainline-1.4.18/` and the candidate's
qualification directory; raw CI/deployment logs remain private. Download staging
is removed. [Release notes](docs/releases/1.4.18.md) record the fix and limits.

## Earlier startup fixes and deployment boundaries

The shared Application Support permission correction and optional-metrics startup
correction remain in main; see releases [1.4.16](docs/releases/1.4.16.md) and
[1.4.15](docs/releases/1.4.15.md). They retain protected PLANK paths and default-off
Mac metrics. Do not deploy Mac Host 1.4.11–1.4.14, whose fixed-count configuration
startup regression is superseded. Deployment details and earlier candidate
hashes are preserved in private inventory and the preceding checkpoint.

The authorized development Mac's last observed installation remains the earlier
1.4.15 startup candidate; this release did not access or upgrade it. Metrics use
UDP export to Telegraf; a closed TCP port does not diagnose the UDP collector.
The merged `macos-display-sleep`, `macos-shared-directory` and
`macos-startup-config` branches and their exact signing permissions remain.
Check live approvals and testing roles before any later retirement.

## Build workflow to preserve

Use the [release runbook](docs/development/build/release-build-runbook.md) and
[hosted-build guide](docs/development/build/github-builds.md).
All four products reuse verified dependency caches. Linux Host and Ubuntu Client
also reuse validated compiler outputs; Mac application/transport objects compile
fresh. Clean source/build directories, fresh linking, tests, package verification,
signing and full CUDA architecture coverage remain mandatory.

For 1.4.18, compiler hits were Host **337 C/C++, 151 Rust, six CUDA** and
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

Publication is complete. Wait for the operator's next task; no rebuild, remote
probe or additional deployment is queued. The remaining check for the display-wake fix is a deliberate sleep/reconnect
and idle-timer session test when the operator chooses to run it. Preserve Terminal and active sessions on the
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
