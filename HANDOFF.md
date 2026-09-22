# PLANK handoff

## Current: RaptorQ 2 upgrade and application datagram pacer removal

The root, Client, Linux Host and Kymux repositories are now on
`raptorq-upgrade`, created from their complete `code-review-fixes` checkpoints,
not main. The root baseline is `91eba02d39c0923008a3f7c9595636aa2b891d09`.
The active worktree remains at `build/worktrees/code-review-fixes`; its directory
name is not its current branch. Do not switch or modify the unrelated primary
checkout as part of this work. The integration checkpoint
preserves the accepted Host identity work, virtual-primary candidate changes,
review fixes #2–7 and Client label cleanup. Dependency commits were created
first, with staged-content and commit-message privacy checks enabled:

- Client: `f1c2e781bf806439971e37ce59d9cd41e0cf589b` (render shutdown plus labels).
- Linux Host: `20ce61cc500a20b97a99fb79c2046e156d9f3dc3` (PAM isolation/deadlines).
- Kymux: `ca10966e9842a9b94aaca7dbc9a6ee050bf1a79c` (data/FEC validation).

The operator authorized committing, pushing and building matching candidates.
Version is **1.0.154-raptorq-upgrade**. Kymux implementation is committed at
`26be84d810b5b52d144705b52e592fb0eb6e8700`; Client candidate changelog is at
`4d23231f600d59e9b812acbb0e2cdc88a51bc473`. Linux Host remains at its checkpoint
above. Root integration follows `8f4475f55e04e487b7c52d37e55461bc2aacb775`.
Retain `code-review-fixes` in all four repositories as the pre-upgrade rollback
reference. Build on GitHub-hosted workers with verified dependency caches,
not hardware targets. No main merge, installation or release publication is
authorized. Existing 1.0.153 artifacts predate review fixes #2–7 and this upgrade.

RaptorQ is pinned to **2.0.1** in KyProto and both product/probe lockfiles;
no other runtime dependency version changes. Receive validation accepts RFC
repair IDs starting at K, retaining the earlier malformed-input/allocation
bounds. A standalone old/new compatibility probe demonstrated incorrect
reconstructed bytes in both mixed-version directions. Native TLS now offers
only **`plank-native/2`**, rejecting mismatches before authentication/setup/media
without an additional round trip or legacy decoder. Actual TLS tests cover
both directions, setup/direct entry points and unknown/missing ALPN.
See `docs/development/reviews/raptorq-2-qualification.md` for the wire contract.

At the operator's request, the application datagram pacer is **deleted**, not
disabled: no optional pacer, reservation timer, platform fast-send feature,
paced-baseline build or pacer/sleep trace columns remain. Quinn still schedules
packets. All Host builds retain the existing **1 Gbps controller-budget floor**,
RTT/window bounds, encoder target, FEC policy, MTU and queue limits. The Client's
default Quinn controller is unchanged. Linux Host selects `quinn-telemetry`;
Linux qualification of the Mac source-first algorithm selects
`quinn-telemetry,macos-source-first`. Historical flags in older results below
must not be reused. The runbooks and trace analyzer reflect the removal.

Current local validation uses pinned Rust 1.89.0, offline/locked inputs and
optimized builds on the Linux Host builder. Both selections pass product,
KyProto and Kynet unit tests, production-library Clippy with warnings denied,
encrypted typed all-lane round trips, both C ABI trust modes, reliable-data
overflow and cancellation checks. New fixed repair-byte vectors, small-object
repair-only recovery and existing multi-block/sub-block tests pass. Source-first
traces parse without the deleted columns; 8 build-policy and 3 analyzer tests
pass. Linux has 51 product unit, 34 KyProto and 6 Kynet tests; source-first has
53 product unit, 35 KyProto and 6 Kynet tests. Both also pass 4 telemetry and
6 reliable-data parser tests; the five ignored integration tests run explicitly
through the loopback runner.

Final controlled-loss sequences: **three consecutive runs per sender** at
150 Mbps / 60 fps and 0/0.5/1/3/5% injected datagram loss, **5400 frames total,
zero unrecovered objects and zero proxy kernel drops**. Per-phase p95 delivery
is 5.728–8.411 ms for Linux and 6.385–13.063 ms for source-first. These are
local transport tests, not hardware playback or a WAN soak. Validation evidence
is in the builder work root's `raptorq-upgrade-validation/` directory; final
logs use `no-pacer-` filenames. The Linux repeat is
`no-pacer-linux-loopback-repeat.log`; the original failed sequence remains
`no-pacer-linux-loopback.log`.
Default-feature Client transport tests and the standalone probe's locked,
offline compilation also pass. Without telemetry selected, the vendored Quinn
crate still emits its two pre-existing unused-telemetry warnings; these were
not introduced or suppressed by this change.

The first post-removal Linux matrix sequence passed two runs, then lost a frame
in run three while the test proxy recorded **76 unintended kernel drops**.
That failure is retained, not converted into a pass; a complete repeat uses
unchanged limits and no system tuning. An earlier source-first diagnostic
accidentally selected the old paced baseline on Linux and missed its 100 ms
submission deadline. This obsolete selection is now impossible. Earlier runs
with incidental proxy drops are retained separately from controlled-loss runs.

Next: verify dependency-first pushes and build all four matching candidates.
The operator approved temporary exact-branch signing permission for these
Mac candidates. Remove only that temporary policy
after signing. Collect checksum/provenance-verified packages under
`artifacts/packages/candidates/1.0.154-raptorq-upgrade/` in the canonical checkout.
Do not mix pre-upgrade packages or relabel them. Native macOS compilation,
hardware playback/input/WAN acceptance and the Client label-only Qt test remain
pending; Linux feature-selection tests are not Apple hardware qualification.

The first hosted attempts (`35790399772` / `35790403469`) stopped in policy,
before compilation: a new source guard incorrectly required Kymux in the
root-only checkout. Its dependency checks now run after bootstrap for all four
products, while root policy verifies the wiring. No transport check is waived.

## Client label cleanup

Removed the macOS Experimental qualifier from the shared Add/Edit capture
selector (`ScreenCaptureKit — macOS`) and on-screen capture-source stats
(`ScreenCaptureKit`). Native X11/XShm keeps its existing Experimental label;
capture/profile selection and streaming behavior are unchanged. The existing
HostChoices Qt test now checks both labels. Source/diff checks pass; Qt runtime
tests and a new package build remain pending. This change is included in the
Client checkpoint above alongside the earlier review fixes.

## Checkpointed: cancellation across transport establishment

Review fix #7 is implemented in the root `code-review-fixes` worktree,
preserving pending fixes #2–6. One durable cancellation boundary now covers
listener accept, TLS, KyProto authentication/endpoint negotiation, certificate
approval, setup, promotion and streaming. The previous lane-local notification
branches are removed. Registration precedes checking the stop/failure predicate,
so a stop cannot be missed between phases or confused with a spurious wake.
Stopping/terminal state cannot be revived by a concurrently completing setup;
recorded failures retain their diagnosis. Start/stop serialize worker-handle
publication and joining. Host close/drain stays outside cancellation and still
has its one-second upper bound, including on handshake failure. Wire format,
ABI, authentication and rate policy are unchanged.

Five focused regression tests pass, including actual silent QUIC handshakes,
destroy during startup and 32 concurrent start/stop races. A real encrypted
loopback test additionally withholds auth/endpoint readiness on either peer,
certificate approval and promotion. With 30-second handshake deadlines, Client
stops took approximately 0.4–1.1 ms and connected Host stops approximately
80–83 ms, including close delivery. Listener socket release is checked. This
integration test is now part of the native loopback/package gate. The five
focused tests also pass with macOS-source-first selected on Linux; no native
macOS build/hardware validation is claimed.

The shipping Linux feature selection passes 52 product unit tests, 4 telemetry
tests, 6 parser tests, 25 dependency media tests, production-library Clippy with
warnings denied, the typed all-lane round trip, reliable-data flood and both C
ABI trust-mode loopbacks. The first three 150 Mbps / 60 fps loss matrices all
passed performance/recovery checks (2700 frames, zero unrecovered objects);
the third also recorded 16 proxy kernel drops, so it is not a controlled-loss-
only sample. A separate complete three-matrix repeat passed with zero proxy
kernel drops and zero unrecovered objects across all 2700 frames at
0/0.5/1/3/5% injected loss, with 6.049–8.382 ms per-phase p95 delivery.
The initial proxy-drop result is retained rather than hidden by the repeat.
Formatting, shell syntax and diff checks pass; the lockfile is unchanged.

This fix is included in the checkpoint above. Existing 1.0.153 artifacts
contain none of fixes #2–7. Use a new candidate version when packaging is
requested; no new package, deployment or merge has been performed.

PR status rechecked: root #10, Client #6 and Linux Host #9 remain open drafts.
They were integrated into the 1.0.152 candidate, not merged into their respective
`main` branches. GitHub comparison confirms their current heads are ahead of
main; do not close them as already merged. No PR state was changed.

## Checkpointed: malformed FEC receive hardening

Review fix #6 is implemented in the same root/Kymux `code-review-fixes`
worktrees, preserving all other fixes below. The active audio FEC receiver
had the same defect as video; both now share `kyproto/.../av/fec.rs` validation.
It rejects truncated headers, invalid/oversized RaptorQ partitions, wrong
symbol lengths/IDs, changing object/group metadata and invalid reconstructed
media headers before unsafe parsing/decoder operations. Pending object,
group, byte-reservation and distinct-symbol bounds prevent unbounded decoder
state. Companion reliable config records have a pre-allocation size/type check.
Errors now reach the receive caller and cancel companion readers instead of
panicking or leaving a half-alive endpoint. No panic-catching workaround,
wire/ABI/feature change, FEC repair-policy or sender-pacing change.
Bounds and their distinction from total RSS are documented in the transport
README; the maximum video envelope includes PLANK's 16-byte frame metadata.

Validation uses pinned Rust 1.89.0 and the unchanged product lockfile/offline
cache on the Linux Host builder. Nineteen new regression tests plus six existing
media tests pass. They cover malformed headers/OTIs, consistency, deduplication,
multi-block/sub-block repair, budget admission/release, forged media headers,
parser errors and task cancellation. These dependency tests are now explicitly
run by the native loopback/package gate, not silently omitted by product tests.
Product tests also pass (47 unit + 4 telemetry + 6 reliable-data parser).
Production-library Clippy with warnings denied passes. All three required
150 Mbps / 60 fps matrices pass at 0/0.5/1/3/5% loss: 2700 frames, zero
unrecovered objects, zero proxy kernel drops; per-phase p95 delivery
5.711–8.138 ms. Typed encrypted round trip, reliable-data flood and both C ABI
trust-mode loopbacks pass, including queued control before peer close.
The macOS-source-first feature selection also passes 26 media tests compiled
on Linux (including the existing source-first test); this is not native macOS
hardware or package qualification.

Included in the Kymux/root checkpoint above. The 1.0.153 artifacts still contain
none of fixes #2–6. Use a new candidate version when packaging is requested.

## Checkpointed: atomic media/input receive claims

The requested video/audio overflow race is fixed in the root
`code-review-fixes` worktree, preserving all earlier fixes below.
`native_ffi.rs` now validates destination capacity and moves the exact front
item out under the queue mutex, before copying its bytes/metadata outside the
lock. Video/audio overflow can only evict unclaimed items; there is no second
dequeue after copying. Input had the same split peek/remove pattern and now
shares the claim helper, preventing duplication/skips with overlapping readers.
The internal packet structs no longer implement Clone. Short/invalid output
buffers leave items queued; zero-byte audio holes and failure/timeout drain
behavior are preserved. Reliable-data's previous atomic copy/accounting remains
unchanged. No queue-limit, wire/ABI, FEC, rate-policy or feature-bit change.

Seven new tests exercise the actual C receive functions, including forced
overflow at the unlocked copy boundary, nested and concurrent readers, exact
drop counts, payload/metadata pairing, output canaries, buffer errors and audio
holes. The one-shot interleaving hook is test-only/thread-local. The existing
Host transport package gate runs these tests automatically. Contracts are in
`protocol/plank-transport/README.md` and the public C header.

Validation on the Linux Host builder uses pinned Rust 1.89.0, the unchanged
lockfile and retained offline cache. The shipping Linux transport feature set
`quinn-telemetry,linux-fast-send` passes 47 unit + 4 telemetry + 6 parser tests
and production-library Clippy with warnings denied. Both real encrypted C ABI
trust-mode loopbacks pass, including setup/promotion, video/audio/input/data,
queued-control preservation and peer close. All three required 150 Mbps/60 fps
loss matrices pass at 0/0.5/1/3/5% loss: 2700 frames, zero unrecovered objects
and zero proxy kernel drops, with per-phase p95 delivery 5.810–10.226 ms.
The seven focused receive tests also pass with default features and with
`quinn-telemetry,macos-source-first` compiled on Linux, exercising conditional
sender-timing fields. Native macOS compilation was not performed. These are
local transport tests, not hardware playback or a WAN soak. Formatting and
diff checks pass.
Included in the root checkpoint above. The existing 1.0.153 artifacts do not
contain this fix. A newly versioned build remains a separate package step.

## Checkpointed: Client render shutdown synchronization

The next requested review fix is implemented in the same root/Client
`code-review-fixes` worktree, based on Client
`4e98452559d1c679fcce607dbde3e5b0f2e8c035`, now committed in the checkpoint above.
No package, install, push or merge was performed for this fix; existing 1.0.153
artifacts do not include it.

Pacer shutdown now publishes its stop predicate and wakes all three conditions
under the frame-queue mutex, then releases that mutex before joining workers.
The predicate is also atomic for existing render/V-sync loop checks outside
the mutex; atomic alone is deliberately not the lost-wakeup solution. V-sync
checks shutdown before entering its waits, and rechecks queue emptiness after
a wake. Thread-affine renderer cleanup and queued AVFrame disposal are retained.
An adjacent SDL3 64-bit tick / `%u` logging mismatch was corrected so the actual
Pacer translation unit passes warnings-as-errors. No pacing policy, transport,
Host, decoder selection or GPU presentation behavior changes are intended.

The new Client `tests/pacershutdown` compiles the actual Pacer with controlled
GPU callbacks and a fixed test display-refresh query. Both Linux and macOS
package builders now invoke it. On the qualified Ubuntu Client builder, nine
scenarios (11 QtTest results including setup/cleanup) pass, including 300 idle
render-thread lifetimes, 100 asynchronous V-sync lifetimes, all three forced
check/wait boundaries, active-render stop and queued-buffer cleanup. GCC 15,
Qt 6.10.2, SDL 3.4.2 and retained FFmpeg 9.0.1 were used, without installing a
Client or changing any live session. AddressSanitizer/UndefinedBehaviorSanitizer
pass. A negative-control build retaining the atomic flag but removing the
shutdown mutex fails all three boundary cases as expected; fixed source was
restored and hash-verified afterward. The full fixed suite also passed twenty
consecutive runs. Client source-gate tests and shell syntax checks pass.

ThreadSanitizer is not a pass: installed Qt has inline mutex TSan annotations
but its prebuilt wait-condition implementation is uninstrumented. A standalone
Qt mutex/condition program with no PLANK code reproduces the same double-lock
report. No suppression or production workaround was added. Native macOS
compilation and real GPU/session shutdown acceptance remain untested; this
fix addresses queue synchronization, not an independently hung GPU driver call.
The isolated source/test builds live under the Client builder's
`$PLANK_WORK_ROOT/code-review-render-shutdown`, seeded from the exact retained
Client Git commit plus the reviewed dirty files, with pinned common-C headers
`060f6179f88343327b44d915007f1fb4cede71f1`. Do not use the builder's historical
primary checkout as current source. The root checkpoint now pins the committed
Client implementation; assign a new candidate version before packaging.

## Checkpointed: Linux PAM isolation, deadlines and cancellation

The operator requested the shared-authentication-mutex/PAM-stall review fix.
Work remains in root and Linux Host `code-review-fixes` worktrees, based on
root `74ff47e` and Host `ebf63ac9347e461a1eaff5adc83a77724187002a`.
Changes are now included in the Host/root checkpoint above alongside the
reliable-data changes. No merge, package build or installation was requested.

PAM operations now run outside the manager state mutex and outside the HTTPS
event loop. A four-worker executor counts running and queued requests together,
with no additional backlog; a small in-process monitor cancels requests on
TCP disconnect without consuming TLS data. The Client's existing five-second
HTTP abort therefore cancels abandoned work. Each PAM operation also has a
30-second absolute deadline across delegation, writes and framed reads.
Descriptor delegation retains its three-second cap and drains already-issued
replies on cancellation rather than contaminating the next request.

In-flight entries remain counted against the 32-entry manager limit even when
revoked. Duplicate responses and late success after cancellation/expiry fail
closed. Cancellation and object destruction happen outside the state lock.
The broker parent watches caller EOF, allows two seconds of normal PAM cleanup,
then kills a stuck child; shutdown no longer waits indefinitely in waitpid.
Healthy authenticated session lifetimes, peer binding, account policy and
claimed-stream ownership are preserved. No new daemon, privilege, config key,
wire version, Client change or macOS authentication change.

The product HTTPS server class moved from `nvhttp.cpp` into `nvhttp.h` so its
actual TLS implementation and disconnect lookup are exercised by the isolated
test, not a substitute server. See `protocol/authentication.md` for contracts.
The new `tests/session/pam` CMake gate is invoked by the Host package-binary
builder even though the shipped payload remains `BUILD_TESTS=OFF`. It uses
the Host-pinned GoogleTest `52eb8108`, Simple-Web-Server `546895a` and retained
Boost 1.89.0. These dependencies were seeded at their exact pins from local Git.

Validation on the Linux Host builder: GCC 14 C++23 with warnings treated as
errors compiles the actual manager, PAM client, broker and HTTPS implementation.
All 29 focused unit tests, the real TLS status/abort test and unprivileged Unix
delegation/framing checks pass. AddressSanitizer + UndefinedBehaviorSanitizer
pass all three CTest targets, including TLS. ThreadSanitizer could not link
because this builder lacks its runtime; do not claim a TSan pass. The optional
root-to-unprivileged delegation test reports a skip without root privileges.
No real PAM/SSSD account, live login/logout, or hardware acceptance was exercised.
The final non-sanitized three-target suite also passed ten consecutive runs.
The older standalone `test-host-supervisor-package.sh` stops at its pre-existing
two-argument `layout_arguments(request.mode_1, request.mode_2)` source grep;
the pinned virtual-primary Host already changed that call before this work.
That unrelated stale assertion was not changed and is not an authentication
test pass. Full product/package compilation remains a separate gate.

To repeat locally, use `cmake -S tests/session/pam` with a
`cmake-build-*` binary directory, the qualified GCC 14 compiler and
`-DPLANK_BOOST_SOURCE_DIR="$PLANK_BOOST_SOURCE_DIR"`, then build and run CTest.
The HTTPS fixture creates and removes a private ephemeral test certificate;
no deployed key or credentials are used. Host and Kymux changes are now committed
before their parent gitlinks; assign a new candidate version before packaging.
The existing 1.0.153 packages contain neither of these additional security fixes.

## Checkpointed: reliable-data allocation bounds

The operator accepted the automatic Host identity-trust behavior below and
requested the next code-review fix: oversized incoming reliable-data lengths.
Work remains on `code-review-fixes` in the same root worktree. No merge,
deployment or new candidate package is part of this change.

The Kymux worktree is now initialized at `third_party/kyber-kymux`, on its own
`code-review-fixes` branch based on the pinned `158719b6`. Its parser/writer
share a 1 MiB payload cap, checked before payload allocation; partial headers
are errors rather than clean EOF. Root imports that cap and bounds reliable
send/receive queues to 8 MiB AND 64 records each, in setup and active sessions.
Send overflow remains retryable; receive overflow fails explicitly. C ABI
receive retains the byte charge on short buffers and copies/removes under one
queue lock. No media/FEC, clipboard-limit, input or wire-format change.

Changes are committed in root and Kymux as part of the checkpoint above.
Existing 1.0.153 artifacts do NOT contain this additional fix: assign
a new candidate version before producing packages; never overwrite/relabel them.
See `protocol/plank-transport/README.md` for the memory budget and tests.

Validation uses pinned Rust 1.89.0 and the unchanged product lockfile on the
Linux Host builder. The retained cache needed its already-pinned Rustls 0.23.45
downloaded; dependencies were not upgraded. Release unit/integration tests pass
(40 + 4 telemetry + 6 parser); the three explicitly ignored network tests run
through the native loopback script. Encrypted data flooding verifies bounded
failure in both directions; the C ABI loopback verifies setup/promotion,
media/input/control, short-lived peer closure and queued-control preservation.
The final-source optimized loopback run passed all three 150 Mbps / 60 fps
loss matrices at 0/0.5/1/3/5% loss (2700 frames total), zero unrecovered objects
and zero proxy kernel drops; per-phase p95 delivery was 5.673–7.617 ms. This
is local transport qualification, not an Internet or hardware-video soak.
Production-library Clippy with warnings denied passes. All-target Clippy still
reports two pre-existing test-style findings (`collapsible_if` in `native.rs`,
`items_after_test_module` for `completion_tests`); allowing only those in the
diagnostic command yields a pass. No source-level lint suppression was added.
Native macOS compilation and live device acceptance are not claimed here.

## Accepted: automatic Host identity trust

Work is isolated in `build/worktrees/code-review-fixes`, root and Client branches
`code-review-fixes`, based on root `9c9d6bd` and Client `6580f794` below. It retains
the pending virtual-primary fixes; main and the unrelated primary checkout are
unchanged. No merge or release is authorized. The operator subsequently approved
temporary feature-branch signing and installing matching candidates on the
dedicated development Mac and Development NUC for live login/logout validation.

The operator approved automatic first-use trust before credentials and an
explicit Cancel / Trust Replacement Host dialog on identity changes. Trust is
separate from bookmarks; deletion/recreation is not a reset. The operator also
approved a stable machine authority across macOS login/logout and user changes,
using the existing authenticated coordinator without sharing its private key.
See `docs/development/plans/host-identity-trust.plan` and
`docs/security/host-identity-trust.md` for the residual TOFU risk and design.

Implementation and automated build gates pass; the operator subsequently
reported that the behavior works. The automated deployment evidence and
untested individual scenarios are retained separately below.
Root implementation through `984b80c3147cf498574ff97543863d5d20907246` and Client
`4e98452559d1c679fcce607dbde3e5b0f2e8c035` are pushed. Candidate version is
`1.0.153-code-review-fixes`. Linux Host remains
`ebf63ac9347e461a1eaff5adc83a77724187002a`; kymux remains
`158719b67f83e3d83e8bfba1588420ed84a65cab`; Client common-C remains
`060f6179f88343327b44d915007f1fb4cede71f1`.

Hosted validation:

- Linux Host and Client passed in run `35698729084`, root
  `b9a99c3418051f26918f21baf1fa1d60353ca341`. Subsequent source changes affect
  only Mac diagnostics/test setup and documentation, not these Linux payloads.
- macOS Host passed in run `35701450093`, root `984b80c`: package filesystem
  checks (65), signed XPC checks (262), actual system-crypto certificate issuance
  for distinct worker keys, and actual Network.framework TLS chain emission
  (worker leaf followed by machine authority), including authenticated HTTP.
- macOS Client passed in run `35701452179`, root `984b80c`. Both Client platforms
  pass trust-store (9), real TLS guard (5) and responsive consent UI (11) tests.
  TLS tests prove ordinary worker-key changes retain identity and rejected
  replacements receive no HTTP credential bytes.
- Real NvHTTP launch/authentication integration passed all 19 scenarios in the
  Linux Client build: first use, known/unknown recovery, replacement decisions,
  mid-password-conversation key changes, redirects and malformed launch replies.
- Linux certificate renewal, reconnect checks (14), portable package-script
  checks (23), CI policy checks (60) and version checks pass.

Mac test setup must retain these resolved details: existing-key LibreSSL
requests require `-new`; the XPC fixture must not retain itself; private test
directories require POSIX `realpath` (Foundation can retain the `/var` alias);
bare Qt TLS tests need the pinned dependency `DYLD_LIBRARY_PATH`, whereas the
packaged application finds its OpenSSL libraries in its bundle. None of these
are reasons to relax TLS 1.3, private-directory checks or identity validation.

Verified Linux artifacts are collected in the canonical checkout under
`artifacts/packages/candidates/1.0.153-code-review-fixes/linux/`, with original
source SHA, hashes and gitlinks in the catalog manifest:

- `plank-client_1.0.153-code-review-fixes_amd64.deb` — SHA-256
  `7cd9e9219795b10d7376ade72ade60846595a901a26ceb7d5e63c252b845a6b1`.
- `plank-host-1.0.153-0.code_review_fixes.1.el9.x86_64.rpm` — SHA-256
  `81002e04f6d26c0b9ba2e8450f3f65ea389ad99ca4fdb4692bc50cf1027ec39a`.

Authorized signed Host/Client runs `35702904682` / `35702907819` passed at root
`bd281914201929d9ce93a0388460269b25d2e064` (documentation-only successor).
Both passed Developer ID signing, notarization, stapling, Gatekeeper, package
checks and temporary-keychain cleanup. The temporary feature-branch signing
policy was removed afterward; the protected environment again permits only main.
Signed artifacts are collected alongside Linux in the candidate catalog's
`macos/` directory; all four final catalog checksums pass:

- `plank-host_1.0.153-code-review-fixes_arm64.pkg` — SHA-256
  `4aa8aaee245a0f01ed425061ae99e62125b230cbb6aebf643d91feb68efa5ff8`.
- `plank-client_1.0.153-code-review-fixes_arm64.dmg` — SHA-256
  `049f4d845717fa52d5ba7ea68e90c55859c8f9fb931ab3cc4a55e9c79ae45fe6`.

The exact Host PKG is installed on the authorized development Mac. Installer,
installed signature/version and byte-for-byte payload hash checks pass; executable
SHA-256 is `a4c38ab81924d0845b93dffa84da96140b08bc3efa2e4d63387e42f96dcf3e65`.
The machine key survived the upgrade unchanged. The actual desktop worker
automatically obtained its machine-signed certificate, retained a separate key,
and cannot read the root machine key. A bounded TLS 1.3 HTTP check validated
that chain and the installed version. Non-prompting checks in the console Aqua
session pass for screen/input/Accessibility before and after upgrade; audio
consent is not tested. Machine/desktop roles are running without startup errors.
Temporary diagnostic jobs/files and the privileged SSH session were removed.

The Development NUC remains unreachable at its recorded endpoint. The operator
has been asked to confirm power/address; no Client package was installed and no
other target was substituted. The operator subsequently accepted the behavior;
we did not independently perform the remaining login/logout, cross-user handoff,
media/input or replacement-dialog matrix. Do not mistake successful Host
installation for an automated pass of those individual scenarios. No
merge or release occurred. Machine-specific evidence is in the private notes.

The previous candidate and package provenance below remain valid and untouched.

## Previous candidate: virtual-primary PR repairs

The operator authorized fixing two Client findings in the coordinated Client
#6 / Linux Host #9 / root #10 series. Work uses branch `virtual-primary-fixes`
in `build/worktrees/virtual-primary-fixes` and its Client worktree. The fixes
are pushed to the author's editable `codex/virtual-primary-order` PR branches.
Main remains unchanged. Do not merge, install or publish without approval.
The operator subsequently authorized building/signing and downloading all four
test packages. The reviewed snapshot is also pushed to the maintainer-owned
`virtual-primary-fixes` branch for protected hosted signing.

Root PR base: `db868b4a8930397628c3fb10949c61c1c9ad6a2d`.
Client repair: `6580f794141b2073eae1110136d8665605eb3803`.
Root integration: `c38d5ea6952d8422f1334d5a671846a476b5c916`.
The root branch is refreshed with main's completed build notes at
`652718632be33b355df5e1fce989018c9df49f3a`; only HANDOFF conflicted.
Candidate version is 1.0.152, with the actual CI branch qualifier retained.

- Removed the Host-sized presentation-canvas override and its unused helper.
  Primary connector ordering retains the established aspect-preserving
  renderer and corresponding mouse/pen/cursor geometry.
- Bound the optional primary hint to the requested output count and an
  unambiguous horizontal layout. Manual bookmarks omit an unmappable hint
  instead of sending index 2 or rejecting an otherwise valid connection.
- Unit coverage includes 0–4 displays, every primary position, reversed
  enumeration, negative origins, ambiguous layouts, differing Host/Client
  aspect ratios and Retina logical input/cursor round trips.
- Linux Host code is unchanged from the reviewed Host #9. No transport,
  capture/encoding, physical-monitor policy or Wacom-focus change was added.

Local CI policy checks pass (60), version-contract and diff checks pass.
PR run 35677116506 passed all four products. Both Client platforms passed 25
OutputTopology tests; macOS passed 27 PlankPresentation tests. Linux compiles
the shared presentation code but its suite list does not run that test.
No new hardware acceptance is claimed. See `docs/development/virtual-primary-order-review.md`,
`protocol/output-topology.md` and `docs/releases/1.0.152.md`.

## Test package collection

All candidate builds use exact root
`0617daa52d4a136fb35cc9f12c5f446e722d39a3` and effective version
`1.0.152-virtual-primary-fixes`. Collect under
`artifacts/packages/candidates/1.0.152-virtual-primary-fixes/`; do not relabel
the earlier PR-merge artifacts with the new branch name.

- Linux Host/Client: run 35686244053, both passed and collected.
- Signed macOS Host: run 35686244115, passed and collected.
- Signed macOS Client: run 35686246368, passed and collected.

Both Mac jobs passed Developer ID signing, notarization, stapling, Gatekeeper,
package gates and temporary-keychain cleanup on disposable hosted runners.
The temporary exact-branch signing permission was removed after both passed;
the protected signing environment again permits only `main`.
No candidate was installed or published, and no live macOS acceptance is implied.

Downloaded packages are checked against each builder's recorded SHA-256 and
source/gitlink provenance before the normal local collector is run. All four
packages passed the final local checksum check and share the same source commit.
The catalog manifest and sidecars retain full hashes. Package SHA-256 values:

- Ubuntu Client: `fb55dd5f57f6e6dd495d47a4b0bae579ed5e4ebc65e324a6173ff42425130c42`.
- Linux Host: `af2aa85e379c31f02d9aa667ca03ed03063751a8a33a17df4bca248273e66d6b`.
- macOS Host: `9a57afe3678c9182c3a7be7f821e05554dae119e12167b4cd9df061918e04372`.
- macOS Client: `153931f564be1e600f2982b0dc31781aa185690382ee735e09407d52a747739b`.

The Linux Host passed all three selected-policy loss matrices at 150 Mbps,
60 fps and 0/0.5/1/3/5% controlled loss, with 6.545–8.088 ms p95 delivery.
RPM log-directory/manifest gates and the post-package input suites passed.
These are automated builder checks, not WAN or live tablet qualification.
The RPM retains the production BUILD_TESTS=OFF payload.
Package-collection tests (6), version-contract checks and diff checks passed.

## Other open PRs

All four cnoellert PRs were rechecked; no new PR or unreviewed revision appeared.
Client #7 at `af659dbca03304897dc693dc323a419134de6147` remains a separate
Wacom-focus proposal. No blocking code defect was found; native fullscreen
Spaces, focus release into local dialogs, reconnect and pressure still need
live macOS 27 qualification. It is not included in this candidate.
Linux Host #9 remains at `ebf63ac9347e461a1eaff5adc83a77724187002a`.
Client #6 and root #10 contain the authorized repairs and remain drafts.

The latest pre-repair root rebase passed all four hosted jobs in run
35675419841. Earlier paced-baseline and skipped-frame failures remain
historical evidence, not erased by later passes. Main now tests only the
selected shipping transport policy, as explicitly authorized by the operator.
Do not relax its three loss matrices or other shipping gates.

## Mainline packages and provenance

All four 1.0.151 packages passed and are collected/checksum-verified under
`artifacts/packages/releases/1.0.151/`. Nothing was installed or published.
The latest published release remains 1.0.143.

- Ubuntu Client: run 35672399443.
- Signed Mac Host: run 35672399113.
- Signed Mac Client: run 35672399343.
- Linux Host: run 35674515126.

The first three use root `c14704801ffa8c5166961c03db8f4bf6c57b08d5`;
the RPM uses `aa885d0f5b86f4e9101cff97d22c2caa9aeab66c`, which only changes
Host gate selection and its tests/docs. Exact hashes and submodule provenance
remain in each catalog manifest and main's HANDOFF at `6527186`.
Never replace or relabel those packages with this candidate.

The candidate's maintained inputs are Client `6580f794`, Linux Host
`ebf63ac9`, Kymux `158719b6`; nested dependency pins are unchanged.
Use GitHub-hosted builders, verified dependency caches and the release runbook.
Preserve the unrelated RK3576 plan, dirty HANDOFF and diagnostics in the
primary checkout. Private deployment notes stay outside Git.

## Remaining acceptance

Validate connector-primary behavior and image/input mapping with mixed
resolutions, Native and Scaled-Span, one/two local monitors and a manual
two-output bookmark on a three-monitor client. Confirm reconnect, fullscreen
transitions, mouse, pen and cursor behavior. macOS 27 live acceptance remains
outstanding; earlier macOS 15 trials are not exact-source qualification.

Mainline takeover/handoff acceptance, Wallpaper/Screen Saver hover lag and the
Linux physical-display provenance issue remain documented at main `6527186`.
This repair does not expand into those tasks or the separate Wacom-focus PR.
