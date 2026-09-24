# PLANK handoff

## Current task: native camera forwarding and stereo microphone implementation

The operator requested preserving webcam/microphone native media output through
transport without Client transcoding and explicitly requested a new branch.
Native does not mean uncompressed. After live capture confirmed the camera's
native formats, the operator chose stereo Opus at 192 kbps, constrained VBR,
audio application mode and 10 ms packets for microphone forwarding. This
supersedes native PCM/mSBC preservation as the microphone implementation goal.
They explicitly approved proceeding with all implementation/test work and
confirmed that the Mac virtual microphone must expose 48 kHz stereo.
See [the implementation plan](docs/development/plans/native-media-forwarding.plan).

Branch: `native-media-investigation`, isolated worktree
`build/worktrees/native-media-investigation`. Original runtime base:
`af71d2b404486a9846bca464ddd646b5ab9c738a` from `microphone-forwarding`.
Synchronized with main `acb29884bff626c9381169fd94563ec79555984c`.
Its runtime/package source remains `a4ea39eb6fd0c098ebe01e6eb516747b84c71800`;
the latest main commit changes only package-validation documentation.
The initial investigation checkpoint is `c12504c`; only this handoff required
merge resolution. The investigation commits add synthetic camera probes and measured
application-delivery results; the current implementation adds stereo audio. Main's version, release notes, build runbook, packaging tests and
Client gitlink are retained. The separate startup-fix worktree, main worktree
and primary RK3576 research are untouched.

The operator authorized independent per-feature schemas and compatibility with
older peers after a schema 4 Client could not connect to the schema 5 Host.
The installed Host candidate is **1.1.004-native-media-investigation**. Implementation
adds authenticated feature negotiation, launch 7 and exact schema 4/5/6 adapters.
Schema4 disables its incompatible mono microphone; schemas5/6 retain stereo
microphone, and camera requires schema 6/7. New Clients bridge only known older
Hosts after pinned HTTP404; authentication/TLS failures never trigger fallback.
See [the contract](protocol/media-feature-negotiation.md) and
[release notes](docs/releases/1.1.004.md). Compatibility checks pass at runtime source
`c42252ba` with Client `04c307dd`: Ubuntu: 225 launch checks, 291 optional-service
checks and 33 real Qt/TLS scenarios; Mac: 45 feature checks, 744 session checks
across 24 scenarios and real HTTPS/QUIC launches for schemas 4/5/6/7. TLS/auth
failure, redirects, malformed replies and unknown older versions do not trigger
fallback. These are synthetic component/session results, not installed acceptance. The operator installed the signed 1.1.004 Host. Installed Host, camera extension
and microphone driver hashes match the package, and both Host roles restarted.
The production camera extension is activated and enabled. The older macOS
Client still returns to bookmarks after desktop preparation; installed backward
compatibility acceptance is therefore **not passed**. Client diagnostics identify
a separate display-discovery failure before stream launch: the OS mode list has
no native flag, although the current backing-pixel mode is valid. The fatal check
was added in Client `a5ad0e94` on September 15 and is already present in1.0.156.
Prior successful connections do not establish which display modes were reported
then; do not attribute the changed result to a specific OS/driver update without
evidence. The installed1.1.005 Client uses current backing pixels when the native
flag is absent and shows an error if display discovery really fails. Host1.1.004
remains installed. Ubuntu Client remains on1.1.002. Never install superseded1.1.003.

Camera integration includes Ubuntu device selection and toolbar activation,
session-bound Host reception, root-brokered fresh shared mappings and a CMIO
extension with native/NV12 output. Camera starts off on every connection,
including reconnects. A missing selected camera fails without choosing another
device. Optional camera failure leaves other session media available.

The Mac extension publishes immutable formats only after its first validated
native sample. Root verifies the signed extension and current registered
worker; the consumer verifies root and keeps admission independent of producer
memory. One media job may be outstanding; revocation removes the device and
rejects old completions. Three atomic shared slots bound copying and age.
Codec failure expires the producer, and camera-off/reopen uses new memory.
The build now embeds/signs the extension, validates the containing Host profile,
and provides explicit enable/disable setup. Uninstall refuses to remove the
containing app until OS extension removal is complete.

Validation for this integration: Ubuntu camera actor sanitizer tests pass
off-by-default, acknowledgement gating, stale acknowledgement, cancellation and
missing-device behavior. Shared C camera controls and the typed launch contract
pass, including 167 Ubuntu launch checks. Mac SDK27 compilation of IPC, producer,
activation and extension passes; shared-buffer and native sample/output
sanitizer tests pass. The headless CMIO source lifecycle test also passes
native-format publication, fixed formats, stale generation and revocation before
a queued media completion; it does not activate an OS extension or exercise
root admission. Portable packaging lifecycle/profile/permission tests and
62 CI policy tests pass. An earlier run on the dedicated Mac was at LoginWindow,
where the broader session fixture could not obtain a WindowServer event source.
The hosted Mac fixture passes 744 checks
across 24 scenarios at the exact candidate source below; this resolves the
fixture gate without claiming installed camera application acceptance.

Candidate source is `803383b588f1c56606cc0f7fdc7103c5c215f602`, Client
`79ebab378eda15419b07a324c2df17bd1411f890`. Hosted run
[`35966387798`](https://github.com/instinctual/plank/actions/runs/35966387798)
passes all four product jobs: both Linux packages and both unsigned Mac builds,
including camera lifecycle/sample tests and the full Mac authentication/session
fixtures. Initial source 82fb419 found stale schema 5 HTTPS/Client fixtures; those
are corrected in the passing candidate.

Both Linux packages are checksum/provenance-verified and collected under
`artifacts/packages/candidates/1.1.003-native-media-investigation/`:

| Candidate package | SHA-256 |
| --- | --- |
| Ubuntu Client DEB | `1f3207e4404c2ce27b4e10d4618013c188a3b082d999db1a7c716bb027df29cc` |
| Linux Host RPM | `3ad58a8f124991cd1a30300a424ee31135aab9e4b93f7860f224e6f9c98e097f` |

Signed Host run 35968724357 and signed Client run 35969255868 both pass at
`5e84977c51e71a66f0e8dd084717a81da2242830` (runtime identical to 803383b).
The signed Host PKG SHA-256 is
`04f4d5d6fb9ea14ac51fec2c501e931a269d135d3f6195d9075ddb30279cc5a3`.
It is collected and staged. The signed Client DMG is collected with SHA-256
`c20368813ae59675d00a3fe7e63ec159c1dd91606d94b598ba31f0ef5341b9cf`.
These 1.1.003 packages were not installed. Preserve them as the 1.1.003 checkpoint;
do not relabel them as 1.1.004.

The operator supplied a new Developer ID profile for `la.instinctual.PLANK.Host`.
Its exact app/team, existing application signing certificate, expiration and
system-extension installation permission pass validation. The protected
`macos-signing` environment now contains `PLANK_MACOS_HOST_PROVISION_PROFILE`;
the signing job consumes and removes its temporary decoded copy. Existing
notarization credentials are unchanged. No profile or credentials were committed.
Signed Host packaging and production extension activation pass for1.1.004.
Installed broker/extension admission and application delivery,
concurrent readers, sustained/loss/unplug testing and A/V synchronization remain
required. Presentation currently uses arrival in the Core Media Host clock;
Client capture timestamps survive PCAM, but no lip-sync claim is justified.

Signed 1.1.004 packages at the exact source below are collected and transferred,
with SHA-256, signatures and stapled tickets verified. Host bundle/extension/HAL
signatures, camera installation entitlement and Gatekeeper also pass on the target.

| Package | Run | SHA-256 |
| --- | --- | --- |
| macOS Host PKG |35972375915|`c5e42d96364b0cdfa244e9a3b11a11c8e2d5107497d231e4cb781cf118017769`|
| macOS Client DMG |35972378850|`22c05bc51f4c4a1c52d726b0c8b0002287685dd35a82fa73abb47cbf5593f614`|

The Mac Client DMG is staged but not installed. Hosted run35972351358 passes
all four product jobs. Both Linux packages are collected with verified source
provenance: Client DEB SHA-256
`db83bd8ad0a39a522aecf1886db0f53af4b0599f20227aba96925ddb979aa895`
and Host RPM SHA-256
`8db77a73a0d0d627f91c7a9753e2df795e89f861628b0e708752b62408d8e2a6`.
The focused1.1.005 display regression passes on the dedicated SDK27 Mac with
AddressSanitizer and UndefinedBehaviorSanitizer, including absent native flags,
empty/unavailable mode lists, invalid dimensions and native/current ownership.
The seven fullscreen checks pass on both development platforms; 62 CI-policy
checks and release-version validation also pass. The signed Client build
[`35975769184`](https://github.com/instinctual/plank/actions/runs/35975769184)
passes at root `ad7f5ac0ce9bbcadb1cb68485f08cd85034059f1`, with Client
`b391c2795902227a33e04de56cc447ff1f0d2b32` and the other gitlinks unchanged.
The DMG SHA-256 is
`728d32821d1b1323c282abf38677cd1bb4738317fc6b9219b8f11c85b2ac7da3`.
It is collected and installed on the affected Mac Client. Signature, notarized
Gatekeeper assessment and installed binary hash pass; the executable SHA-256 is
`36d2845b13155845314c211d5a473311f4ed99be4c58f8185d943f72523f1560`.
The old Client is retained as a verified private archive. The new Client's real
startup log confirms current backing pixels are selected when the native flag
is absent. A full authenticated connection retry is still pending; this does
not establish installed session acceptance. Temporary signing permission is removed.

## Installed state and source provenance

The prior stereo Host and the still-installed Ubuntu Client are **1.1.002-native-media-investigation**,
from root `613765ba8e3b66f4b2e42685f1ed8230af2c8139` and Client
`398b05a01cf84a894b8935bb0eb9fce7c8a271ca`. Signed Host run 35952211994 and
all-product run 35952188885 passed. The Host PKG SHA-256 is
`12ac1eeabc056b64486a234fb9cdbd68030988b12c25b38255ac3a0ae372136d`;
the Client DEB SHA-256 is
`5244de6797f6cc4327c1426a6f9ea62eeaa23fe3840578d7ab788f856b098942`.
Their installed payloads were verified before the Host upgrade. After the earlier
operator reboot, Core Audio reported
PLANK Microphone as 48 kHz, two channels, Float32 and eight bytes per frame.
Installed-device stereo routing and physical application acceptance are pending.
The earlier synthetic extension was removed with approval. Enumeration now
confirms the production camera extension1.1.004 is activated and enabled.

Current compatibility package source:
`9a858832db135b0ff62891b1b2faa0af7c8fa660`.

| Input | Commit |
| --- | --- |
| Shared Client | `04c307dd59a1f70b2b1e63ec1cad9e25f1912850` |
| Client common-c | `060f6179f88343327b44d915007f1fb4cede71f1` |
| Kymux | `3f7a9d8618978287186e5d6ce0eaa067743cb06c` |
| Linux Host | `5829bf7c335440a8b25c3330643eacb4d914f00a` |

Root and Client are pushed to the feature branch. Linux Host is unchanged and
uninitialized in this worktree. No merge, tag or GitHub release is authorized.
The branch's temporary protected signing permission was removed after both signed
builds completed; main remains allowed. Prior mainline package provenance is
in [main's synchronized handoff](https://github.com/instinctual/plank/blob/acb29884bff626c9381169fd94563ec79555984c/HANDOFF.md).

## Native media evidence and remaining gates

Physical camera capture confirms native H.264 and MJPEG at 720p/1080p. H.264
is Baseline level 4.0, 8-bit 4:2:0; its startup driver sequence gap is conservatively
marked for recovery even when coded frame numbers remain continuous. MJPEG
measured approximately 30 fps. Later H.264 measured approximately 15 fps under
the camera's existing dynamic-frame-rate/auto-exposure policy; nominal 30 fps is
not a measured delivery guarantee. UVC camera-generated recovery keyframes
passed three of three requests below 140 ms. Prior device format and interval
were restored after capture; no persistent UVC control changes remain.

USB monitoring established the camera microphone's native S16LE stereo PCM at
32 kHz, with 96,000 frames in three seconds and no USB errors. No audio recording
was saved. PipeWire exposes converted float ports; preserving its API samples
would not prove hardware-original PCM preservation. The operator selected
192 kbps stereo Opus VBR instead. Encoder/decoder tone tests preserve independent
channels; the Mac virtual input has the matching 48 kHz stereo format.

Direct encrypted camera/audio probes pass on the normal PLANK UDP port without
firewall changes or tunnels. The final short test received 90 MJPEG and 84 H.264
frames; every received native payload matched its source hash and decoded to
NV12 on the Mac. VideoToolbox used hardware for H.264 and software for JPEG.
H.264 recovery used device keyframe requests. After allowing a complete
six-packet Client capture batch in the bounded microphone queue, all 411/428
microphone packets arrived in the two respective camera runs, with zero source
drops, transport timeouts or receiver gaps. Opus payload rates measured
192.34/192.80 kbps. Mute/reopen passed. The 100 ms stale-packet limit remains.
These are short component tests, not sustained performance or lip-sync acceptance.

Mac native sample validation checks bounds, dimensions, timestamps, generation
and sequence. H.264 Annex B framing becomes Core Media length prefixes without
changing NAL payload bytes; JPEG payloads remain unchanged. NV12 decoding is
created only when requested. Sanitizer tests cover malformed framing, false
dimensions, replay, output switching and keyframe recovery. The production
extension lifecycle fixture covers native-format publication, fixed formats,
stale generation and revocation before queued completion without OS activation.

The earlier signed standalone CMIO probe passed native compressed H.264 delivery
and NV12 application output, including simultaneous coded/pixel consumers in
both startup orders. It used synthetic repeated keyframes. AVFoundation may
choose pixel output automatically; native advertising does not force an app to
preserve H.264. Configuration selection and consumer adaptation need explicit
qualification. Its successful OS approval and subsequent removal do not approve
the production Host extension.

Required next steps: retry the installed1.1.005 Mac Client connection, then
exercise the matching Ubuntu Client's
physical camera/stereo microphone. Verify installed broker and
extension admission, native/pixel application delivery, concurrent readers,
sustained loss/keyframe recovery, unplug/reopen, cleanup and A/V synchronization.
Current presentation uses arrival in the Core Media Host clock. Client capture
timestamps survive transport, but there is no qualified lip-sync result.

Read [the investigation](docs/development/investigations/native-media-forwarding.md),
[probe procedure](docs/development/investigations/native-camera-probe.md),
[camera contract](protocol/camera.md) and [microphone contract](protocol/microphone.md).
Machine inventory, paths, captures and raw evidence stay in private notes/audits;
credentials remain in the OS Keychain or password manager. Do not copy them here.
