# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Keep machine inventory,
credentials and private captures outside Git. This file records current work;
older candidate provenance remains in Git history and the artifact catalog.

## Active — Native X11 performance and frame-path cleanup

Branch: `code-simplification`. All seven approved follow-up items are implemented
and pushed. Both affected hosted builds passed; the original RPM and DEB are
collected and checksum-verified. No build remains active. No merge, release or
package installation was performed. Installed session acceptance is next.

Current sources:

- Host candidate root `c4745cd`, version 1.3.09.
- Linux Host `acd7054d` (includes successful-only CUDA resource adoption).
- Ubuntu candidate root `0e0b1f2`, version 1.3.08.
- Client `7d628f604023697d0d35b55d549d0e89a95a832e`.
- Client common-C `9838bb82e2b018cf3d47f927fbf14226058ccc8b` (unchanged).
- Kymux `12af484eb307351b068aba96da12afce46f4614b` (unchanged).

Completed changes:

1. Batch XCB root/overlay geometry and checked SHM capture requests; validate and
   consume every reply/error on each frame, including after topology changes.
2. Register reusable native 10-bit SHM images for CUDA NVENC upload with a 256 MiB
   process cap and pageable fallback. Keep SHM mode 0600, registration until GPU
   completion, and unregistration before unmapping. Error exits drain the stream.
3. Separate capture, GPU upload/conversion, CPU submission/wait and encoding
   timing; retain 2048 samples per stage with lifetime aggregates.
4. Give x264 workers contiguous rows and a nonaliasing exact RGB10 unpack loop.
   GCC 14 vectorizes it; handwritten SIMD was tested and removed as unnecessary.
5. Delete the unreachable synchronous Host capture/encoding implementation.
6. Delete dormant X11 cursor blending, retaining separate cursor transport.
7. Cache Ubuntu EGL import entry points/capabilities per Qt/EGL context; retain
   existing image/frame/fence ownership and reset behavior.

No wire, authentication, input, Mac rendering or capture-profile change. Both
native X11 x264 and HEVC 10-bit 4:4:4 identity NVENC remain supported. NvFBC retains
its separate capture/encoding path. Private machine details stay outside Git.

| Product | Version | Run | Source | Status |
| --- | --- | --- | --- | --- |
| Linux Host | 1.3.09-code-simplification | `41397585486` | `c4745cd` | Passed; collected |
| Ubuntu Client | 1.3.08-code-simplification | `41396383942` | `0e0b1f2` | Passed; collected |
| macOS Host, prior unchanged build | 1.3.07-code-simplification | `41385319485` | `b13dbca` | Passed; signed/notarized, collected |
| macOS Client, prior unchanged build | 1.3.06-code-simplification | `41384156717` | `90cee00` | Passed; signed/notarized, collected |

Host run `41396380698` was deliberately canceled before packaging for the final
CUDA rollback/compiler-vectorization refinement. It is not an accepted package.
The successful Client source did not change, so its original package/version is
retained. Do not relabel it as 1.3.09 or infer a combined root snapshot.

Validation completed:

- Portable production-header tests verify all 1024 component levels, random
  packed/unaligned/tail cases, row coverage, bounded timing, XCB request ordering,
  resize/error replies, CUDA rollback and concurrent registration-budget use.
  ASan/UBSan pass with GCC 14, including failed calls modifying output parameters.
- The GPU upload fixture uses real mode 0600 SysV SHM and the production registration
  owner on RTX 6000 Ada/595.104.02. Every returned source bit matches. Repeated
  isolated comparisons show roughly 26–34% lower median upload time with pinned
  SHM at 4K/5K. This is not an end-to-end encoding or frame-rate result.
- A read-only live depth-30 Xorg fixture passed at 5120x2160. Its short concurrently
  loaded comparison showed no capture speed gain (25.446ms original versus
  26.326ms batched median). The dominant Xorg image readback remains. Neither
  GPU probe installed anything, saved screen pixels or changed a running session.
- GCC 14 CPU-only unpack comparisons show modest median improvement, principally
  from contiguous row partitions. Full results and limitations are in the plan.
- Ubuntu normal/sanitizer, decoder, compositor, EGL/1024-level precision, Wacom,
  PipeWire, launcher, package-upgrade and package gates passed. These hosted
  software-GPU checks do not qualify Intel VA-API or a live remote session.
- Linux Host native10 and package gates passed, including RPM ownership of
  `/var/log/plank` as root:root mode 0700. Input/crypto fixtures passed 25 shuffled
  repetitions; three 900-frame loss matrices had zero unrecovered frames.

Packages are in `artifacts/packages/candidates/<version>-code-simplification/`.
Original manifests, SHA-256 checks, recursive source pins, hosted logs and test
reports are retained under `artifacts/qualification/code-simplification-1.3.08/`
and the corresponding 1.3.09 directory. Both original manifests match the local
catalog, including source revisions, submodule pins and package hashes.
Task-specific download/build scratch was removed after preserving this evidence.

Installed acceptance remains: native X11 x264 and HEVC NVENC at 4K/5K, gradients
and real motion, topology changes, reconnect/teardown and a normal Client soak.
Check stage timings without attributing the isolated upload gain to total
capture/encode latency. Prior Mac candidates still need their existing live
gates. No build result substitutes for installed session acceptance.

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
