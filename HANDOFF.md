# PLANK handoff

Read `AGENTS.md` and the relevant build runbook first. Machine inventory,
credentials and private captures stay outside Git. This file records current
state; older detailed results remain in Git history and the artifact catalog.

## Code review hardening — all candidates ready

The operator authorized **every finding** from the full read-only review on a
new branch, without intermediate approval stops. Root, Client, Linux Host,
Client common-C and Kymux use **`code-review-hardening`**, based on main
`b8a0f1a84f00b90e42c152f7b8600368bf858866`. Version is **1.4.10**. Work is
committed and pushed; no merge, release publication or installation is requested.
See [the implementation checklist](docs/development/plans/code-review-hardening.md).

Current pins:

- Client `669b792e70150b8f679a90a273059e2190ded7dc`.
- Client common-C `c7d1b83143be1511735526ae8ce75a6d5c25f63c`.
- Linux Host `539f58b057da36124800837d49896b940de218bb`.
- Kymux `9e1a7e304abe4ad6b42a7a10ef41eae2b16fb31f`.

Implemented:

- Bound Linux HTTPS buffering/admission before dispatch; correct the fallback 404.
- Bound KyProto control records and propagate fatal control/router failures.
  Datagram backpressure is isolated per endpoint; retired endpoints are safe.
- Replace detached common-C failure callbacks with synchronous once-only
  notification on the producing thread. Qt queues teardown/recovery and joins
  producers before retiring the session. Native Apple uses its direct bridge.
- Release all held mouse buttons and mapped keys; clear transient Alt/modifier,
  repeat and scroll state while preserving persistent tablet identity.
- Use bounded, cancellable caller-owned PulseAudio capture/control on Linux.
- Remove Sunshine directory migration, unsupported AV1 and unused utilities;
  retire unused Client toolbar/pointer/focus/color helpers, artwork/game metadata,
  polling and audio statistics that always returned zero.
- Remove the unused alternate setup lifecycle. Local C ABI is 14; the shipping
  wire format is unchanged. HTTPS handles authentication/topology, QUIC handles
  launch and active traffic. Rebuild static consumers against matching headers.
- Assemble video metadata/payload once and reuse that owned allocation in FEC.
  Source-first submission, repair policy and packet bytes are unchanged.
- Cache Native X11 geometry behind checked root/overlay structure subscriptions.
  Every capture still validates depth/SHM size and rejects racing display changes.
- Select affected CI products and fingerprint dependencies independently. Schema 3
  required one new cache population; verified dependencies now reuse those keys.

GitHub package builds and original installers:

| Product | Source root | Build | State |
| --- | --- | --- | --- |
| Ubuntu Client | `1576ed26` | `42318113500` | Passed, downloaded and verified |
| Mac Client | `3b0550bf` | `42318465953` | Signed/stapled, downloaded and verified |
| Mac Host | `49897540` | `42317158306` | Signed/stapled, downloaded and verified |
| Linux Host | `91fd5954` | `42321629509` | Passed, downloaded and verified |

Catalog: `artifacts/packages/candidates/1.4.10-code-review-hardening/`.
Original builder manifests, logs and reports are in
`artifacts/qualification/code-review-hardening-1.4.10/`. Client production code
is identical at `c3e2b670` and `669b792e`; the latter only synchronizes a UI test
with Qt layout. Later root differences are test fixtures/documentation or other
products, not unrecorded modifications to already collected packages. Preserve
each original manifest and hash; never relabel a package.

Verification passed:

- 131 CI policy tests, eight portable root packaging/privacy tests, common-C
  component suites and 941 lifecycle assertions pass. Common-C and Native10
  AddressSanitizer/UndefinedBehaviorSanitizer checks pass. Local ThreadSanitizer
  could not link because its runtime is absent; do not claim a TSan pass.
- Linux HTTPS/PAM bounds and lifecycle tests pass. Input/crypto fixtures pass
  25 shuffled repetitions. The actual PulseAudio backend captures a synthetic
  tone, cancels within 500 ms while the daemon is stopped, cleans up within 1s,
  and captures again after it resumes. This isolated fixture passed in 4.082s.
- Default and diagnostic-feature Rust Clippy pass with warnings denied.
  Actual KyProto parser/state tests and native encrypted media/data/cancellation
  fixtures pass. Exact integration filters now reject a zero-test result.
- Linux hosted transport run `42316773288` passed three 900-frame, 150 Mbps loss
  matrices through 5%, with zero unrecovered frames and zero unintended kernel
  drops; all four ACK-hold/receiver-pause cases passed and recovered in place.
- The exact Mac test executable from that run, with shipping `sender-timing`
  features and target 26.7, passed three matrices on the authorized development
  Mac: 2,700 frames, 150 Mbps throughout, zero unrecovered frames, worst delivery
  16.796 ms, p95 maximum 11.827 ms and receive-gap maximum 23.610 ms. Its SHA256 is
  `1ca3222cb35cad8b84c16829064df143ba3a10905984634198d9eab5787fa1e8`.
  Mac kernel-drop counters are unavailable. Terminal and Host were preserved;
  all temporary remote files are removed. This is isolated transport qualification.
- Read-only Native10 capture at 5120×2160 / depth 30 passed geometry and SHM checks.
  Median 6.07 ms batched versus 5.99 ms cached does not establish a material FPS gain.
  Two geometry queries per steady frame are removed. No saved screen pixels,
  service restart, display/input change or installed session test occurred.
- Ubuntu passed Qt input/rendering, ASan/UBSan, compositor/launcher, real PipeWire
  playback and package gates. Both Mac products passed their component and
  signing/notarization/package gates; these do not establish installed acceptance.

Superseded failures were corrected rather than waived: stale setup packet/test
expectations; leftover Client declaration/include dependencies after artwork
removal; a UI assertion sampling delegates before layout; and an isolated
PulseAudio fixture inheriting an unsuitable CI home directory. The latest Host fixture gives its daemon private runtime/state/cookie paths
without changing HOME, uses a synthetic tone and allows bounded source startup
separately from unchanged cancellation/teardown deadlines. A standalone daemon
check measured first PCM at about 2.1s; an immediate one-second expectation was
incorrect. Component tests now run before the full media/RPM build. The preceding Host run passed compilation, HTTPS, input/crypto, transport
and RPM checks but failed daemon startup before exercising audio recovery.
The corrected fixture and all final gates passed in run 42321629509. No test
was disabled and no cancellation, loss or latency threshold was relaxed.

All four original manifests and package hashes match the local catalog. Both
Mac PKGs are signed, notarized and stapled. Downloads are cleaned up; logs,
original manifests and qualification evidence remain. Next is operator
installation/session acceptance, then an explicit merge or publication decision.

## Main baseline — 1.4.09 packages ready, publication held

Main remains `b8a0f1a8`. All four 1.4.09 packages are built from exact source
`6c9bf535338c72d40b5193b8c112282b2ffa591b` and retained in
`artifacts/packages/releases/1.4.09/`; no release/tag or installation was made.
The catalog's `releases` name denotes mainline provenance, not publication.

Pins: Client `1c54da5d0cfae834c9484c67c3519bad8024d263`, Linux Host
`2281c3ed6dbf5779ec75dba15a8a4f165efba1fa`, Kymux
`079e56477a0577c74fb643400668ac983662d3e4`.
Successful runs: Linux Host 42309328630, Ubuntu 42309335146, signed Mac Host
42309339041, signed Mac Client42309343325. Transport 42309346962 passed;
its exact Mac test binary matched the qualified candidate. Original manifests,
checksums and reports remain in `artifacts/qualification/mainline-1.4.09/`.

Main includes shared source-first FEC and the 4 MiB outgoing datagram queue,
2 MiB minimum in-flight window and 1 Gbps controller budget. There is no application
pacer or unbounded queue. Reliable-data pressure pauses and resumes reads instead
of ending a session; explicit takeover/security failures remain terminal.
Earlier installed 1.3.16 testing recovered through 8% induced loss and recovered
after an 8.5% FEC exhaustion event without reconnecting; a later 7% one-minute test
also remained normal. Those historical results do not accept new candidates.

Dependencies remain FFmpeg 9.0.2, Qt 6.10.2, Boost 1.92, JSON 3.12, Vulkan 1.4.367,
Kymux/Kyproto 0.29, Quinn 0.11.12 / proto 0.11.19 / udp 0.5.16, Rustls 0.23.46,
RaptorQ 2.0.1 and Rust 1.99.1. NVIDIA 595.104.02 / CUDA 13.2 Update 2 / NVENC SDK 13.0.19
and the full CUDA architecture list remain. Transport ALPN is `plank-native/2`.
Older package provenance is preserved in the catalog, plans and Git history;
see the [cleanup inventory](docs/development/reviews/desktop-cleanup-inventory.md)
and [simplification plan](docs/development/plans/code-simplification.plan).

## Separate work and remaining acceptance

Native Apple/AVP development and TestFlight automation remain on `native-builds`
and the dedicated AVP branches. Their own protocol pin is unchanged; consult
that branch's HANDOFF before resuming. When rebasing to C ABI 14, remove the native
bridge's obsolete `config.session_mode` assignment and `SETUP_READY` allowance.
Do not merge or delete those branches as part of desktop hardening. Contributor
Mac test/signing branches remain; main protection was discussed, not enabled.
The hardening branch's signing permission is 65803900; retain it until retirement.

The authorized development Mac is identified in private notes. Preserve Terminal
and active sessions. Reference Macs are read-only unless reassigned. No active
remote collector, loss injection or temporary probe remains from this pass.
No package installation, reboot or service restart was performed.

Installed acceptance still requires the exact candidate packages:

- Capture/encode and exact-format hardware decode/presentation, 10-bit color,
  4K/5K, fullscreen/window scaling, Retina/notch and multiple displays.
- Wacom pressure/clicks/Tablet Margins, mixed local/remote models, USB reconnect
  and network recovery; preserve the persistent-tablet contract.
- Real A/V listening/synchronization soak, audio-device changes, microphone,
  camera, clipboard, disconnect/reconnect and desktop transitions.
- Mac setup/permissions/uninstall and login/locked takeover; the identical Host
  package on 26.7 and 27, and Client on 15 and 27. Chris owns 26.7 session validation.

Intel NUC Gen11 is unqualified; no runtime blacklist was added. Its repeated
video-engine hangs remain unexplained despite passing isolated controls. Do not
resume that investigation without operator direction. See
`docs/hardware/intel-nuc-client-qualification.md`. A separate earlier surface-timeout
investigation is paused; packet-loss snapshots do not establish its cause.
Wallpaper/Screen Saver pointer lag, Linux physical-display provenance,
application hotkeys and immediate-paste stress remain separate deferred work.
