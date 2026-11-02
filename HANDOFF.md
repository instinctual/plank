# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Keep machine inventory,
credentials and private captures outside Git. This file records current work;
older candidate provenance remains in Git history and the artifact catalog.

## Active — Simplification complete; candidates ready

Branch: `code-simplification`. All eight follow-up changes are implemented and
pushed. No merge, release or installation was performed. The previous
scope and its candidates remain preserved; installed session acceptance is
still required.

Source revisions:

- Initial four-product snapshot: root `90cee00088be11c2e6f9b295b73e1d8e2ed6528d`.
- Final transport cleanup: root `b13dbca` (1.3.07 Mac Host rebuild).
- Client `b0b982db202410d6269d148280fe415f69b9fc79`.
- Client common-C `9838bb82e2b018cf3d47f927fbf14226058ccc8b`.
- Linux Host `0ac655da8d19bb8dff841f7f0e140cd078f7b6bc`.
- Kymux `12af484eb307351b068aba96da12afce46f4614b` (unchanged).

Completed changes:

1. Deleted the retired two-connection transport implementation and obsolete
   standalone probes. Native configuration/lifecycle coverage remains.
2. Replaced decoder polling with FFmpeg send/drain handling: retain the same
   packet across EAGAIN, attach metadata after acceptance, flush both codec and
   metadata on errors, and wake blocked input waits during cancellation.
3. Assembled the Host's video prefix and encoded payload once, then transfer
   ownership through the send queue without a second frame copy.
4. Bound send/receive video queues by both count and 64 MiB plus metadata;
   count every evicted frame. FEC and Quinn have separate bounded storage.
5. Compiled focused Linux Host input/crypto/logging tests instead of rebuilding
   the entire Host with coverage. Remove duplicate Qt header declarations and
   obsolete source-string requirements where behavioral gates remain.
6. Removed unsupported Client AV1 paths, Linux Host Apple startup and an unused KMS
   parser.
7. Replaced bookmark polling sleeps with a cancellation-aware timed wait.
8. Removed unused wide logging/deprecated codecvt initialization; verified actual
   UTF-8 logging under the C locale without that facet.

Native wire/ABI values, profile IDs, exact-format hardware qualification,
login-screen audio, input recovery and package security/ownership are unchanged.
Default and Mac-feature transport tests passed (61/63 tests respectively;
nine certificate/media fixtures excluded from ordinary cargo tests). Required
native loopback and loss runners passed hosted qualification. Clippy passes
with warnings denied for default and Mac-feature builds. Eight common-C and
eight repository/package contracts, 115 CI-policy cases, portable catalog and
decode controller fixtures, 1,000 lifecycle races and 2,039 frame assertions pass.

Ubuntu normal/ASan/UBSan suites passed actual pinned H.264/HEVC decoder tests,
polling cancellation, input/Wacom, compositor scaling/two-display, launcher,
package-upgrade, identity and dependency checks. Mac Client decoder, polling,
Qt/Metal and signed-package gates passed. Linux Host input and crypto/UTF-8
fixtures passed 25 shuffled repetitions; three 900-frame 150-Mbit/s loss matrices
spanning 0–5% injected loss had zero unrecovered frames. These are hosted tests,
not installed GPU, display, audio or tablet acceptance.

| Product | Version | Run | Source | Status |
| --- | --- | --- | --- | --- |
| Linux Host | 1.3.06-code-simplification | `41384148711` | `90cee00` | Passed; collected |
| Ubuntu Client | 1.3.06-code-simplification | `41384151783` | `90cee00` | Passed; collected |
| macOS Client | 1.3.06-code-simplification | `41384156717` | `90cee00` | Passed; signed/notarized, collected |
| macOS Host | 1.3.07-code-simplification | `41385319485` | `b13dbca` | Passed; signed/notarized, collected |

The earlier Mac Host 1.3.06 also passed run `41384154127` and remains preserved.
The 1.3.07 follow-up only removes an unused receive timestamp compiled with
sender-timing; the other three products do not enable that feature, so their
compiled paths are unchanged. Do not relabel or replace the earlier artifact.
Packages live in `artifacts/packages/candidates/<version>-code-simplification/`.
Original manifests, source pins, logs and regression evidence are retained in
`artifacts/qualification/code-simplification-1.3.06/`; the follow-up Host has its
own 1.3.07 evidence directory. Check each manifest for its exact source/hash.

All package checksums are verified. No hosted job remains active for this work.
Next: install candidates for the hardware/session gates below. No hosted result
substitutes for those tests. No live performance improvement is claimed from
copy/queue assertions alone.

## Preserved checkpoints

- Root `0a32513`, candidate `1.3.05-code-simplification`: all five original
  simplification items and four hosted builds passed. Includes shared profile
  catalog, owned encoded frames, consolidated Client lifecycle, Mac display
  transactions outside the runtime lock and unsupported Windows Host removal.
  Exact pins/results remain in the plan and original package manifests.
- Root `94aeeee`, candidate `1.3.04-host-cleanup`: all four builds passed after
  retired crypto/socket/DNS, packaging/rendering, unused Host backends and
  schema4–6 compatibility removal. See the cleanup inventory and prior plan.

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
