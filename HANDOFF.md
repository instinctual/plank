# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Keep machine inventory,
credentials and private captures outside Git. This file records current work;
older candidate provenance remains in Git history and the artifact catalog.

## Reliable-data pressure and reconnect recovery — installed Linux checks complete

Root and Client branch remain `client-bookmarks`; candidate **1.3.16-client-bookmarks**
includes all preceding fixes. A live 1.3.15 session ended when the bounded
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

Package source is root `6aa4f0d29c6585f2063c0fada2cd50a4b7a05d02`, Client
`b859e34318ba315ad5068e2e00aa50120d26fe92`, Linux Host
`2f2f207827a907fb6aaf2b8ac3833507389cd678` and Kymux
`12af484eb307351b068aba96da12afce46f4614b`. Hosted run `41590277670`
passed all four product compile/test jobs. Linux DEB/RPM packages are verified
in `artifacts/packages/candidates/1.3.16-client-bookmarks/linux/`; Mac jobs
were unsigned checks, not signed installer delivery. Build logs, original
manifests, recursive pins and Qt evidence are in
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
encrypted loopback test specifically exercises that path. Signed Mac 1.3.16
installers and installed Mac acceptance remain outstanding. No merge or release.

## Ready for installed testing — HEVC hardware selection and NVENC recovery

Root, Client and Linux Host branch: `client-bookmarks`; candidate
**1.3.15-client-bookmarks**. Client `412c0c2b`; Linux Host `2f2f2078`.
The preceding independent-bookmark and cleanup work remains included/unmerged.

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

Code and notes are committed/pushed on `client-bookmarks`; no merge, release or
installation. Next: manually install the exact Host and Client candidates on
the authorized test pair, confirm HEVC hardware decoding/live updates, then
test recovery. Check H.264 software decoding remains functional and a Client
without the selected HEVC hardware path receives the explicit error. Hosted
format-offer tests cannot qualify actual GPU surfaces or sustained playback.

Cache record: Ubuntu reused Rust/Cargo/compiler outputs and rebuilt the changed
FFmpeg library. Mac reused Rust/Cargo/Qt and rebuilt its shared native-dependency
prefix for the FFmpeg fixes. This branch had no Linux Host dependency cache;
the first Host build populated it. Do not repeat a dependency bootstrap merely
to update these final notes.

## Completed candidate — independent bookmarks for one Host

Branch: `client-bookmarks`, based on the complete `code-simplification` candidate
below. Client-only candidate version: **1.3.14-client-bookmarks**.

Resume on `client-bookmarks` in the root and Client repositories. Code and
candidate records are pushed; the next step is operator testing, not another
build. The preceding cleanup and this bookmark change remain unmerged to
`main`. Continue using this branch for any bookmark follow-up so its verified
dependency caches remain available.

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
changes, installations, merge or release are included in this task.

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
caches held only on `code-simplification`; `main` still has the older baseline.
The unnecessary cold builds finished and populated `client-bookmarks` caches.
The runbook now requires checking branch/default-branch cache visibility before
promising reuse. No cache-key relaxation, dependency change or unapproved merge
was used to hide this limitation. Future shared reuse requires the approved
baseline and caches on `main`, or a separately designed cross-branch store.

## Completed candidate — native-only cleanup/refactor

Branch: `code-simplification`. All ten approved follow-up items are implemented
and pushed. **1.3.13-code-simplification** has passed the four products' hosted
build/component/package gates. Both Mac PKGs are signed, notarized and stapled.
No merge, release, installation or installed-session acceptance was performed.

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
Host common-C headers `209604a`, Kymux `12af484e` (unchanged). Host headers use
`code-simplification-host-headers`; the maintained product/common-C changes use
`code-simplification`. The final Linux-only code/packaging corrections do not
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
The original package and qualification directories remain intact. Neither
checkpoint was merged, released, deployed or treated as hardware acceptance.

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
