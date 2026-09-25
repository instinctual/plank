# PLANK handoff

## Current task and source

Continue native camera forwarding and stereo microphone work on
`native-media-investigation`, isolated worktree
`build/worktrees/native-media-investigation`. The operator authorized implementation,
packages and hardware tests, stopping only for necessary operator action. They also
requested Manual as the default Client microphone activation mode; existing saved
choices must be preserved. See [the implementation plan](docs/development/plans/native-media-forwarding.plan).

The branch was synchronized with main `acb29884bff626c9381169fd94563ec79555984c`.
Its original runtime base was `af71d2b404486a9846bca464ddd646b5ab9c738a`.
The separate main/startup-fix and RK3576 work remain untouched. No merge, tag or
GitHub Release is authorized. Candidate version is **1.1.014-native-media-investigation** (HAL clock-period correction).

Host 1.1.013 source is `8aeca421d6bed09f1ad6c45aa5f7d2b98e071ce3`.
It explicitly clocks the capture aggregate from PLANK Output and adds bounded
source/clock/queue gap diagnostics. It retains the 500ms observer and 1-second
maximum observation age. Client changes are release notes only; installed
Client 1.1.010 remains compatible. The next Host uses the corrected HAL drivers. Current inputs:

| Input | Commit |
| --- | --- |
| Client | `b5c3a7a5ddd37e010155883054931be3010fc5a2` |
| Client common-c | `060f6179f88343327b44d915007f1fb4cede71f1` |
| Client qmdnsengine | `920c097ffa742e2968290f15d4dde6693aec02e5` |
| Kymux | `3f7a9d8618978287186e5d6ce0eaa067743cb06c` |
| Linux Host | `5829bf7c335440a8b25c3330643eacb4d914f00a` |

Runtime correction source is `730c5d48f36b792d4de6506e8cfda28aec46f6da`.
SDK27 ASan/UBSan tests pass for both driver clocks, multi-reader/restart behavior,
bounded stereo history and output tap/routing/XPC. The100000-block tap ring,
one-million-frame microphone history and full microphone component build pass.
The offline production Opus fixture passes12216 checks for each synthetic tone.
Candidate publication is in progress. Package manifests retain per-product source provenance;
never relabel a signed package or rebuild different bytes into an existing catalog
entry. Temporary signing permission was removed after Host 1.1.013 completed;
main-only policy is verified. No signing credentials were read, changed or committed.

## Active audio regression

Host1.1.013 and Ubuntu Client1.1.010 are installed; the Host executable matches
its signed package. Recurring continuous distortion remains. Preserve the active
session: do not restart services, toggle forwarding, close applications, change
permissions or install automatically.

Controlled synthetic1kHz tone tests distinguish the routes: the operator hears
a clean tone played directly through Ubuntu's normal output and distortion when
the same tone traverses the Mac/PLANK route. Bounded aggregate measurements find
phase/energy distortion already at the Client Opus decoder. The production Mac
Opus encoder passes offline tests across180/512/960-frame interleaved and uneven
planar inputs with byte-identical packets; the exact installed Client decoder
reproduces the synthetic tone with coherence greater than0.999. This narrows the
investigation to the live Mac path but does not independently prove its cause.

A confirmed SDK contract violation exists in both virtual HAL drivers: the live
Output device advertises480 frames for `kAudioDevicePropertyZeroTimeStampPeriod`,
while SDK27's `AudioServerPlugIn.h` requires at least10923. The driver correction
uses15840 frames to match the measured built-in output, separates microphone IPC's unchanged480-frame packets and
permits bounded HAL reads through the8192-frame sample history. Component
qualification passes; a fresh Host candidate is in progress; no installed fix is claimed. The
built-in output reports a512-frame IO buffer and15–4096 supported range; both
installed PLANK devices report180 frames and15–180 range. All run at48kHz.

Earlier source-gap traces were contaminated by Host stack sampling: the bursts
of299/336 irregular source timestamps coincide exactly with profiler windows.
They must not be used as proof of the original fault. With that profiler stopped,
a40-second trace contains8058 packets with continuous5ms source timestamps,
no missing samples and one empty SDL queue observation despite audible distortion.
Do not run Host stack sampling again during audio qualification. All bounded
probes have exited. Reports stay private; only generated tones and aggregate
statistics were retained, with no recording of user media.

Host1.1.013 retains PLANK Output as the aggregate's explicit main clock and
bounded capture diagnostics. Its installed benefit is unproven. Host1.1.012's
separate500ms background ownership observer remains:457 lifecycle checks pass,
with one-second freshness and immediate user-switch/sleep revocation. Previous
samples exposed synchronous account queries on the media queue; that contention
was removed. Profiled dropout/overrun counts cannot quantify the original fault.

## Implemented behavior

Camera capture on Ubuntu preserves native H.264 Annex B/MJPEG coded payloads
through the authenticated Kymux connection. There is no Client camera encoder.
The Mac camera extension supplies compatible compressed samples or decoded NV12
pixels according to the active application format. Native H.264 NAL framing is
adapted for Core Media; this is not recompression. Camera starts off on connection
and reconnect. Missing selected devices fail explicitly without selecting another.

Microphone audio deliberately uses Opus at192kbps total, constrained VBR,
48kHz stereo and10ms packets, following the operator's choice over native PCM
transport. Opus is lossy. The measured webcam USB input is32kHz S16LE stereo;
the Client converts the selected input to the transport format. The Mac virtual
microphone exposes48kHz interleaved stereo Float32 with shared timing/drift
correction. A mono source cannot acquire independent channels through conversion.

Candidate1.1.010 adds:

- Manual microphone activation for new Client settings, preserving saved choices.
- Recovery-frame requests when another app joins PLANK Camera, with bounded retries
  until an independent frame is delivered after that join. Existing readers continue.
- Microphone3 capture timestamps from PipeWire buffer cycles and reported graph/
  resampler latency, compensated for Opus lookahead. Bounded PCM assembly expires
  stale speech and preserves sequence gaps for codec reset.
- Host camera presentation mapped to the first source sample actually consumed by
  the microphone renderer after drift correction, using its scheduled HAL clock.
  Fresh anchors expire after100ms and allow at most150ms extrapolation. Silence,
  mute, driver resets and cleanup invalidate them. Camera-only/legacy microphone
  sessions retain arrival timing. Native camera bytes and camera schema1 are unchanged.
- Camera IPC version2 separates receipt age from future presentation time. Decoder
  completion repeats freshness checks; future presentation cannot renew stale data.

Ubuntu offers microphone3 then2; the macOS Client currently offers2. Older peers
retain unchanged stereo microphone2. Authenticated independent feature negotiation
uses launch7, with exact launch4/5/6 adapters. Schema4 disables old mono microphone;
schemas5/6 retain stereo and camera requires6/7. Known older Hosts are bridged only
after pinned HTTP404; TLS/auth failures never trigger fallback. See
[media negotiation](protocol/media-feature-negotiation.md), [microphone timing](protocol/microphone.md)
and [camera transport](protocol/camera.md).

Host1.1.009's working output behavior is retained: desktop capture reads only
PLANK Output UID/stream0 with an unmuted Core Audio tap and verified-process
allowlist. Physical outputs play locally. Volume/mute follow PLANK Output.
Desktop ScreenCaptureKit captures video with audio disabled; root LoginWindow
retains its separate ScreenCaptureKit audio path. Automatic selection uses the
installer-created root0700 OutputRouting journal directory, restores prior devices
only while PLANK still owns selection, and preserves later manual choices.
See [audio architecture](docs/architecture/macos-audio-tap.md).

The redundant Enable Camera setup dialog fix is retained: query actual extension
properties, reconcile upgrades, and show the enabled state without asking again.
Real first-use, approval, disabled, error and reboot states remain explicit. The
Installer recommends restarting and permits deferral; no script reboots or restarts
Core Audio. Current active sessions must be preserved during staging.

## Packages and validation

The Host 1.1.013 package is collected at
`artifacts/packages/candidates/1.1.013-native-media-investigation/macos/plank-host_1.1.013-native-media-investigation_arm64.pkg`.
SHA-256: `6c9595a0db9ecaad2c8b239e5d65bcfb34566f60f20aa2d3f4786884e2a24108`.
It uses root8aeca421 and Cliente8e1030eff04759e30645f26b08e0d27c707aee7. Signed
[Host run 36071264074](https://github.com/instinctual/plank/actions/runs/36071264074)
passes all build, test, signing, notarization and package gates. The test target's
Downloads copy passes transfer hash, package signature, Gatekeeper, version,
RecommendRestart and all four component signature checks. The operator installed it and rebooted; the running executable matches the
signed package. Distortion remains under the controlled tone test above.

The preceding Host 1.1.012 package is collected at
`artifacts/packages/candidates/1.1.012-native-media-investigation/macos/plank-host_1.1.012-native-media-investigation_arm64.pkg`.
SHA-256: `187053e123263fbcefc843d9f335b15c33b81a18529c79a02a159804c6ab7d7a`.
Its source is root `177061ffda5012a30d33a89fcb27f051f1bc0a26`,
Client `72c6267ce7bec8788a1256382841ecbe54a75262`, signed run36067300678.
The test target's Downloads copy passes transfer hash, package signature,
Gatekeeper, version, RecommendRestart and all four payload component signature
checks. The operator installed it and rebooted the Host; its installed Host
binary matches the signed package. Residual crackling cleared only after the
operator subsequently rebooted the Client. The agent did not restart services
or change forwarding configuration.

Host1.1.011 is collected at
`artifacts/packages/candidates/1.1.011-native-media-investigation/macos/plank-host_1.1.011-native-media-investigation_arm64.pkg`.
SHA-256: `4188d0b4bf9f4b33928af7f0115f0f3d04c89e3cdd0a9ce20c8a2f48173114a4`.
Its source is root `b7c2b6fb57b5ab4d6233ba4554c1efb5e92b60b0`,
Client `b5423392b312200a9ef4cac2da63d547338733f2`, signed run36066019394. The
Downloads copy passes transfer hash, package signature, Gatekeeper, version,
RecommendRestart and all four payload component signature checks. No install,
reboot or CoreAudio/service restart occurred. Client1.1.010 is compatible.

Signed [Host run36061559638](https://github.com/instinctual/plank/actions/runs/36061559638)
and [Client run36061563286](https://github.com/instinctual/plank/actions/runs/36061563286)
pass the full builds, tests, signing, notarization and package gates.
[Corrected run36062636492](https://github.com/instinctual/plank/actions/runs/36062636492)
passes all four product jobs, including Linux Host. The table below retains
the previously staged1.1.010 packages, separately from the1.1.011 Host above.
Mac 1.1.010 source is `f006f95cb85e0bb9a3a13bdca74914f6d110cb44`;
Ubuntu 1.1.010 source is `2b09aba2bc8a34262e1e0d366917e5c54d5772a1` (tests-only
difference), both with Client `9921712feca1346fe627e6c650c0ac646b7df4c4`.

| Package | SHA-256 |
| --- | --- |
| Ubuntu Client DEB | `d668178a9340f146309f1db5c6374079c99695ecece5e52406a2327b422ee5b8` |
| macOS Client DMG | `3df014b9720d1915c1914dc58e746ee2313d1d0a9fdd7fd25cf7c85af5db9b5c` |
| macOS Host PKG | `4887bd102a84a9ccac297b65b105518e9d44954a32d57e7e4d0657339f809877` |

All artifacts belong under
`artifacts/packages/candidates/1.1.010-native-media-investigation/`.
Both Mac installers are staged in the office Host test target's Downloads;
Ubuntu Client is staged in the development Client's Downloads. Transfer hashes
and package versions pass; Mac signatures/Gatekeeper and Host RecommendRestart
also pass on the target. Ubuntu Client 1.1.010 remains installed; the Host was
subsequently updated to 1.1.013. The Mac Client installer remains staged.
Completed Ubuntu component worktrees, builds,
bundles and the temporary extracted SDK were removed; private reports remain.

Focused gates pass: fixed microphone2/3 vectors and malformed bounds; encrypted
reverse microphone mute/reopen in both formats; Ubuntu legacy/timed capture actors;
232 Client launch checks;52 Mac feature checks;36 real Ubuntu Qt/TLS scenarios;
capture queue gaps/expiry/stereo; source/Host origin, drift, reset and expiry tests;
SDK27 camera IPC/lifecycle and microphone producer/session compilation.

The first Ubuntu full build found a fixture expecting only microphone2 offers.
Root2b09aba corrects that expectation and adds real TLS cases for microphone3
acceptance, runtime unavailability and rejection of an unagreed downgrade. No
runtime or authentication policy was weakened. Full builds use the declared
PipeWire development dependency; local component checks used a matching extracted
SDK without installing packages on the builder.

A three-second live input probe receives281 packets with increasing source times,
2.8026s source span and12.2–18.9ms source-to-read age. It records timing counters only,
not samples. Reported hardware/graph latency remains an input to synchronization;
this probe and synthetic clock tests do not establish physical lip sync.

## Installed baseline and next test

The operator uses the authorized development Ubuntu Client with the authorized
office Mac Host test target. Build Mac components/probes only on the dedicated
SDK27 development Mac or authorized hosted workers. The office Mac is test-only.
Machine addresses, accounts, deployment details and reports remain in private
notes outside Git; read their local README before machine work.

Host 1.1.013's installed executable matches its signed package. The active
Ubuntu Client reports 1.1.010. Host 1.1.009's working output routing is retained;
the current residual audio regression and candidate are described above.
The separate Mac Client1.1.005 display-mode fallback was installed and its
connection succeeded; do not restore the fatal missing-native-flag check.

Prior installed camera tests pass separate native H.264 delivery:317 frames at
1920x1080 over10.522s, and separate NV12:310 frames over10.307s, both with zero
invalid samples/application drops. The operator confirmed QuickTime, FaceTime
and Zoom capture. One simultaneous native-first/pixel-second run delivered only
14 pixel frames with241 drops; the new recovery fixture is not a substitute for
repeating that installed test. Other application formats may inherit an existing
pixel stream; automatic output does not guarantee native coded delivery.

Next: validate and stage Host1.1.014 with the HAL clock-period correction.
Keep the active diagnostic session until the operator chooses to install/reboot.
Then verify loaded driver clock properties, repeat the quiet synthetic tone and
website camera permission/start/stop trigger, and compare aggregate signal/timing
statistics without Host stack sampling. Confirm normal typing and playback with
both capture devices disabled and enabled.
Then qualify:

1. Manual default and mute/reopen, physical channel separation and cleanup.
2. Native-first/pixel-second and reverse-order concurrent readers for sustained delivery.
3. Combined camera/microphone lip sync, timestamp mapping through load/loss, unplug/reopen
   and reconnect; native payload preservation remains required.
4. Output restoration on disconnect/crash/unplug, manual override, local physical
   playback and remote volume/mute. The working-session report does not qualify
   these unobserved transitions.

All diagnostic readers/probes are stopped. General Linux color/input/Wacom,
network, privacy and production gates in
[acceptance criteria](docs/development/acceptance-criteria.md) remain unchanged.
