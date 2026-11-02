# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Keep machine inventory,
credentials and private captures outside Git. This file records current work;
older candidate provenance remains in Git history and the artifact catalog.

## Active — Desktop code simplification

Branch: `code-simplification`, starting from pushed root `94aeeee` and the
`host-cleanup` nested commits recorded below. The operator authorized all five
items in [the plan](docs/development/plans/code-simplification.plan): unsupported
Windows Host removal, a shared profile catalog, owned encoded Client frames,
Client lifecycle consolidation, and Mac Host display transactions outside the
shared runtime lock. All five implementations, focused regression checks and
four hosted candidate builds are complete for **1.3.05-code-simplification**.
The packages are downloaded and checksum-verified. No merge, release or
deployment was performed.

Current implementation pins:

- Client `6739eafdd19c9b1bae370c9e9a3c72001bcaaba1`.
- Client common-C `51b084da8f5fd894bf1962690a05b7b0f1269476`.
- Linux Host `cb4b6b49c119cca269e24d9fcfb6f120cb5dc0d2`.
- Kymux `12af484eb307351b068aba96da12afce46f4614b` (unchanged).

The Linux Host removal deletes about 19,000 lines of unsupported Windows code,
including its platform dependencies and unused settings. Active Linux capture,
encoding, input, NVIDIA API13 and the full CUDA architecture list are retained.
The shared catalog preserves profile IDs, exact formats and runtime hardware
probes; malformed or partial profile names are rejected. Encoded frames share
one allocation through FFmpeg except when SPS rewriting or noncontiguous prefix
removal requires assembly. The transport-to-C boundary still copies once.
Client cancellation cannot be undone by late recovery completion. Mac display
preparation, takeover drain and restoration run outside the runtime lock, with
reserved admission, scope/token revalidation and asynchronous shutdown.

Portable checks pass: 115 CI-policy cases, eight common-C regressions, eight
root build/structure contracts, C/C++ catalog contracts, 1,000 lifecycle races
and 2,039 frame/recovery assertions. The four-MiB delta fixture confirms one
allocation and no NAL/reassembly copies. Hosted Ubuntu component tests passed
under ASan/UBSan. Mac runtime tests passed actual TLS/QUIC admission, takeover,
disconnect/expiry restoration and cancellation with a synthetic display provider;
cancellation drained in 0.08 seconds. These do not prove physical-display or
installed session behavior.

Hosted candidate builds:

| Product | Run | Root source | Result |
| --- | --- | --- | --- |
| Linux Host | `41378937781` | `d98e996` | Passed; RPM collected |
| Ubuntu Client | `41379496268` | `e2f42a6` | Passed; DEB collected |
| macOS Host | `41378048318` | `e986108` | Passed; signed/notarized PKG collected |
| macOS Client | `41378323417` | `f1d873e` | Passed; signed/notarized PKG collected |

The Linux Host passed three 900-frame, 150-Mbit/s loss-matrix trials spanning
0, 0.5, 1, 3 and 5 percent injected loss, with zero unrecovered frames, plus
its input lifecycle suite. This is synthetic transport qualification, not a live
network or NVIDIA hardware pass.

Packages are in `artifacts/packages/candidates/1.3.05-code-simplification/`.
Original manifests, full logs, local fixture reports and recursive pins are in
`artifacts/qualification/code-simplification-1.3.05/`. Package manifests retain
each exact source commit and SHA-256. The root snapshots differ only by the
Client changelog and Linux packaging gate corrections; later changes do not
alter either built Mac product. Initial runs found a JSON Boolean type mismatch
in the Mac catalog adapter and stale source assertions for deleted Linux Host
Boost.Process guards and Client profile switches. These were corrected without
restoring retired production paths; the corrected gates remain enforced.

Ubuntu normal and ASan/UBSan suites, compositor checks at 100/125 percent scale,
two-display behavior, three launcher smoke runs, package identity and dependency
closure passed. Mac Client Qt/Metal fixtures and both Mac package/signing gates
passed. Temporary task build/download directories were removed after preserving
reports and packages. No hosted build remains active for this work.

Next: install matching candidates for the hardware/session acceptance below,
especially exact-profile decode, reconnect/cancel, Wacom, A/V soak and Mac
display restoration. Fixture results do not substitute for those checks.

## Previous checkpoint — Host and desktop Client cleanup

The pushed starting checkpoint is root
`94aeeee149b75b4c851931e1138e5bedfcac5aff` on `host-cleanup`, with Client
`48bc98df023ecddb8967edef3d6da70238b2300b`, common-C
`7ead62a835b8eeb99aac264809153424d3c778aa`, and Linux Host
`2fa4d389f8da059dc3bebcead95cd57c35fdcd43`.

Candidate **1.3.04-host-cleanup** already passed all four hosted build/package
gates, including signed/notarized Mac packages. It removed retired Client
crypto/socket/DNS helpers and packaging/rendering paths; unselected Linux Host
display/capture/encoder backends; and schema4–6 negotiation compatibility.
Qt production shader fixtures passed full/limited BT.709 and identity mappings
on software GLES. Those changes are included in the current candidate.

Its original packages, hashes and exact build snapshots remain in
`artifacts/packages/candidates/1.3.04-host-cleanup/`; original manifests, logs and
regression reports remain in `artifacts/qualification/desktop-cleanup-1.3.04/`.
See [the scope inventory](docs/development/reviews/desktop-cleanup-inventory.md)
and [the previous plan](docs/development/plans/host-cleanup.plan). Installed
hardware/session acceptance remains pending; no merge, release or installation
was performed for that checkpoint.

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
