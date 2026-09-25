# PLANK handoff

## Current task and source

The operator-authorized integration of `native-media-investigation` into `main`
is committed and pushed, including its Client dependency. Root main reached
`2a0701d92c4412f25807c517943bf01cdc9ed566`; Client main reached the commit below.
Stereo validation is recorded in root `b9b1036bb5dff2915483c565f070332b2b8151f0`:
the operator confirms distinct physical webcam microphone channels on the home
Client. The implementation is saved; remaining work is the installed hardware
qualification listed below. No further implementation change follows from that
confirmation.
The tested feature worktree is `build/worktrees/native-media-investigation`;
main integration uses the existing clean main worktree. Preserve the separate
RK3576 work. See [the implementation plan](docs/development/plans/native-media-forwarding.plan).

Both main branches fast-forwarded to the tested feature tips without conflict
resolution, with the Client pushed first. The root's previous main
is `acb29884bff626c9381169fd94563ec79555984c`; the Client's previous main is
`cc511584c41c337569a1efd559a7c3362283d9cc`. Root feature `3bef4f6d6407ab0d8cb978896527f9e2db7533db`
passes all four product jobs in [run36078190861](https://github.com/instinctual/plank/actions/runs/36078190861),
plus privacy and clipboard regression checks. Integration preparation changes only
documentation. Kymux, common-c, qmdnsengine and Linux Host gitlinks are unchanged
from main. No merge requires new runtime code or a replacement installed package.

Source version is **1.1.014**. Existing feature-qualified artifacts retain their
original filenames and provenance; never relabel them as main builds. No new
signed package, tag or GitHub Release is requested by this integration.

Host1.1.014 package source is `c12f325fb5df8fdc21549cca97de5670ee71c282`.
It corrects both HAL driver clock periods while retaining PLANK Output as the
explicit aggregate clock, the500ms background session observer and one-second
maximum observation age. Client changes are release notes only; installed
Client1.1.010 remains compatible. Current inputs:

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
Root and Client source are pushed; Host1.1.014 is signed, collected and staged. Package manifests retain per-product source provenance;
never relabel a signed package or rebuild different bytes into an existing catalog
entry. Temporary signing permission was removed after Host1.1.014 completed;
main-only policy is verified. No signing credentials were read, changed or committed.

## Audio regression and installed correction

Host1.1.014 and Ubuntu Client1.1.010 are installed. All four installed Host
component hashes match the signed package. Read-only HAL queries confirm both
PLANK devices now report a15840-frame clock period and512-frame IO buffer,
matching the built-in output. The operator reports that the correction appears
to have fixed the distortion and confirms the repeated quiet1kHz tone is clean.
Six steady tone seconds measure coherence above0.99996 at the Client decoder,
PipeWire handoff and ALSA output. The start overlapped existing playback and is
excluded from the pure-tone metric. A40-second metadata trace receives8052
packets with continuous5ms source timestamps and no missing-sample markers;
the Host audio log remains unchanged. Arrival jitter reaches93.5ms and nine
SDL input-queue-empty observations occur; these do not independently establish
audible underruns. Prolonged recurrence and duplex soak remain separate gates. Preserve the working
session; no automatic restarts, permission changes or capture toggles.

Before the correction, controlled synthetic1kHz tone tests distinguished the
routes: the operator heard a clean tone directly through Ubuntu's normal output
and distortion when the same tone traversed the Mac/PLANK route. Bounded aggregate measurements find
phase/energy distortion already at the Client Opus decoder. The production Mac
Opus encoder passes offline tests across180/512/960-frame interleaved and uneven
planar inputs with byte-identical packets; the exact installed Client decoder
reproduces the synthetic tone with coherence greater than0.999. This narrows the
investigation to the live Mac path but does not independently prove its cause.

The previous virtual HAL drivers violated the SDK contract: the installed
Output device advertised480 frames for `kAudioDevicePropertyZeroTimeStampPeriod`,
while SDK27's `AudioServerPlugIn.h` requires at least10923. The driver correction
uses15840 frames to match the measured built-in output. It keeps microphone IPC
at480-frame packets and permits bounded HAL reads through the8192-frame history. Component
qualification passes. Before the correction, the built-in output reported a
512-frame IO buffer and15–4096 range; both PLANK devices reported180 frames and
15–180 range. All use the same48kHz
stereo Float32 interleaved format. The built-in output explicitly uses simple IIR
clock smoothing and a stable clock; PLANK inherits those SDK defaults. Physical
output latency60 and safety offset48 frames must not be copied into the virtual
sink. Clock-domain identifiers must not falsely claim shared hardware timing.
After installation, HAL selects512-frame IO buffers for both PLANK devices.
No buffer-size setter or physical routing change was added.

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
was removed. Keep this scheduling change: it prevents slow OS queries from
blocking media/input. The500ms interval reduces scheduled queries from50 to2 per
second; it is not proven to have cured the distortion. Profiled dropout/overrun
counts cannot quantify the original fault.

## Installed microphone follow-up

Two simultaneous Mac application readers pass delivery checks for12 and8 seconds:
576000 and384000 frames,48kHz stereo, no invalid or over-full-scale samples.
Both runs receive identical left/right samples. This proves concurrent delivery
in stereo format, not independent stereo source preservation; the active physical
source was not verified. All readers exited and no media was saved.

On 2026-09-24, the operator tested a physical stereo-microphone webcam with the
home Ubuntu Client and confirmed distinct left/right channels. This closes the
audible channel-distinctness check for that setup. The report does not specify
the webcam model, Host or installed versions; it is operator confirmation,
not an instrumented channel-mapping or crosstalk measurement. It does not change
the earlier concurrent-reader measurements or qualify camera/microphone lip sync.

## Implemented behavior

Camera capture on Ubuntu preserves native H.264 Annex B/MJPEG coded payloads
through the authenticated Kymux connection. There is no Client camera encoder.
The Mac camera extension supplies compatible compressed samples or decoded NV12
pixels according to the active application format. Native H.264 NAL framing is
adapted for Core Media; this is not recompression. Camera starts off on connection
and reconnect. Missing selected devices fail explicitly without selecting another.
Camera discovery has no vendor/model whitelist. The current Ubuntu capture path
requires native H.264 or baseline MJPEG at720p/1080p nominal30fps. Raw-only modes,
other sizes/rates and macOS Client camera capture are not implemented. The tested
physical camera does not qualify broad model compatibility.

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

Host1.1.014 is collected at
`artifacts/packages/candidates/1.1.014-native-media-investigation/macos/plank-host_1.1.014-native-media-investigation_arm64.pkg`.
SHA-256: `e785833fceafa737d7249edf6991a68ae3272d8f08f2f976c26ecd0dd3ba9f00`.
Signed [Host run36076189576](https://github.com/instinctual/plank/actions/runs/36076189576)
passes the full build, tests, signing, notarization and package gates at
root`c12f325fb5df8fdc21549cca97de5670ee71c282`, with the current gitlinks above.
The Host test target's Downloads copy passes transfer hash, package signature,
Gatekeeper, exact version, RecommendRestart and all four component signatures.
The operator installed it; all four installed component hashes match this
package, and both loaded audio drivers report the corrected period and512-frame
buffers. The operator reports audible recovery and confirms a clean repeat tone. Temporary branch signing
permission is removed and main-only policy verified. No credentials were read
or changed; no agent-initiated installation or service restart occurred.

The Host 1.1.013 package is collected at
`artifacts/packages/candidates/1.1.013-native-media-investigation/macos/plank-host_1.1.013-native-media-investigation_arm64.pkg`.
SHA-256: `6c9595a0db9ecaad2c8b239e5d65bcfb34566f60f20aa2d3f4786884e2a24108`.
It uses root8aeca421 and Cliente8e1030eff04759e30645f26b08e0d27c707aee7. Signed
[Host run 36071264074](https://github.com/instinctual/plank/actions/runs/36071264074)
passes all build, test, signing, notarization and package gates. The test target's
Downloads copy passes transfer hash, package signature, Gatekeeper, version,
RecommendRestart and all four component signature checks. The operator installed it and rebooted; the running executable matches the
signed package. That version still distorted the controlled tone and is superseded.

Previous Host1.1.011/012 artifact provenance remains in the immutable package
catalog. These packages are superseded by the installed1.1.014 candidate.

Signed [Host run36061559638](https://github.com/instinctual/plank/actions/runs/36061559638)
and [Client run36061563286](https://github.com/instinctual/plank/actions/runs/36061563286)
pass the full builds, tests, signing, notarization and package gates.
[Corrected run36062636492](https://github.com/instinctual/plank/actions/runs/36062636492)
passes all four product jobs, including Linux Host. The table below retains
the1.1.010 packages, including the currently installed Ubuntu Client.
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
subsequently updated to 1.1.014. The Mac Client installer remains staged.
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

The last instrumented baseline uses the authorized development Ubuntu Client
with the authorized office Mac Host test target. The newer home stereo report
does not identify its Host or package versions. Build Mac components/probes only on the dedicated
SDK27 development Mac or authorized hosted workers. The office Mac is test-only.
Machine addresses, accounts, deployment details and reports remain in private
notes outside Git; read their local README before machine work.

Host1.1.014's four installed components match its signed package. At that check,
the Ubuntu Client reported 1.1.010. Host 1.1.009's working output routing is retained;
initial audio recovery and remaining validation are described above.
The separate Mac Client1.1.005 display-mode fallback was installed and its
connection succeeded; do not restore the fatal missing-native-flag check.

Prior installed camera tests pass separate native H.264 delivery:317 frames at
1920x1080 over10.522s, and separate NV12:310 frames over10.307s, both with zero
invalid samples/application drops. The operator confirmed QuickTime, FaceTime
and Zoom capture. One simultaneous native-first/pixel-second run delivered only
14 pixel frames with241 drops; the new recovery fixture is not a substitute for
repeating that installed test. Other application formats may inherit an existing
pixel stream; automatic output does not guarantee native coded delivery.

The authorized installed-version, driver-clock, quiet-tone and40-second timing
checks are complete; all probes exited. Next: continue recurrence testing during ordinary use and repeat the website camera
permission/start/stop trigger with playback; do not use Host stack sampling.
Then qualify:

1. Manual default, mute/reopen and cleanup; controlled channel identity/crosstalk.
   Distinct stereo channels are operator-confirmed on the home setup above.
2. Native-first/pixel-second and reverse-order concurrent readers for sustained delivery.
3. Combined camera/microphone lip sync, timestamp mapping through load/loss, unplug/reopen
   and reconnect; native payload preservation remains required.
4. Output restoration on disconnect/crash/unplug, manual override, local physical
   playback and remote volume/mute. The working-session report does not qualify
   these unobserved transitions.

All diagnostic readers/probes are stopped. General Linux color/input/Wacom,
network, privacy and production gates in
[acceptance criteria](docs/development/acceptance-criteria.md) remain unchanged.
