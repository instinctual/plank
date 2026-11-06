# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Keep machine inventory,
credentials and private captures outside Git. This file records current work;
older candidate provenance remains in Git history and the artifact catalog.

## Shared source-first video FEC — candidate in progress

The operator authorized branch `shared-source-first-fec` from main `283dced7`,
including Kymux `0ec3ef2a`. Current candidate version is **1.4.08**. This replaces the
two platform-selected video senders with the accepted macOS ordering on every
platform: submit original symbols, then generate/send the same RaptorQ repairs.
The source iterator now constructs one symbol at a time, avoiding a padded
frame copy and a full-frame packet vector. The library's OTI partition,
symbol IDs, padding, repair bytes/count and current wire generation are retained.
Audio FEC, codecs, encoder rates and the Quinn controller are unchanged.
Reverse camera video also uses this shared sender; receiving Clients need no
protocol update for the Host ordering change.

Removed the old prepare-all production path, macOS-only feature switches and
obsolete two-archive comparison script. Timing diagnostics remain optional.
Current runbooks use one shared loopback runner on both Host builders; the
old Linux job labelled macOS FEC still selected the Linux path because of its
target-OS guard. It is replaced by actual shared-sender tests, plus native Mac
execution. Source tests cover exact upstream bytes at symbol boundaries,
multi-block/sub-block padding, lost originals/repairs and reordering. The C ABI
fixture now sends a 1.6 MB keyframe.

Local parser/source checks passed (38 cases), default/timing Clippy passed,
and the enlarged C ABI frame roundtrips passed both trust modes. The first
local 150 Mbps matrix failed in its zero-injected-loss phase with a frame gap
and four proxy socket drops. An isolated unchanged-main comparison also failed
in its zero-loss phase and recorded 2,113 proxy drops. Neither is a qualifying
performance pass. No retries or relaxed thresholds were used; hosted native
gates remain required. Failure reporting now retains transport/FEC snapshots.
Evidence is under `artifacts/qualification/shared-source-first-fec-1.4.06/`.
No deployed session or system networking setting has been changed.

The first candidate `9c6fc521` / Kymux `258520c7` passed hosted transport
`42282420253` and signed Mac Host `42282430816`, including three 150 Mbps loss
matrices each. Mac package 1.4.06 is retained in its original catalog. Linux
build `42282425564` passed all three matrices, then failed the new 1.6 MB C ABI
test: Quinn evicted 430 unsent datagrams (606,300 bytes) from its 1 MiB queue,
exceeding the repair budget. The network loss counters stayed zero. This is
local queue pressure, not a RaptorQ byte mismatch. All failure logs are retained.

The operator selected a larger bounded queue first, preserving existing
immediate submission/oldest-eviction behavior. **No send_datagram_wait change
has been made.** Kynet now defines one 4 MiB outgoing queue constant and uses
it for native server/client endpoints on both platforms. This buffers bursts
on demand; it does not set playback delay or alter the 2 MiB in-flight floor.
The stall fixture uses the identical shared setting and still requires actual
overflow and prompt recovery after a long hold. The all-lanes roundtrip and
C ABI fixtures both use a 1.6 MB frame. Local 4 MiB C ABI tests pass both trust modes
with zero queue evictions. New 1.4.07 evidence is kept separately from 1.4.06.

The 1.4.07 hosted stress run hit 748 unintended proxy kernel drops after the
long ACK hold; its 2 MiB effective receive buffer could not absorb the released
burst. The Mac matrix separately missed a 100 ms frame deadline. Both failures
are retained, with no qualifying retry. The test-only proxy now has a dedicated
receive worker and an 8 MiB/4,096-packet bounded ingress FIFO so forwarding/ACK
release does not block socket draining. Saturation still fails, both workers
join on stop/error, and kernel-drop/frame/latency gates remain. Timeout failures
now preserve transport/FEC snapshots too. No product socket or system sysctl
is changed by the test harness. Local VM tests still encounter
loopback receive loss and are not performance acceptance. Candidate 1.4.08
contains the same production queue/FEC code as 1.4.07; only test diagnostics,
fixture capacity and version changed. New hosted qualification is pending.

Next: commit/push this exact candidate, rerun the hosted transport gate and
both Host package builds, and record actual results.
Do not merge or publish a release. Installed Linux encoder/playback/loss
acceptance remains separate from synthetic/hosted gates.

## Live Client connectivity — corrected 1.4.05 merged

Root/Client branch `client-live-connectivity` started from accepted main
`65c2624f` / Client `09e05360`. Exact **1.4.05** package source is root
`351e721f10439a029f75da6b3f9125cad8d249fe`, Client
`c97f8575d007481d886dfb15bc69354961a61ed6`; both are committed and pushed.

The Internet dialog checks every configured IPv4 address about once per second,
retains results between rounds, and has no Refresh button, explanatory paragraphs
or Live/timestamp line. Its result area and Close spacing are compact. Normal
checks use the configured interval only while the main window is visible;
hiding/minimizing cancels timers/probes and showing it checks immediately.
One scheduler serializes live/background rounds and cancellation. Session
recovery, Host polling, QUIC health and stream RTT are unchanged. Add bookmarks
now explicitly ignore outside clicks and are modal; Edit retains its existing
Escape-only policy. Action buttons and Escape remain available.

**Do not install 1.4.04.** Its duplicate Edit-dialog `closePolicy` prevented
`PcView.qml` from loading, hiding bookmarks/Add and breaking Back. Saved
bookmarks were intact; no settings deletion/reset was performed or is needed.
The operator reported this after the build-only checks passed. The old full
launcher test logged nested QML failures but did not reject them. The repaired
check requires the actual bookmark-page completion marker as well as outer
window readiness, and rejects component/StackView/duplicate-property errors.
It rejects all three saved faulty CI launcher logs; the runbook documents this
failure signature. Both old packages are marked DO-NOT-INSTALL in their catalog
and retained only for provenance. Private machine logs/settings stay outside Git.

Hosted Ubuntu run `42194901081` and signed Mac run `42194905843` passed on their
first attempts at the exact corrected source. Each connectivity suite reports
47 passing results, including live updates, cancellation/reaping, slow rounds,
production hide/minimize/restore binding, and compact dialog layout. The Ubuntu
full launcher passed all three fresh-profile runs with the bookmark page ready
and no nested QML failures. Existing Client/render/package gates passed, along
with 122 portable CI policy tests. The prior fixture's QProcess teardown warning
is absent after waiting for its asynchronous cancellation before destruction.
All dependency caches were reused; Ubuntu also restored compiler outputs.
No dependency upgrade or forced bootstrap.

Verified originals are collected under
`artifacts/packages/candidates/1.4.05-client-live-connectivity/`:

- `linux/plank-client_1.4.05-client-live-connectivity_amd64.deb`
- `macos/plank-client_1.4.05-client-live-connectivity_arm64.pkg`

The Mac PKG is signed, notarized and stapled. SHA256, source pins and original
per-product manifests match the local catalog. Logs, Qt reports, regression
controls and generated screenshots are in
`artifacts/qualification/client-live-connectivity-1.4.05/`. Dialog layouts were
visually inspected; download staging was removed. Signing policy `65721204`
should be removed when retiring this branch. The redundant all-product push
run `42194853835` was cancelled; no Host package was requested.

On November 6 the operator authorized commit, push and merge. Client main was
fast-forwarded to the exact tested `c97f8575` tree and pushed before the parent
merge. Both repositories now have the corrected work on main at version
**1.4.05**. No separate detailed installed-retest report was provided; retain the
distinction between the recorded CI checks and live acceptance. No remote
installation or release was performed. The installers above remain original
branch candidates and must not be relabeled as mainline packages.

## macOS login handoff — 1.4.03 accepted and merged

Work on `macos-login-handoff` started from `4aca1bf3` and includes the accepted
mouse-delta fix. Both fixes are now merged into main at version **1.4.03**.
A captured first post-reboot login showed
the sign-in worker draining normally, while an immediate Client reconnect hit
that retiring worker and received authentication `denied`. The Client correctly
treated that as terminal; the desktop worker became ready about four seconds
later. Neither the Client application nor machine coordinator crashed.

Mac Host start/respond now use the existing `busy` response when graphical
authority is unavailable or changes during verification. Clients already map
this to retryable 503. Stale challenges/tokens/leases are still pruned, no
authorization crosses a graphical generation, and actual verifier rejection,
account mismatch, malformed input, replay in an active scope and explicit
same-scope revocation remain denied. No Client or protocol-version change.

New native cases cover login/logout, response after watchdog pruning, changes
during verification, concurrent retirement/revocation and password wiping.
The real loopback HTTPS cross-UID handoff gate also checks start/respond while
the old listener remains reachable after authority retires. Its signal is
synthetic-fixture-only; no production diagnostic/control endpoint is added.

Source `54cdf2b11a093bf582f83dde16f514a421d9ad8d` is committed and pushed.
Signed GitHub run `42185149530` passed on its first attempt, including 591
authentication assertions, the real TLS retirement/cross-UID handoff test,
its existing EADDRINUSE negative control, and the native session/input/package
gates. Existing Client reconnect-policy, 121 CI policy and 16 package-catalog
checks passed locally. The build used caching, but both exact Rust/Cargo keys
missed and were populated; no dependency version changed or forced bootstrap
was requested. Do not describe this run as a cache hit.

Signed, notarized and stapled installer, downloaded and checksum/source-verified:
`artifacts/packages/candidates/1.4.03-macos-login-handoff/macos/plank-host_1.4.03-macos-login-handoff_arm64.pkg`.
The original manifest equals the collected manifest. Qualification evidence is
in `artifacts/qualification/macos-login-handoff-1.4.03/`. Temporary download
staging is removed. Exact-branch signing policy `65716927` should be removed
when retiring this branch; redundant all-product push run `42185127914` was
cancelled because only the affected Mac Host package was requested.

On November 6 the operator confirmed that the candidate fixes the reported
first-login failure and authorized commit, push and merge. The accepted scope
is that reproduced login handoff; do not infer separate installed macOS 26.7
or every login/logout scenario from this report. The QuickTime mouse fix below
is also accepted and included. Private machine evidence stays outside Git.
Client/Linux Host pins are unchanged. No agent-driven installation, reboot,
logout or live session change was performed, and no release was requested.

## macOS mouse motion — accepted and merged with login handoff

Branch `macos-mouse-deltas` starts from main `32c92612`; version **1.4.02**.
The operator approved a Mac Host fix for the built-in screen-recording area
selector refusing to move/resize. Read-only checks found the full native
display geometry and confirmed button/drag delivery, but the passive listener
could not expose individual posted-event fields. An unposted Quartz check
confirmed that constructing a mouse event with a changed absolute position
leaves both movement deltas zero. Production code never filled them in.
The operator's installed test below confirms that supplying them fixes the
reported recording-area behavior.

The Mac Host now derives X/Y movement from successive mapped Quartz positions.
It rounds positions before subtraction so slow Retina motion accumulates
correctly; rejected delivery retains the prior baseline through the existing
state rollback. Mouse-down/up identities, pointer mapping and tablet behavior
are retained. No Client, Linux Host, transport or dependency change is needed.
New native regressions inspect both Quartz and AppKit deltas for all five
buttons, native 5K, scaled/negative-origin displays, motion reversal, stationary
reports, coalescing, rejected/malformed input and sub-point accumulation.

Source `300c743ef94aa9815be9cf3af91721a17a075186` is committed and pushed.
Signed GitHub run `42178253865` passed on the first attempt, reusing both
Mac Host Rust/Cargo caches. Portable checks passed (121 CI policy and 16
package-catalog tests). Hosted native checks include 3,863 mouse/input
assertions, 1,537 pen assertions and 216 native-input assertions across eight
scenarios, plus the existing display/authentication/session/package gates.
These construct/inspect events; they do not prove the live selector is fixed.

Signed, notarized and stapled original installer, downloaded and verified:
`artifacts/packages/candidates/1.4.02-macos-mouse-deltas/macos/plank-host_1.4.02-macos-mouse-deltas_arm64.pkg`.
The original manifest equals the locally collected manifest; SHA256 and source
pin are verified. Evidence is in `artifacts/qualification/macos-mouse-deltas-1.4.02/`.
Temporary download staging is removed. The exact branch has signing policy
`65711552`; remove it when retiring the branch. The redundant all-product push
run `42178245127` was cancelled; only the affected Mac Host package was requested.

The operator installed this candidate and rebooted; installed version was
confirmed during the separate login-handoff investigation above. On November 6
the operator confirmed that the QuickTime screen-recording boundary is fixed.
That accepts the reported selector behavior in the tested session; it does not
claim separate installed Retina/all-button validation. No remote installation
or Host/session restart was performed by the agent.
Merged into main through `macos-login-handoff`; no release was requested.
The recorded installers retain their original candidate identities. Temporary
read-only collectors were removed. Private machine evidence remains outside Git.

## Kymux reconciliation — merged; 1.4.01 packages ready

The operator authorized merging the tested reconciliation and PLANK #28 on
2026-11-05, followed by all four mainline candidates without publication.
PR #28 merged as `c7857982`; the reconciliation merged as `310210a8`.
Exact root `ad1b32474b7affcd72fa00f21be9b8e891ce4546` is the **1.4.01** package
source, separate from the retained 1.4.00 installers. Client
`09e0536079d761a5d4e7e5d2133e719912f6abc7` only adds the bundled changelog;
Linux Host remains `2281c3ed6dbf5779ec75dba15a8a4f165efba1fa`. All four builds
use GitHub-hosted Actions with dependency caching enabled:

- Linux Host `42083601539`: passed; RPM downloaded and checksum-verified.
- Ubuntu Client `42083607155`: passed; DEB downloaded and checksum-verified,
  with Qt test reports retained.
- Signed macOS Host `42083612368`: passed; PKG downloaded and checksum-verified.
- Signed macOS Client `42083619097`: attempt 2 passed; PKG downloaded and
  checksum-verified. Attempt 1 timed out
  waiting for the first frame swap in the unchanged `MacQtWindowTest`; preceding
  Metal rendering/color tests passed. The same source passed the full window
  test on one retry, with every gate retained and no code change. The initial
  failure's underlying cause is not proven; its log is preserved.

The combined source passed all 121 CI policy tests and 16 package-catalog tests.
Both Host dependency caches were reused (four Linux groups, two macOS groups).
Ubuntu reused Rust, Cargo and compiler caches; its exact FFmpeg cache key missed
and was rebuilt and saved without changing dependency versions or cache policy.
The successful Mac Client retry missed its four exact cache groups and populated
them. No forced clean bootstrap was requested; do not describe a cache miss as
successful dependency reuse.
Package manifests, logs, run metadata and recursive source pins are retained in
`artifacts/qualification/mainline-1.4.01/`. Mainline installers are collected in
`artifacts/packages/releases/1.4.01/`; this path does not imply publication.
Both Mac installers are signed, notarized and stapled. All four have passed
their hosted build/component/package gates and local manifest/SHA256 checks:

- `linux/plank-host-1.4.01-1.el9.x86_64.rpm` — Rocky 9.7.
- `linux/plank-client_1.4.01_amd64.deb` — Ubuntu 26.04.
- `macos/plank-host_1.4.01_arm64.pkg` — macOS 26.7 and newer.
- `macos/plank-client_1.4.01_arm64.pkg` — macOS 15 and newer.

Exact sizes, checksums and pins are in the catalog's `manifest.json` and
`SHA256SUMS`; original per-product manifests remain in qualification evidence.
No installation, live session acceptance, GitHub release or release tag was
performed. The next gate is installed-session testing of these exact packages.

Branch `kymux-reconciliation` starts from main `b67727ad`. Kymux's shipping
`dependency-refresh` pin `12af484e` and its separate `main` tip `04c3f179`
were merged without conflicts as `7f7893f`; `0ec3ef2` adds byte-budget and
exact FEC-accounting regressions. Kymux `main` is now fast-forwarded and pushed
to `0ec3ef2a068d2267eba38a30cdc60f28fd17aaf2`, containing both histories.
Root `af38de84` pins the candidate; `bf5c6046` adds its contract/handoff notes.
The PLANK parent gitlink is now merged to the reconciled pin. Original PR #26
is closed as superseded by the merged reconciliation; do not restore its older
`04c3f179` API/dependency snapshot.

This preserves the newer upstream generic protocol/serialization APIs and all
existing manifests/lockfiles, including RaptorQ 2.0.1. The runtime delta is only
the bounded video receiver retirement and budget diagnostics in two KyProto
files. Reliable configs remain ordered, stale frames can be retired at the
existing limits, and fresh oversized bursts still fail. Wire generation,
sender rate/window/queue policy, MTU handling, audio and reliable-data bounds
are unchanged. Do not replace this with PR #26's original older pointer.

Hosted transport qualification passed at exact root `af38de84` in
`42075309641`: state/queue accounting, ACK/receiver stalls, native FEC,
reliable pressure, cancellation, microphone and camera lanes. All six 150 Mbps
loss matrices (0/0.5/1/3/5% loss) recovered every frame with zero unrecovered
symbols; all 30 phase performance gates passed. Brief ACK holds caused zero
drops; actual sender/receiver overflow recovered on the existing connection.
The macOS feature configuration runs on Linux in this workflow, not macOS.

All four hosted product builds passed at root `bf5c6046` in `42076080008`,
including the Mac Host's real encrypted C-ABI loopback and the Linux Host's
native recovery gates. Existing dependency caches were enabled; no forced
bootstrap was requested. This is compilation/component/package validation,
not installed session acceptance. Both Mac jobs were unsigned validation builds.
No installation, production impairment, signing or release was performed.
Logs, run metadata and a parsed transport summary are retained under
`artifacts/qualification/kymux-reconciliation-20261105/`.

Review of PLANK-specific Kymux changes found the rejected datagram batching,
expanded send queue, blocking datagram submission and application pacer already
removed/reverted. Keep the active security bounds, MTU handling, telemetry,
packet draining and recovery. Simplifying the macOS source-first sender needs
a measured comparison; this reconciliation does not remove it or claim it is
redundant. Duplicate historical drain commits do not duplicate runtime code.

Kymux PRs #2 (js-sys) and #4 (kywasmtime) were closed as requested because the
shipping products do not use those browser backends. PLANK #28's failed Linux
Client job passed on rerun (`42060946515`, attempt 2); its original failure was
a download connection reset. #28 is now merged. The NVENC-headers update stays
open and deferred because its driver requirement exceeds the qualified floor.

## Mainline packages ready — 1.4.00, not published

On 2026-11-05 all four desktop packages were rebuilt on GitHub-hosted Actions
from exact main root `2a82edd54f4beb556fd5754f0091b960f32043cd`. No product or
build-script changes were needed. Successful workflow runs:

- Linux Host: `42061683466`.
- Ubuntu Client: `42061722088`.
- Signed macOS Host: `42061520267`.
- Signed macOS Client: `42061726889`, attempt 2. The first attempt stopped at
  a dependency-download connection reset (`curl` exit 35); only the failed job
  was retried at the same source revision.

All packages are downloaded and SHA256-verified under
`artifacts/packages/releases/1.4.00/`:

- `linux/plank-host-1.4.00-1.el9.x86_64.rpm` — Rocky 9.7.
- `linux/plank-client_1.4.00_amd64.deb` — Ubuntu 26.04.
- `macos/plank-host_1.4.00_arm64.pkg` — macOS 26.7 and newer.
- `macos/plank-client_1.4.00_arm64.pkg` — macOS 15 and newer.

Both macOS installers are signed, notarized and stapled. Hosted build,
component/regression and package gates passed, including the Client bookmark
policy tests. This does not add installed hardware/session acceptance.
Original manifests, build logs, run metadata and Qt test evidence are retained
under `artifacts/qualification/release-1.4.00/`. Main's updated dependency caches
were populated; no forced clean bootstrap was requested. Duplicate download
staging was removed after catalog verification.

The operator requested packages only: **no GitHub release, tag, deployment or
installation** was performed. The `releases/` catalog denotes mainline package
provenance, not publication. Source pins remain those recorded below.

## Merged to main — 1.4.00 desktop baseline

On 2026-11-05 the operator authorized merging the complete `client-bookmarks`
candidate. Root, Client and Linux Host are now on `main`, fast-forwarded to
the tested source without conflict resolution or new runtime changes. Root
`6de6f8ef` is the merged candidate tip; this handoff update follows it.
The **1.4.00** baseline includes dependency refresh, SDL removal, native cleanup,
independent bookmarks, video/reconnect recovery, sender-window headroom and
headless bookmark filtering. Native Apple/AVP work remains separate.

Canonical common-C `plank/client` and `plank/host`, plus build-deps `plank/main`,
were also fast-forwarded to their existing tested pins. Kymux stays pinned to
`12af484e` on `dependency-refresh`: its own `main` has separate FEC-retirement
changes that were not in this candidate. Do not repin it to that branch head or
delete the retained dependency branch without separate reconciliation/testing.
The subsequent mainline builds are recorded above. Existing branch-qualified
packages keep their original provenance; never rename candidates as mainline
packages.

Linux `serverinfo` now publishes the configured startup policy as a versioned
UI hint. Both desktop Clients use one layout dropdown with stable saved values:
virtual Hosts omit Match Host; physical/unknown Hosts retain manual choices.
The edit dialog also uses the last authenticated topology while offline, only
for the original address. Unsupported saved physical choices select Match
Client in the editor; Cancel leaves storage unchanged. Discovery never changes
stored bookmarks, trust or authenticated launch policy. Mac Host layout choices
are unchanged. New-bookmark filtering requires the updated Linux Host; existing
bookmarks can use previously authenticated topology.

Shared QML tests cover both dialogs, stable single/dual values, invalid saved
selections, stale discovery replies, offline hints, address changes and Mac
fixed-layout behavior. Versioned parser vectors cover invalid/unknown hints.
Local checks: 121 CI policy tests and 16 package-catalog tests pass; shell syntax
and whitespace checks pass. Dependency pins are unchanged.

Source pins: Client `e34dfd131ab0f35493f186666ddb8464d82b2dbd`, Linux Host
`2281c3ed6dbf5779ec75dba15a8a4f165efba1fa`, Kymux
`12af484eb307351b068aba96da12afce46f4614b`. Root `a3f4a327` contains the product
change; `a1ea856d` updates the Linux packaging source check to expect the stable
layout value rather than the former dropdown index. The first Linux Client run
stopped at that stale check; it was not an application compile failure.

Hosted Linux Host run `41976626854` and signed macOS Client run `41976630163`
passed at `a3f4a327`. Linux Client run `41978798249` passed at `a1ea856d`, including
the sanitizer/compositor and package checks. Both Clients passed all five
bookmark-choice tests and all 26 output-topology tests, including the new policy
vectors. The Ubuntu rerun restored Rust, Cargo and FFmpeg dependencies and reused
compiler outputs; bootstrap took two seconds. The earlier Host FFmpeg cache miss
followed changed installed NVIDIA configuration-package metadata; the compiler
remains pinned CUDA 13.2.

All three affected candidates are downloaded and checksum-verified under
`artifacts/packages/candidates/1.4.00-client-bookmarks/`:

- `linux/plank-client_1.4.00-client-bookmarks_amd64.deb`.
- `linux/plank-host-1.4.00-0.client_bookmarks.1.el9.x86_64.rpm`.
- `macos/plank-client_1.4.00-client-bookmarks_arm64.pkg` (signed, notarized, stapled).

Each manifest retains its original root provenance and checksums; the final root
change affects only the Linux package source check. Mac Host code is unchanged,
so no new Mac Host package was built for this task. Logs, run metadata, original
manifests and Qt test evidence are retained under
`artifacts/qualification/headless-bookmarks-1.4.00/`. No installed session test,
deployment or release has been performed for these candidates. Current code and
notes are committed and pushed on `main`; the prior candidate records below
retain their build-time branches, versions and acceptance limits.

## Ready for installed testing — sender-window recovery candidate

The operator resumed the separate sender-stall investigation and explicitly
prohibited disruption of the affected production pair. A new test Client is
being prepared. Use isolated loopback tests meanwhile; no production SSH,
impairment, package installation or service change is needed for this stage.

Saved Host evidence shows an approximately 140KiB in-flight window filling,
send progress stalling and the bounded 1MiB outgoing datagram queue evicting
packets. The original trigger remains unproven. Hosted comparison run
`41738601498` at `2ae65baf` passed all 12 encrypted loopback cases and existing
native Linux/macOS FEC regression matrices. With no injected packet loss,
brief ACK holds caused 474/1024 sender drops in the baseline; a 2MiB minimum
eliminated both. A 1MiB minimum did not cover the higher-rate case.

Candidate **1.3.17-client-bookmarks** adds that single bounded minimum in the
shared Host rate controller. It keeps encoder targets, FEC, outgoing-queue size,
protocol and Client behavior unchanged. Quinn's own pacing remains coupled to
window/RTT, so this can increase bursts; no independent pacing layer is added.
The temporary alternative-controller wrapper is removed. The retained test
asserts zero drops for brief holds and automatic resumption after actual sender
overflow or receiver-queue overflow. Hosted run `41739851250` passed the final
four-case stall gate, transport/unit checks and native FEC/reliable/cancellation
checks for both submission paths. Brief holds lost zero datagrams; long holds
still dropped data and automatically resumed. See
[the investigation](docs/development/investigations/sender-window-recovery.md).

Candidate package source is `60d72591ce78ef0627541022236477ffd3af97ca`, with the
unchanged Client/Linux Host/Kymux pins recorded for 1.3.16 below. Linux Host run
`41740636134` and signed macOS Host run `41740645876` both passed from that exact
source, reusing the existing verified dependency caches. Both packages are
downloaded and checksum-verified under
`artifacts/packages/candidates/1.3.17-client-bookmarks/`:

- Linux RPM: `linux/plank-host-1.3.17-0.client_bookmarks.1.el9.x86_64.rpm`, SHA256
  `91447bc7e6a41cf69e2a864c36fd3f0fd277d26c930cf1d95089451d2db1bf97`.
- Signed/notarized/stapled Mac PKG: `macos/plank-host_1.3.17-client-bookmarks_arm64.pkg`,
  SHA256 `2761df7fa76d1af6022a68588d803c17b18c493392c792f36f39e6a327567e70`.

Original manifests, build logs, run metadata and the baseline/final comparison
records are in `artifacts/qualification/sender-window-20261103/`. Duplicate
download staging is removed. No Client package is required for this Host-only
policy change; existing 1.3.16 Clients can test it. This qualification did not
include installation or live acceptance. Its code is now merged as part of the
1.4.00 baseline above; no build or impairment is left running.

The loopback datagrams include FEC-equivalent load but do not claim codec or
RaptorQ recovery; the native regression matrix covers that separately. Live
acceptance awaits a newly authorized, qualified Client. Do not use the excluded
Gen11 target or either protected production machine.

## Gen11 Client hardware — unqualified; investigation stopped

The operator excluded Intel NUC Gen11 (Tiger Lake) from qualified Client
hardware on 2026-11-03. Do not use it for release acceptance or resume its
investigation without new direction. The single-monitor comparison is cancelled.
This is a qualification decision, not a runtime blacklist or a proven driver
fault. The evidence and limits are recorded in
[`docs/hardware/intel-nuc-client-qualification.md`](docs/hardware/intel-nuc-client-qualification.md).

Full 1.3.16 sessions repeatedly triggered video-engine GPU hangs with zero
unrecovered video data. Five ten-minute independent controls passed, including
the exact failing stream through the shipped FFmpeg libraries and through
fenced offscreen GPU sampling. Root cause remains unresolved. Diagnostic-only
hosted runs `41724066016` (`8fb8fef5`), `41729310186` (`929d2fcc`) and
`41732372949` (`d8f2930a`) passed; the installed FFmpeg library hashes matched.
Results are retained in `artifacts/qualification/vaapi-isolation-20261103/`;
private footage and machine evidence remain outside Git.

The unbuilt decoder-recovery experiment was privately preserved and removed
from the working tree, including its unaccepted terminal retry policy. The
Client is clean at `b859e34318ba315ad5068e2e00aa50120d26fe92`; the subsequent
1.3.17 version belongs to the sender-window candidate above. Existing transport/reconnect and
hardware-selection fixes remain intact. Temporary remote probes and recordings
were removed after preserving the evidence; the ordinary Client is restored
without preload recording. No package, driver or system configuration change,
active collector or network impairment remains from the investigation.

The earlier ACK-delay investigation requires a different qualified Client;
do not continue it on the excluded Gen11 test machine.

## Reliable-data pressure and reconnect recovery — installed Linux checks complete

Candidate **1.3.16-client-bookmarks** was built from that branch and includes
all preceding fixes. A live 1.3.15 session ended when the bounded
reliable-data receiver filled. Its immediate reconnect reached the Host before
old-session retirement and incorrectly reported a transfer. No deliberate
packet loss had been applied; private timestamps/logs remain outside Git.

- Shared transport now pauses the reliable-data reader when its 64-record/8MiB
  queue fills. It resumes on successful FFI dequeue without evicting messages,
  growing the limits or disconnecting. At most one extra bounded record waits;
  cancellation remains prompt and invalid sizes remain rejected.
- The Client routes occupied-session responses through its existing retry
  policy, on Linux and Mac Hosts. Explicit takeover notifications, invalid
  credentials, TLS rejection, user Disconnect and configured automatic timeout
  remain terminal. Automatic recovery never requests takeover.
- Local checks: 64 transport unit tests pass; the encrypted bidirectional test
  passes packet/byte pressure, pauses over two seconds and ordered drain. The
  Client recovery-policy fixture and 121 CI policy cases pass. The loss runner
  now requires the pressure-recovery test instead of expecting queue overflow
  to kill the connection.

Linux package source is root `6aa4f0d29c6585f2063c0fada2cd50a4b7a05d02`, Client
`b859e34318ba315ad5068e2e00aa50120d26fe92`, Linux Host
`2f2f207827a907fb6aaf2b8ac3833507389cd678` and Kymux
`12af484eb307351b068aba96da12afce46f4614b`. Hosted run `41590277670`
passed all four product compile/test jobs. Linux DEB/RPM packages are verified
in `artifacts/packages/candidates/1.3.16-client-bookmarks/linux/`. The initial
Mac jobs were unsigned checks; signed delivery is now complete as described
below. Build logs, original manifests, recursive pins and Qt evidence are in
`artifacts/qualification/data-backpressure-1.3.16/`. Dependency caches were
reused; no FFmpeg or dependency version/patch changed.

The operator authorized installing the exact Client and subsequently the Host
on the test pair. Both package/installed executable hashes match. Administrator
configuration and the Host certificate were preserved. Package hashes:

- Client DEB: `62b282f6eca1a72f70c0c46300c5a822ef36dbe7d9de6b5a760ae241a4ac41f9`.
- Host RPM: `e8a5b6abee088b1af5461ead8ca45d51f3fb255d45d1438a2859d10b47844a04`.

Installed qualification used HEVC 10-bit 4:4:4 identity, 5120x2160 at 60fps and
a 50Mbps target. Client-ingress random loss matched only its active QUIC UDP
tuple, affecting all incoming lanes, with independently guarded cleanup:

- Client 1.3.16 / Host 1.3.15: full one-minute stages in 0.5% increments through 8%
  completed without logged recovery errors. During the 8.5% stage the operator
  reported after-FEC loss; two IDR requests each produced a Host refresh about
  19ms later. Loss was removed and the operator confirmed normal playback
  without reconnecting. The connection later recorded 18 unrecovered source
  symbols; these are connection-wide totals, not per-stage measurements.
- The authorized Host upgrade to 1.3.16 restarted only the Host/PAM services.
  The Client retried while the listener was unavailable and automatically
  reconnected with its retained renderer after about 11 seconds. It did not
  report a false takeover or require the operator to restart the Client.
- With both sides on 1.3.16, an additional 60-second 7% test dropped 22,902 of
  325,074 packets (7.045%). No IDR/reconnect or audio underrun/missing-frame
  event was logged, and the operator confirmed normal picture playback.
  The exact after-FEC counter for this second run was not independently read.

All injected-loss tables, transient services/timers and remote test/install
staging were removed; the session remains connected. Raw machine evidence is
private; the sanitized qualification summary remains in the artifact directory.
This short random-loss matrix does not qualify burst loss, every bitrate, or
live Mac behavior. Live queue saturation was not directly observable; the
encrypted loopback test specifically exercises that path. Its code is now in
the merged 1.4.00 baseline; this does not imply a published release.

Signed Mac delivery is complete from root
`431902bc727b2065209aedfc7f701acced10e1e9` (only HANDOFF differs from the Linux
package source; all product/dependency sources match). Host run `41595563892`
and Client run `41595567493` passed signing, notarization, stapling, Gatekeeper
and package gates. All existing dependency caches were restored and verified.
The two PKGs are downloaded/checksum-verified in the same candidate catalog's
`macos/` directory:

- Host `plank-host_1.3.16-client-bookmarks_arm64.pkg`, macOS 26.7+:
  `72fe9dc2d381ce54a70d962b0bf59ecbda521f30d939e7aab84c360834d4f52b`.
- Client `plank-client_1.3.16-client-bookmarks_arm64.pkg`, macOS 15+:
  `dfed633d4ae19502291745257e417ab5ad1db4eb16b6577463867ee7c6b4fba9`.

Signed logs, run metadata, original manifests and Client UI test evidence are
retained with the qualification reports. Duplicate staging was removed. No Mac
installation or installed Mac acceptance occurred; those checks remain open.

## Ready for installed testing — HEVC hardware selection and NVENC recovery

Original root, Client and Linux Host branch: `client-bookmarks`; candidate
**1.3.15-client-bookmarks**. Client `412c0c2b`; Linux Host `2f2f2078`.
The preceding independent-bookmark and cleanup work is included in main.

An inspected Linux session received video continuously, but decoded too slowly
in software and repeatedly overflowed its decoder queue. Input continued to
reach the Host; the frozen image made typing appear broken. Two fixes are
implemented, with no production installation or restart:

- The FFmpeg9 identity-GBR patch had been rebased into `map_to_alpha_format()`,
  instead of the hardware-offer switch in `get_format()`. Its hash/application
  gates passed but did not prove behavior. Corrected both 8/10-bit aliases;
  added a source-location guard and real-fixture hardware-offer tests for both
  desktop Clients. Tests choose software after inspecting the offered formats
  so hosted checks require no GPU. Installed hardware acceptance remains open.
- The Linux NVENC session discarded refresh requests inside its one-second
  rate limit. Client/Host timing skew placed recovery requests inside that
  window, leaving the decoder waiting for an IDR. Retain and coalesce a pending
  request until its deadline; ordinary frames do not clear it. No extra thread,
  periodic keyframes, protocol change or queue expansion is introduced.

The operator approved hardware-only HEVC decoding. The policy applies to every
HEVC profile from both Hosts, including Apple HEVC. H.264 software decoding
remains supported, including NVENC H.264. Startup and decoder-reset failures
explain the hardware requirement; no codec/profile substitution is permitted.
The obsolete caller-selectable decoder mode is removed in favor of one policy.
The Mac Client's private FFmpeg additionally requires hardware in VideoToolbox's
HEVC decoder specification, preventing an internal Apple software fallback.
Private machine evidence and the final session counters remain outside Git.

Local gates pass: 121 CI-policy cases, four source-guard cases, actual old-patch
rejection, the complete selectable-profile decoder policy, and NVENC deferred
requests normally and under ASan/UBSan. All three hosted builds passed on their
first attempt at package-source root `a09cb615ca18dc8bad25e02380c1efd007252b80`:

- Linux Host `41563355878`: NVENC request regression, existing input/PAM tests
  and RPM gates passed.
- Ubuntu Client `41563352014`: real FFmpeg hardware-format offers for Main10
  and identity 8/10-bit HEVC passed, including sanitizer runs. Profile policy,
  component/compositor/launcher and package checks passed.
- Signed Mac Client `41563360359`: corresponding VideoToolbox format-offer and
  policy tests, existing Metal/Client checks, signing, notarization and stapling
  passed. Mac Host code is unchanged and needs no rebuild for these fixes.

All three packages are downloaded under
`artifacts/packages/candidates/1.3.15-client-bookmarks/`; their original builder
checksums pass. Logs, manifests, run metadata and the test summary are in
`artifacts/qualification/video-recovery-1.3.15/`. Installers:

- `linux/plank-host-1.3.15-0.client_bookmarks.1.el9.x86_64.rpm`
- `linux/plank-client_1.3.15-client-bookmarks_amd64.deb`
- `macos/plank-client_1.3.15-client-bookmarks_arm64.pkg`

Code and notes are included in main. The later 1.3.16 installed recovery checks
are recorded above. Preserve H.264 software decoding and the explicit error
when selected HEVC hardware decoding is unavailable. Hosted format-offer tests
cannot qualify actual GPU surfaces or sustained playback.

Cache record: Ubuntu reused Rust/Cargo/compiler outputs and rebuilt the changed
FFmpeg library. Mac reused Rust/Cargo/Qt and rebuilt its shared native-dependency
prefix for the FFmpeg fixes. This branch had no Linux Host dependency cache;
the first Host build populated it. Do not repeat a dependency bootstrap merely
to update these final notes.

## Completed candidate — independent bookmarks for one Host

Branch: `client-bookmarks`, based on the complete `code-simplification` candidate
below. Client-only candidate version: **1.3.14-client-bookmarks**.

This work and its preceding cleanup are now in `main`. The candidate records
below retain their original provenance; use the current mainline source for
new work, not the superseded candidate branch.

Add now creates an independent, permanent bookmark ID instead of replacing the
record for the entered address. Edit accepts shared addresses and preserves the
bookmark ID. Existing saved IDs/settings remain valid. Names, layouts, profiles,
bitrates and Client-display choices remain per bookmark. Host TLS trust remains
endpoint-scoped and is not reset by adding/deleting a bookmark. Changing a
bookmark's destination clears its old token and identity key.

The production-manager regression suite covers same-address Add/Edit,
save/reload, existing IDs, deletion, shared trust, online metadata and supported
address forms/Mac profiles. The delayed settings writer now locks its Host-map
snapshot and synchronizes shutdown with its wait predicate. Both Client build
scripts run this suite. All nine cases passed on both platforms, along with
the existing Client/component/package gates and 119 CI policy tests. No Host
changes or installations were required for this Client-only feature.

Package-source root: `d013be4a69068c2d46283fad18bb70c11f63ce8c`;
Client: `f6b5ea1d` (other pins unchanged from the cleanup candidate).
Ubuntu run `41510795259` and signed Mac Client run `41510800187` passed on
their first attempt. The Mac PKG is notarized/stapled. Both packages are
downloaded under `artifacts/packages/candidates/1.3.14-client-bookmarks/` and
their SHA-256 checks pass. Original builder manifests, run metadata, logs,
recursive pins and summary are in
`artifacts/qualification/client-bookmarks-1.3.14/`.

Installers ready for manual testing:

- Ubuntu: `linux/plank-client_1.3.14-client-bookmarks_amd64.deb`.
- macOS: `macos/plank-client_1.3.14-client-bookmarks_arm64.pkg`.

These paths are relative to the candidate catalog above. No new Host package
was needed for this bookmark change; the previous four-product cleanup
candidate is preserved below. No test-system configuration was changed.

Next installed check: add two differently named bookmarks for the same Host
with different layouts/profiles/bitrates; edit one, restart the Client and
confirm both remain independent. Deleting one must retain the other.

Build lesson: this task's new branch could not restore unchanged dependency
caches held only on `code-simplification` while `main` had the older baseline.
The cold builds populated `client-bookmarks` caches. The runbook requires
checking branch/default-branch cache visibility before promising reuse. The
source baseline is now merged; a future mainline build must populate its caches
before sibling feature branches can restore those inputs. No cache-key
relaxation or dependency change was used to hide the original limitation.

## Completed candidate — native-only cleanup/refactor

Branch: `code-simplification`. All ten approved follow-up items are implemented
and pushed. **1.3.13-code-simplification** has passed the four products' hosted
build/component/package gates. Both Mac PKGs are signed, notarized and stapled.
This source is now merged. Its original candidate qualification did not include
release, installation or installed-session acceptance.

Package catalog: `artifacts/packages/candidates/1.3.13-code-simplification/`.
All four SHA-256 checks pass. Original builder manifests, logs, exact recursive
pins and `summary.json` are in `artifacts/qualification/code-simplification-1.3.13/`.

| Product | Package-source root | Successful build/validation |
| --- | --- | --- |
| Linux Host | `80a192a61d66710f7d0fadffeaedbe5f0e797611` | `41505308512` |
| Ubuntu Client | `bc959b800ff2351db29eba95ba9a4c59c19fd167` | `41497448295` Client job |
| macOS Host | `bc959b800ff2351db29eba95ba9a4c59c19fd167` | `41497448295` Host job; signed `41497504932` |
| macOS Client | `bc959b800ff2351db29eba95ba9a4c59c19fd167` | `41497448295` Client job; signed `41497522046` |

Final pins: Linux Host `7d9b16ce`, Client `8a989271`, Client common-C `0aa126f`,
Host common-C headers `209604a`, Kymux `12af484e` (unchanged). The source was built
on `code-simplification` / `code-simplification-host-headers`; the product and
common-C commits are now on their canonical branches. The final Linux-only code/packaging corrections do not
change Client or Mac product inputs. Their original packages/provenance are
retained, not relabeled. Documentation-only commits may follow these build roots.

Completed implementation:

- Client queues own final native input payloads; the Linux Host validates and
  injects them directly. Removed GameStream packet reconstruction, the second
  Host queue/dispatcher, controller/haptic APIs, relative-pointer APIs and
  generic direct-touchscreen forwarding. Raw-HID Wacom, normalized pen, absolute
  mouse, scroll, keyboard, bounded backpressure and persistent tablets remain.
- Removed unused recorder callbacks and the Client startup relative-mouse wiggle.
- Removed unselectable KMS product capture, GL/EGL conversion, GLAD, orphaned
  shaders and asset packaging/localization tasks. DRM discovery, standalone KMS
  probes and the independently generated display EDIDs remain.
- Simplified Linux encoding to active x264 and direct NVENC paths. Removed the
  unused FFmpeg hardware-frame encoder bridge, unreachable variants/options,
  generic conversion fallback and AV1 probing. NvFBC and Native X11 retain their
  selected profiles; empty x264 preset/tune settings retain their prior meaning.
- Removed dormant HDR metadata/callbacks; ten-bit SDR and RGB identity remain.
  Event type 1 and feature bit 0x02 stay reserved, not reassigned.
- Reduced Client decoder/renderer interfaces to the current Qt backends and
  mandatory exact-profile testing. Removed old decoder tables, H.264 SPS
  rewriting and h264bitstream. Owned IDRs retain the original encoded buffer.
- Cached Ubuntu planar-conversion shader descriptions by format, dimensions,
  plane mapping/stride orientation and range. Every frame still validates
  metadata and binds its current textures; no GPU wait or CPU readback was added.
- Updated the required build/source/package gates, tests, runbooks and inventory.
  The finished-RPM gate now has a fast fixture that catches stale payload
  requirements and rejects retired assets, missing EDIDs and unsafe log modes.

Validation passed: 119 CI policy tests; common-C 8/8 normally and with GCC14
ASan/UBSan; 58 Host input tests plus 2 core tests, each repeated/shuffled 25 times;
three 900-frame 150-Mbps loss trials through 5% injected loss with zero unrecovered
frames; original-H.264/owned-IDR decode fixtures on both Clients; Ubuntu normal,
sanitizer and compositor tests; Mac Metal color checks (630 cases); all finished
package gates and checksums. The optional-service and header-only packaging
checks also passed. These are component/build results, not live session results.

Superseded candidate runs exposed stale fixture expectations, declarations and
asset-path/artwork assertions after deletion. They were corrected without
relaxing selected codec/range requirements. The final successful runs above
supersede those failures; candidates 1.3.10–1.3.12 were not accepted or installed.

The prior Native X11/upload work remains included. Its isolated pinned-SHM
upload test improved median upload time by roughly 26–34%; live Xorg readback
showed no capture speedup. This is not an end-to-end performance claim.

Next: installed acceptance of the exact packages for capture/encode/decode/color,
Wacom recovery, A/V synchronization, display transitions and supported Mac
versions, as listed below. No further implementation item from this pass is
left pending. The preceding checkpoint is root `c886880`, Host `acd7054d`,
Client `7d628f60` and Client common-C `9838bb82`.

## Preserved checkpoints

- Root `0a32513`, candidate `1.3.05-code-simplification`: all five original
  simplification items and four hosted builds passed. Includes shared profile
  catalog, owned encoded frames, consolidated Client lifecycle, Mac display
  transactions outside the runtime lock and unsupported Windows Host removal.
  Exact pins/results remain in the plan and original package manifests.
- Root `94aeeee`, candidate `1.3.04-host-cleanup`: all four builds passed after
  retired crypto/socket/DNS, packaging/rendering, unused Host backends and
  schema4–6 compatibility removal. See the cleanup inventory and prior plan.

The previous eight-item follow-up and four-product qualification are preserved
in root `90cee00`/`b13dbca` and the 1.3.06/1.3.07 artifacts. Their detailed changes
and tests remain in the plan and Git history.

See [the simplification plan](docs/development/plans/code-simplification.plan)
and [cleanup inventory](docs/development/reviews/desktop-cleanup-inventory.md).
The original package and qualification directories remain intact. Both
checkpoints are now ancestors of main; merging does not imply release,
deployment or hardware acceptance.

## Included prior candidates and unchanged contracts

All earlier candidates remain intact under `artifacts/packages/candidates/`:

- `1.3.03-host-cleanup`: standard Mac Installer, run `41365218759`, root
  `0c29479ea72cd115a6d7e45f3a8474589df031d3`. Custom Requirements plug-in removed;
  authorized preinstall still rejects FileVault on or an unsuccessful query.
- `1.3.02-host-cleanup`: Linux Host run `41361778133`, root
  `7bce649341c45a0137b2e3afca5ea9a1b0dc6c48`; Mac Host run `41359912649`, root
  `ffec346936d20c610b1cd3fbfef538a51e971e40` (original filename retains its OS suffix).
  Includes inactive encoders/crypto/packaging removal, Mac `-O2` and bounded 20ms
  display-snapshot reuse with immediate invalidation; no auth ownership caching.
- `1.3.01-client-no-sdl`: Ubuntu run `41356244348`, Mac run `41356253597`, root
  `f5304a106af8e4e23b9be429d622c6e5d460ef19`, Client `7a9704fe`.
  Qt owns both desktop sessions; Ubuntu uses PipeWire, Mac uses Core Audio.
  SDL/SDL_ttf and the unused Client libswscale link are removed.
- `1.2.14-dependency-refresh`: all four builds and dependency qualification
  passed. See its plan and original package/qualification manifests for pins.

Exact package hashes, full source/submodule provenance and logs remain in the
corresponding catalog and `artifacts/qualification/` directories. Do not rename
or relabel older packages. None of these candidates implies live acceptance.
Standard Mac Host filenames omit the OS floor; metadata still requires 26.7+.
Mac Client remains one Apple Silicon package for 15+, built with SDK27 or newer.

Dependencies: FFmpeg9.0.2, Boost1.92, JSON3.12, Vulkan1.4.367, Kymux/Kyproto0.29,
Quinn0.11.12 / proto0.11.19 / udp0.5.16, Rustls0.23.46, RaptorQ2.0.1,
Rust1.99.1. NVIDIA595.104.02 / CUDA13.2 Update2 / NVENC SDK13.0.19 and the full
CUDA architecture list are unchanged. Transport remains `plank-native/2` with
bounded queues/parsers, fixed-MTU policy and no application datagram pacer.

## Separate work and remaining gates

The 18 fully merged parent-repository feature branches were removed locally and
from GitHub on 2026-11-05. Every deleted tip remains reachable from main. The
clean `kymux-reconciliation` and `macos-click-pairing` worktrees were retired,
including the former's linked Kymux checkout; canonical dependency repositories,
their branches, retained packages and qualification evidence are unchanged.
The 11 matching temporary `macos-signing` branch permissions were also removed.

Remaining local parent branches are `main`, `apple-native-integration`,
`native-builds`, `avp-dual-display`, `macos-host-test` and
`codex/macos26-host-test`. The two Host test branches and their signing permissions
remain, as do the native TestFlight permissions. The superseded PR #26 Dependabot
branch remains remote-only; it was outside the selected 18 merged branches.

Native Apple/AVP development and TestFlight automation remain on `native-builds`
and the dedicated AVP work branches; consult their own HANDOFF/plan before
resuming. Do not merge or remove those branches as part of desktop cleanup.
Contributor signing automation is documented in the GitHub build runbook.
Main protection was discussed but not authorized or enabled.

Hosted compilation does not replace installed acceptance. Remaining checks:

- Exact-format hardware decode/presentation, ten-bit color, 4K/5K, fullscreen,
  window scaling, Retina/notch and multiple displays.
- Wacom pressure, clicks, Tablet Margins, mixed local/remote tablet models,
  USB reconnect and network recovery. No device-reset workaround is added.
- Real A/V synchronization/listening soak, device changes, microphone/camera,
  clipboard, output restoration and logout/reconnect.
- Mac setup/permissions/uninstall, login screen, locked takeover and the identical
  Host package on 26.7 and 27; identical Client on 15 and 27. Chris owns 26.7
  session validation. Reference Macs remain read-only unless specifically assigned.
- Deferred Wallpaper/Screen Saver pointer lag, Linux physical-display provenance,
  application hotkeys and immediate-paste stress remain separate investigations.

## Paused investigation — Intel VA-API surface timeout

Read-only inspection of an Ubuntu Client running **1.2.01** found repeated
`VA-API surface was not ready within 100 ms (38)` errors during exact-format
HEVC 10-bit 4:4:4 hardware decoding. Matching kernel records confirm i915 video
engine hangs, decoder-context resets and fence timeouts. Hardware decoding
initialized again after reconnect. The failure mechanism is established;
the trigger is not. This does not establish a driver-only defect or a stream
format mismatch. Version **1.2.02** fixed idle-status warnings, not this
GPU failure path.

Status 38 is `VA_STATUS_ERROR_TIMEDOUT`. The Qt surface-retention path treats
any unsuccessful synchronization as fatal, and session cleanup occurred about
20 seconds after the reported error. The blocking call was not traced. Simply
increasing the surface timeout or restoring an unbounded wait is not a fix.

Packet loss remains a plausible trigger through frame gaps, IDR recovery or
bursts of recovered frames. Shutdown before/after-FEC percentages are rolling
ten-second peak snapshots, not whole-session totals or a precise record at the
hang. One earlier connection reported unrecovered FEC symbols; the latest did
not. Receive-queue drops may follow a stalled decoder. These counters do not
establish causal order or prove an extreme-loss burst immediately before a hang.
The native receiver delivers complete frames and requests IDR recovery after
sequence gaps; loss does not itself turn QUIC payloads into corrupted bytes.

The operator deferred further investigation. No product changes, deployments,
GPU traces or loss-injection tests were performed for this incident. Private
notes retain the machine inventory, bounded log snapshot and detailed timeline;
no remote collector remains active. When the operator resumes this work, use
an unoccupied test Client to correlate controlled Client-ingress burst loss,
frame gaps/IDRs, surface ownership and GPU events. Preserve the selected codec,
bit depth, chroma and range when evaluating bounded decoder recovery. Existing
mainline package provenance and acceptance limits remain unchanged.
