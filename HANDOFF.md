# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Keep machine inventory,
credentials and private captures outside Git. This file records current work;
older candidate provenance remains in Git history and the artifact catalog.

## Active — Host and desktop Client cleanup

Branch: `host-cleanup`, based on the pending dependency refresh and SDL-free
Clients. Candidate version: **1.3.04-host-cleanup**. No merge, release or
installation is authorized by the current cleanup/build task.

The operator asked for a complete pass over the approved cleanup list, including
both Hosts and both desktop Clients, instead of repeated narrow passes described
as complete. See [the plan](docs/development/plans/host-cleanup.plan) and
[the scope inventory](docs/development/reviews/desktop-cleanup-inventory.md).

Committed and pushed:

- Client common-C crypto/socket helpers and redundant DNS/local-address setup
  are removed. QUIC already owns connection establishment. Thread/signal setup,
  input/media queues and callback lifetimes remain.
- Retired Client shaders/font, inherited packaging/prebuilt/Qt5/embedded paths,
  unused controller launch arguments and GFE-only error translation are removed.
  The packed-color fixture now compiles the production Qt shader.
- Linux Host no-op libdisplaydevice and unselected Wayland/KWin/portal/PipeWire,
  VA-API/Vulkan backends are removed, including their submodules/build switches.
  DRM/CUDA/EGL/X11, PLANK display leases/restoration, x264 and direct NVENC remain.
- Host FFmpeg explicitly disables unused SVT-AV1/AMF/VA-API/Vulkan builds and
  requires an exact prepared prefix. Old automatic release-download fallback is
  removed. The preflight verifies selected CBS patches and rejects stale backend
  selections; retained Client Vulkan decoding is separate.
- Mac Host and desktop Client require schema7 media negotiation. Schemas4–6 and
  version-string adapters are removed. Shared request/reply vectors and failure
  tests are updated; independent optional-feature negotiation remains.

Local validation: 115 CI-policy cases, ten prepared-source/patch cases, eight
common-C regressions, 276 native-session lifecycle checks, Host supervisor source
checks and shell/Python/diff checks pass. The production Qt GLSL passed 1,465
samples per mapping for full/limited BT.709 and 8/10-bit identity mappings on
software GLES; maximum conversion error was one ten-bit code, identity zero.
This is neither GPU surface-import qualification nor installed session acceptance.

Source pins:

- Root build source for both Clients and Mac Host:
  `8f7c713dc2495780c037a45c03cf458ad7056cfe`.
- Linux Host build source: root `6b756cfd5c5a2b317fd15934f139572218b04be7`,
  Host `2fa4d389f8da059dc3bebcead95cd57c35fdcd43`.
- Client `48bc98df023ecddb8967edef3d6da70238b2300b`, its common-C
  `7ead62a835b8eeb99aac264809153424d3c778aa`.
- Kymux `12af484eb307351b068aba96da12afce46f4614b` (unchanged).

Hosted candidate results:

| Product | Run | Result |
| --- | --- | --- |
| Ubuntu Client | `41369564545` | Passed; DEB collected |
| macOS Client | `41369570173` | Passed; signed/notarized PKG collected |
| macOS Host | `41369567315` | Passed; signed/notarized PKG collected |
| Linux Host | `41371782372` | Passed; RPM collected |

The Linux Host's first two runs caught a stale capture-selector source assertion
and an unused VA-API include. Both are fixed. Those are the only differences
from the other three products' root snapshot; their built sources are unchanged.
The assertions now follow the retained display-refresh call, and the removed
VA-API dependency was not restored to hide the include error.

Packages are in `artifacts/packages/candidates/1.3.04-host-cleanup/`, with original
source commits, hashes and package checks in `manifest.json` and `SHA256SUMS`.
Logs, original manifests, recursive pins and regression reports are under
`artifacts/qualification/desktop-cleanup-1.3.04/`. Hosted regression suites cover
Qt EGL/Metal, schema7 negotiation, audio/input/lifecycle and package closure;
they do not establish installed hardware/session acceptance.

The approved cleanup implementation and all four hosted package checks are
complete. No build remains active. Installed session acceptance is still pending;
use the matching candidates and the gates below before considering a merge or
release. This task did not merge, deploy or publish a release.

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
