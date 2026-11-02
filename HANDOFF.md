# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Keep machine inventory,
credentials and private captures outside Git. This file records current work;
older candidate provenance remains in Git history and the artifact catalog.

## Active — legacy input, encoding and decoder cleanup

Branch: `code-simplification`. The operator approved the complete ten-item
follow-up as one refactor. Implementation is complete; hosted validation of
candidate **1.3.13-code-simplification** is running. No merge, release or installation
is authorized by this cleanup. No installed session acceptance is claimed.

The previous checkpoint is root `c886880`, Host `acd7054d`, Client `7d628f60`,
Client common-C `9838bb82` and Kymux `12af484e`. Client and Mac Host candidate
source is root `bc959b800ff2351db29eba95ba9a4c59c19fd167`, Client `8a989271`,
Client common-C `0aa126f`, Host headers `209604a`. The Linux Host advances to
the final native-only Host commit to remove dependencies on the deleted GL
header's imports and shader assets; its final root/build provenance follows below.
The other three products' source/build inputs are unchanged by that correction.
All are pushed. Kymux itself is unchanged. Host headers use the dedicated
`code-simplification-host-headers` branch; the other changes use
`code-simplification` in their respective repositories.

Completed implementation:

- Client input queues own final native payloads; the Host parses/injects native
  values directly. Removed the GameStream packet reconstruction, second Host
  queue/dispatcher, relative-pointer APIs, controller/haptic APIs and generic
  touchscreen forwarding. Raw-HID Wacom, normalized pen, absolute mouse,
  scroll, keyboard, ordering, bounded backpressure and persistent tablets stay.
- Removed the unused recorder callbacks and Client startup relative-mouse wiggle.
- Removed unselectable KMS capture, its GL/EGL conversion code and GLAD build
  input. Removed its orphaned shaders, runtime asset copier, retired installer
  assets and localization tooling. DRM discovery and standalone KMS probes stay.
- Simplified Linux encoding to the active x264 and direct NVENC paths; removed
  generic FFmpeg hardware-frame encoding, unused options/fallbacks and AV1
  probing. NvFBC and Native X11 still support their exact selected profiles.
- Removed dormant HDR metadata/callbacks; ten-bit SDR and RGB identity stay.
  Event type 1 and feature bit 0x02 remain reserved rather than reassigned.
- Reduced the Client renderer/decoder interface to current Qt backends and
  mandatory exact-profile startup testing. Removed old platform decoder tables,
  H.264 SPS rewriting and the h264bitstream source dependency. Owned IDRs now
  retain the original encoded buffer, like ordinary frames.
- Cached the Ubuntu planar-conversion shader description by format, geometry,
  plane mapping/stride orientation and range; each frame still validates its
  metadata and binds the current textures. No new GPU wait or CPU readback.

Validation so far: common-C 8/8 tests (expanded native wire/tool transitions,
backpressure, input bounds, queue ownership, audio timestamps), also passing
ASan/UBSan with GCC14; 261 optional
service checks; 115 CI policy tests; 7 Host header-only packaging tests; no-SDL
source gate. Added real H.264 decoder/ownership fixtures, Host native input
boundary tests and GPU cache invalidation tests for the hosted builders.

The prior Native X11/upload work remains included. Its standalone pinned-SHM
upload comparison improved median upload time by roughly 26–34%; the live
Xorg readback comparison did not show a capture speedup. Do not turn that
isolated upload measurement into an end-to-end performance claim. Earlier
packages and evidence remain in their versioned catalogs.

The initial hosted validation caught two stale test expectations: FFmpeg may
report full-range 8-bit samples with YUVJ aliases, and the encoder probe source
gate used the retired HDR lambda names. The decoder fixture also now drains
normal buffered output and requires all six intact IDRs with exact timestamps,
formats and ranges. No production profile/range check was relaxed. Native
wire and concurrent queue-ownership tests run on both Clients; deterministic
ELF-wrapped scheduler tests run on Linux. Linux compilation additionally caught
a stale encoder declaration, a logger name collision and the declaration prefix
left by a removed callback; all are fixed in this candidate. Candidates
1.3.10–1.3.12 were not accepted or installed. The 1.3.12 Mac Host build/signing,
original H.264 decoder fixtures on both Clients and Ubuntu normal/sanitizer
rendering fixtures passed before the final corrections.

Current runs: Client qualification `41497448295`, signed Mac Host `41497504932`,
signed Mac Client `41497522046`; the corrected Linux Host uses a separate targeted
build. Run `41499694390` compiled the Host and passed transport/FEC tests,
but exposed the obsolete binary asset-path check after shader removal. The
asset packaging and check now follow the actual runtime requirements.
Next: finish the hosted gates, collect original
packages/manifests and record results here. Installed acceptance must
cover exact-profile decoding/color, native X11 x264 and NVENC, NvFBC, input/Wacom,
reconnect, audio and both supported Mac version floors. Do not deploy as part
of this pass.

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
