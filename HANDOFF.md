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
GitHub Release is authorized. Candidate version is **1.1.011-native-media-investigation** (Mac Host scheduling fix).

Host1.1.011 source is `b7c2b6fb57b5ab4d6233ba4554c1efb5e92b60b0`.
Implementation `04df97fe962d` and regression fixture `bd6e7a3e9e20` are committed;
the Client change below only adds release notes. No Client runtime update is
needed for this Host fix. Current inputs:

| Input | Commit |
| --- | --- |
| Client | `b5423392b312200a9ef4cac2da63d547338733f2` |
| Client common-c | `060f6179f88343327b44d915007f1fb4cede71f1` |
| Client qmdnsengine | `920c097ffa742e2968290f15d4dde6693aec02e5` |
| Kymux | `3f7a9d8618978287186e5d6ce0eaa067743cb06c` |
| Linux Host | `5829bf7c335440a8b25c3330643eacb4d914f00a` |

Root and Client are pushed. Package manifests retain per-product source provenance;
never relabel a signed package or rebuild different bytes into an existing catalog
entry. Temporary signing permission was removed after the Host1.1.011 job;
main-only signing policy is verified. No signing credentials were read, changed
or committed.

## Active audio/input regression

Host1.1.010 and Ubuntu Client1.1.010 are now installed. The operator reports
intermittent playback/alert crackles after opening camera and other apps, with
slow typing during the same episodes. They explicitly want the degraded session
preserved for investigation: do not restart, disable forwarding, close their
apps or install the candidate automatically.

The live Host log reports at least64 capture-ring overrun events and512 Opus
reanchors, including120–180ms source gaps. Two eight-second thread samples put
75.6% and74.2% of sampled serial media-queue time inside synchronous local
session/account OS queries. Audio sends, input delivery and reverse camera/mic
validation repeatedly call those queries on that shared queue. No network-only
or camera-decoder-only cause is claimed.

The fix refreshes graphical evidence every20ms on a separate observer and keeps
RPCs outside the snapshot/revocation lock. Media/input reads remain bounded by
250ms observation age measured from the beginning of the read. Expiry, changed
identity, service failure, resignation and sleep latch revocation; late success
cannot renew expired authority. Machine admission, leases, permissions and
capture topology checks remain independent. See the updated
[authentication boundary](docs/architecture/macos-authentication.md).

The dedicated SDK27 Mac passes216 lifecycle checks normally and under ASan/UBSan,
including1000 actual stream authorization/enqueue operations while an OS read
is deliberately blocked, immediate notification revocation and expiry both
with and without foreground polling. Full signed
[Host run36066019394](https://github.com/instinctual/plank/actions/runs/36066019394)
passes the full build/test/sign/notarization/package gates. Its installer is
staged and independently verified on the test target; installed recovery is
not yet tested. No current-session configuration or process was changed;
diagnostics remain private outside Git.

The operator subsequently asked to discuss a500ms refresh interval. The proposed
direction is event-triggered checks plus500ms reconciliation with a separate
strict expiry (possibly1s), after verifying notification coverage. This proposal
is not implemented:1.1.011 still uses20ms observation and250ms maximum age. The
machine coordinator independently checks its own admission/ownership boundary.

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

Host1.1.011 is collected at
`artifacts/packages/candidates/1.1.011-native-media-investigation/macos/plank-host_1.1.011-native-media-investigation_arm64.pkg`.
SHA-256: `4188d0b4bf9f4b33928af7f0115f0f3d04c89e3cdd0a9ce20c8a2f48173114a4`.
Its source is the exact root/Client pair above, signed run36066019394. The
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
also pass on the target. Host and Ubuntu Client1.1.010 are now installed;
the Mac Client installer remains staged. The active degraded session is preserved.
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

Host1.1.010's installed Host executable, microphone driver and output driver
hashes match its signed package. The active Ubuntu Client reports1.1.010.
Host 1.1.009's working output routing is retained, but the current 1.1.010 session has
the audio/input scheduling regression above.
The separate Mac Client1.1.005 display-mode fallback was installed and its
connection succeeded; do not restore the fatal missing-native-flag check.

Prior installed camera tests pass separate native H.264 delivery:317 frames at
1920x1080 over10.522s, and separate NV12:310 frames over10.307s, both with zero
invalid samples/application drops. The operator confirmed QuickTime, FaceTime
and Zoom capture. One simultaneous native-first/pixel-second run delivered only
14 pixel frames with241 drops; the new recovery fixture is not a substitute for
repeating that installed test. Other application formats may inherit an existing
pixel stream; automatic output does not guarantee native coded delivery.

Next: preserve the degraded session and settle the proposed500ms observation
policy. Host1.1.011 is ready in Downloads. The Host test target requires the
operator's administrator Installer interaction; wait for their decision to end
this diagnostic session. After installation,
repeat application startup and simultaneous camera/audio use, inspect audio
ring overruns and compare thread samples/input responsiveness. Then qualify:

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
