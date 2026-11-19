# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. This is the current
checkpoint; private deployment data stays outside Git. Earlier detailed results
are preserved in [the preceding checkpoint](https://github.com/instinctual/plank/blob/af3b5e2d/HANDOFF.md),
the focused plans and the artifact catalog.

## Current state

Active development is on **`tangent-panel-forwarding`**, based on main
`4a1c1046`. **1.4.20-tangent-panel-forwarding** contains Tangent panel forwarding
and the operator-approved shared 4 MiB QUIC receive-buffer request. Both products
log the requested and OS-reported sizes. Linux packages include a commented,
administrator-editable receive-ceiling policy; application buffer defaults,
send budgets, FEC, wire negotiation and test thresholds are unchanged.
Both Linux candidates are installed on the authorized test pair. The operator
will test the live panel connection later. No merge/release is authorized.

| Candidate source | Revision |
| --- | --- |
| Root runtime/build source | `2687e09ad234481e4ed5707f3c8ccf364e4e288c` |
| Linux Host | `883b96aed5f9f824d49ef1b9a84b7335537cc14a` |
| Client | `633ba511e36fb23c2d8e7e42bbc44b2d797909be` |
| Kymux | `4ee4654d6f15ae30e39056f97b51761fe15322fe` |
| Client common-C | `c7d1b83143be1511735526ae8ce75a6d5c25f63c` |

Hosted run `44486242662` passed policy, both Linux packages and both unsigned
Mac regression builds. The exact Linux installers are downloaded and verified;
no further build is queued. Supplemental transport run
`44487124852` passed Linux and Mac functional qualification. The Host job and
supplemental Linux job each passed three 900-frame, 150 Mbps loss matrices with
zero unrecovered frames and zero proxy kernel drops. Both requested 4194304 bytes
but Linux reported only 2097152 under the runner's ceiling; Linux's reported
value includes doubled kernel accounting. These passes do not prove the full
4 MiB request was granted or the packaged policy has been installed.

The exact GitHub-built Mac transport executable was also qualified on the
authorized development Mac with the shipping `sender-timing` feature. Its SHA256
is `70b0ecadc4f39e1f42daa75458fbfd4d51a7e4841977b65099aff2462e38d2b9`.
All three matrices recovered all 2700 frames with the full 4 MiB grant. Worst
phase p95 delivery was 11.564 ms, maximum delivery 20.013 ms and maximum receive
gap 28.003 ms, within unchanged limits. Observed boot time, global socket defaults
and Terminal processes were preserved; temporary staging was removed. The Mac
does not expose the proxy's kernel-drop counter. This is transport qualification,
not an installed GUI, audio-listening or panel acceptance test.

Both verified candidates are under
`artifacts/packages/candidates/1.4.20-tangent-panel-forwarding/linux/`:

| Installer | SHA256 |
| --- | --- |
| `plank-host-1.4.20-0.tangent_panel_forwarding.1.el9.x86_64.rpm` | `cf2f39ab63ce4368ba38cdc68bb85a26fadf41fff26ee050d9681b9faab96a89` |
| `plank-client_1.4.20-tangent-panel-forwarding_amd64.deb` | `d5a8e2477d693af932692b08e374517eec6049bc1ead47fcb4bce2a591b77c10` |

The Host's exact signed VHCI module, corresponding source, receive-ceiling
policy and absence of an external driver-package dependency were checked
independently. Client checks verified the exact udev rule and maintainer hooks,
libusb runtime dependency, both conffiles and absence of autostart entries.
All 17 isolated Debian packaging tests passed on hosted Ubuntu, including
administrator configuration preservation. The operator explicitly authorized
the Client installation/restart, in addition to the already-authorized Host
upgrade. Both installed executable hashes match their verified package payloads;
the Client GUI is open. Bookmarks, administrator configuration, Host identity
and TLS material are unchanged. No reboot, kernel or NVIDIA update occurred.
The older 1.4.19 Client and initial Host artifact are superseded.

Both installed Linux systems now allow the full 4 MiB request: unprivileged,
unbound OS socket checks report 8388608 bytes, including Linux's doubled
accounting. Application default buffers remain unchanged. The Host reports
`PlankTangentVersion=1`; the active Client desktop user can open the qualified
USB node read/write without root. These are installation checks, not a connected
PLANK session's receive-grant or Tangent control acceptance. Temporary installer
copies were removed; no loss injection or forwarding probe is running.

Local validation passed 103 Client-feature Rust tests, 146 CI/policy tests,
Clippy, the real socket-grant test and both C ABI certificate-trust modes.
The sustained local loss matrix still failed with the OS capping sockets at
425984 reported bytes and 586 extra proxy drops. Do not call that a performance
pass, request builder repairs or weaken gates. The hosted Ubuntu package fixtures
provide the Debian validation unavailable on the local Rocky builder.
Evidence is under `artifacts/qualification/tangent-panel-forwarding/receive-buffer-1.4.20/`;
raw logs and deployment/access details remain private.

## Tangent implementation and remaining hardware gate

The operator accepted KnobX1 jog, Play/Stop and all four modes in Flare through
the initial bounded SSH/USB-IP proof. All probes are stopped. Original Client
USB ownership, an empty export match table and unused Host virtual ports were
verified, and the temporary Client kernel exporter was unloaded. The subsequent
candidate installation removed the exact temporary ELRepo driver package and
its weak-module links without rebuilding initramfs, then loaded the RPM-bundled
signed VHCI module. Its resolved path, original decompressed hash and corresponding
source hash were verified independently. Desktop and TangentHub processes were
preserved. Flare is open, but its process ID changed during the installation
window; no Flare restart command was issued and the cause is unestablished.
Do not describe that as uninterrupted Flare acceptance. Firmware, kernel and
NVIDIA versions are unchanged.

The production candidate uses a separately bounded, authenticated reliable QUIC
endpoint, unprivileged Client libusb and the Host's narrowed VHCI attach path.
Ownership belongs to the logical session until disconnect, including transport
recovery. Actual driver/source/license bytes are bundled in the normal Host RPM;
there is no external driver download during installation. Client permissions
cover the qualified Mf ID and active seat only. Mac devices and Wacom remain
outside this feature's scope. See the [plan](docs/development/plans/tangent-panel-forwarding.plan)
and [protocol contract](protocol/tangent-panels.md).

Encrypted failure tests prove that a panel-backend failure retires the peer's
panel channel while ordinary data remains available. The systemd attach exception,
TangentHub enumeration sequence, logical-session ownership and malformed-message
limits are checked. These do not qualify installed libusb/QUIC forwarding or real
Tk/Kb/Bt panels. Unplug, multiple panels, takeover and loss acceptance remain
outstanding. Terminal panel-channel failure currently requires reconnecting.

## Receive-buffer investigation context

The preceding 1.4.19 candidate (`59e0d3d1`) passed Ubuntu packaging and both
unsigned Mac builds, but two Host runs failed a strict loss matrix in the zero-loss
phase, with one missing frame and zero proxy kernel drops. Its native video/FEC
path was unchanged from main and the test did not activate Tangent forwarding.
One targeted retry instead reported missing source symbols before FEC despite
exact reconstructed video. Similar assertions had failed during the earlier
1.4.18 builds, as recorded below; this was not a wholly new observation.

A read-only local observer reproduced receive-socket overflow on both that
candidate and a clean main checkout. The main socket first dropped packets
75 ms into its test. Hosted main comparison `44478883295` passed all matrices.
Socket defaults/grants differed across hosted runs, so successful previous builds
do not establish identical receiving capacity. The local evidence supports explicit
receive headroom, but does not establish the exact cause of every hosted failure.
The operator authorized the bounded correction; no threshold was relaxed or
automatic retry loop introduced. Earlier failed runs and detailed evidence remain
in the preceding checkpoint and private audit, rather than being erased by passes.

## Published baseline

**PLANK 1.4.18 is published** at
[GitHub Releases](https://github.com/instinctual/plank/releases/tag/v1.4.18).
The operator authorized commit, push and release. `macos-display-sleep` is merged
into main; it is the baseline for the active Tangent development branches.
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
main. Their signing/approval policies were rechecked on November 14. Main
protection was discussed, not enabled.

The operator authorized retiring **21 merged branches and three PLANK2 branches**
on November 14. Cleanup removed 23 remote and 17 local branch refs across the
parent, Kymux, common-C, build-deps and libvirtualhid repositories; one Kymux
branch existed only locally. PLANK2 is retired; its separate repository was not
modified. Native Apple/AVP, contributor-test, production/default and open
dependency-PR branches were preserved. Retained Native Apple dependency pins
remain reachable through production branches. Working trees, production gitlinks
and the release tag were unchanged.

Eight obsolete `macos-signing` deployment-branch permissions were removed.
Only `main`, `codex/macos26-host-test` and `macos-host-test` remain allowed;
the contributor approval registry is unchanged. Exact deleted refs and policy
IDs are recorded in the private audit directory. This was branch/policy and
documentation housekeeping; no package rebuild or deployment was needed.

## Next work and qualification limits

The operator chose to test later. When the installed 1.4.20 Client connects to
the authorized Host, inspect the live receive-grant logs, libusb/QUIC attachment
and TangentHub ownership, then observe jog, play/stop and mode controls. Installed
OS socket capacity and bundled-driver checks are complete; the initial
kernel-export proof is still not acceptance of the libusb Client backend. Keep
other panel models unqualified until tested. No new build or deployment is queued.
The remaining check for the display-wake fix is a deliberate sleep/reconnect
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
