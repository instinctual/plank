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

The synchronized base product version is **1.1.001**; the stereo test candidate
is **1.1.002-native-media-investigation**. Preserve the padded patch component.
Main already contains the accepted microphone and post-reboot certificate
startup repairs. The synchronized Client base changed only its changelog. The current stereo
work updates that Client. Stereo test packages are recorded below; live
deployment and product camera integration remain pending.
See [coordinated upgrade notes](docs/releases/1.1.001.md).

Mainline **1.1.001** test packages are built and checksum/provenance-verified
from exact root `a4ea39eb6fd0c098ebe01e6eb516747b84c71800`. Hosted runs:
Linux Host `35940461297`, Ubuntu Client `35940463873`, signed Mac Host
`35940466159`, signed Mac Client `35940468319`. All four passed first attempt.
They are retained in `artifacts/packages/releases/1.1.001/`; that catalog name
does not mean publication. No installation, tag or GitHub release was performed
by the package task. Matching Host/Client manual installation and live hardware
acceptance, including post-reboot Mac startup, remain pending.

| Mainline package | SHA-256 |
| --- | --- |
| Linux Host RPM | `83999138c18b78001d4f503000b56faf34245b4635f676eb13a72814d3c163e1` |
| Ubuntu Client DEB | `35b2c031cceb923cd0cccb5830c566eff15237bd545c90a04b00d71f035f02bf` |
| macOS Host PKG | `6111c9ea85849813ddb6ce1d5a62e17b1e5c0428d28fa3d92932791b32ee351c` |
| macOS Client DMG | `95dbd029e1665b0fde2b64fbff86e84968577318fbb9147fa7af7e3de4fe7685` |

Detailed package provenance, recursive pins and qualification results remain in
[main's handoff at the synchronization point](https://github.com/instinctual/plank/blob/acb29884bff626c9381169fd94563ec79555984c/HANDOFF.md).
These packages do not contain native-media work. Do not relabel them as feature
candidates or mix their RaptorQ-2 transport with pre-upgrade published peers.

Stereo candidate **1.1.002-native-media-investigation** is built from exact root
`613765ba8e3b66f4b2e42685f1ed8230af2c8139`, Client
`398b05a0` (full pin in the table below). Signed Mac Host run `35952211994`
passes build/tests/signing/notarization/stapling. All four product jobs pass in
hosted run `35952188885` (Mac jobs unsigned). Packages are collected with original provenance in
`artifacts/packages/candidates/1.1.002-native-media-investigation/`.

| Stereo candidate | SHA-256 |
| --- | --- |
| Mac Host PKG | `12ac1eeabc056b64486a234fb9cdbd68030988b12c25b38255ac3a0ae372136d` |
| Ubuntu Client DEB | `5244de6797f6cc4327c1426a6f9ea62eeaa23fe3840578d7ab788f856b098942` |

Both candidates are installed on their authorized development targets. The
operator completed the signed Mac installer and rebooted. Host and HAL binaries
match the signed package payload; the machine service is running. Core Audio
reports the loaded production input as 48 kHz, two channels, 32-bit float and
eight bytes per frame. The matching Ubuntu package and installed executable
hashes/version pass; it contains no service or autostart entry. The Client is
open for operator authentication. Live stereo routing, mute/reopen and physical
audio acceptance remain pending; format discovery alone does not qualify them.
The operator is away and cannot provide interactive help. Continue unattended
component/network work on the authorized targets; do not wait for that login.
No tag, merge or release is published. Exact feature-branch signing permission
is temporary; remove it when signed builds for this task are finished.

The subsequent camera transport prototype is **not in those package bytes**.
PCAM v1 has shared C/Rust bounds and a fixed synthetic wire vector, explicit
camera-only versus microphone-plus-camera endpoint allocation, two/three-frame
queues, activation isolation and H.264 keyframe recovery. Portable wire and
queue tests pass; encrypted Rust C-ABI tests pass all four allocation/setup
combinations with byte-identical synthetic payloads and mute/reopen. The
microphone encrypted regression still passes after allocation coordination.
Product camera capture/negotiation/UI/Host extension integration is not enabled.
The subsequent direct V4L2 capture component passes sanitizer tests on the
authorized Client builder: unchanged payload copy, malformed framing, native
mode requirements, coerced/busy-device rejection and partial-resource cleanup.
Live execution as the existing graphical user passes 90 MJPEG and 90 H.264
buffers at 720p, with restoration of the exact prior format/interval and no
saved images. Descriptor-verified UVC H.264 IDR/SPS/PPS requests pass three of
three recoveries below 140 ms. No encoder, persistent UVC mapping, bitrate or
exposure-control change is involved. Later capture measured approximately 15 fps
with dynamic frame rate enabled by the device's existing auto-exposure policy;
do not present nominal 30 fps as measured delivery. The H.264 startup driver
sequence gap remains and is conservatively marked for recovery. Product capture
activation, native network delivery and extension integration remain pending.
Full Linux/Mac lifecycle/performance gates for this new lane remain required.
See [the camera contract](protocol/camera.md).

Read [the investigation](docs/development/investigations/native-media-forwarding.md)
for sources, preservation boundaries, integration constraints and probe gates.
API/code evidence supports device-native camera/audio payload forwarding.
Pilot device formats and H.264 extension controls are enumerated; PLANK network
preservation and physical-input Mac compatibility remain unverified. Camera:
native H.264/MJPEG through
1080p30. Read-only extension-unit queries advertise picture-type, bitrate,
frame-rate and configuration controls. No extension-control writes were made;
the subsequent operator-authorized captures are recorded below. The USB microphone
exposes S16_LE stereo at 16/24/32 kHz. Latest operator selection is Bluetooth
headphone playback only: A2DP SBC-XQ, internal 48 kHz stereo S16LE sink, with
headset microphone suspended. Effective/configured input is the USB camera
microphone, running at 32 kHz stereo S16LE and linked to PLANK's 48 kHz mono
float input. PLANK's 48 kHz stereo float playback is linked to the headphones.
Earlier headset-mode inventory confirmed mSBC with decoded 16 kHz mono S16LE
in both directions. No streams or device settings were changed by inventory.
All raw inventory and deployment details remain in protected private notes.

The hardware-facing USB microphone format is S16LE/32 kHz/stereo, but its
PipeWire adapter exposes float DSP ports and does not advertise passthrough
port configuration. Disabling conversion only on PLANK's stream cannot prove
original PCM preservation. The ALSA reference query refused a busy capture
device; audio-server ownership and user routing remain unchanged.

V4L2 distinguishes compressed and emulated formats. SDL can expose MJPG bytes
but can also convert requested formats. ALSA `hw:` avoids userspace PCM
conversions. The measured baseline Client requested converted 48 kHz mono
float PCM and sent 64 kbps Opus; its Mac virtual input was fixed to mono.
The current stereo changes below supersede that baseline.
New native format negotiation/validation and shared endpoint allocation need
product work. Audio FEC's minimum two repair symbols affect wire-rate estimates.
AVFoundation can request device-native compressed samples. Synthetic H.264
delivery through a Core Media I/O extension now passes; physical camera driver
support and third-party applications remain unverified. Qualify application
passthrough separately from decoded-frame output;
a physical USB connection does not guarantee that an application preserves H.264.
Target automatic format negotiation on one camera, preserving one native network
stream and decoding on the Mac only when needed. The synthetic test demonstrates
AVFoundation decoding and simultaneous consumers with different output formats;
the extension's active format is a stream property, not a per-client promise.

SSH key access and uncached passwordless sudo verification succeeded. Query-only
inventory is complete; privileged V4L2 metadata queries were needed because the
SSH account lacked camera-node access. No access policy was changed. The initial
SSH-user PipeWire query was not the desktop graph; read-only queries as the
active graphical user subsequently established the Bluetooth devices and routes.

The synthetic Mac format probe passes native compilation with warnings as
errors, H.264/NV12/BGRA/JPEG format construction, and H.264-to-NV12 decode at
320x240. Generic keyed archiving fails for all four formats and is inconclusive
for extension IPC. The standalone camera extension and consumer compile and
pass strict certificate signing with a matching system-extension installation
profile. Xcode export must retain the required entitlement and embed its
authorizing profile. Notarization, stapling, strict signature, Gatekeeper,
operator-approved extension activation and camera consent all pass.

The application-delivery matrix passes unchanged H.264 and decoded NV12 through
one camera. Explicit H.264 selection needs the macOS configuration lock through
capture; releasing it before startup allowed AVFoundation to choose NV12.
Thirty coded frames match the extension's source hash. A pixel consumer receives
NV12 while the source stays H.264 and the extension performs no decoding,
establishing framework-side adaptation. Explicit NV12 and automatic pixel output
also pass. Native output with automatic source selection receives NV12, so
advertising H.264 does not force every app to select it.

Mixed readers pass in both startup orders: 180 coded plus 90 pixel frames with
2.91 seconds overlap, and 180 pixel plus 90 coded frames with 2.97 seconds
overlap. The reverse-order pixel run spans 7.28 seconds versus 5.97 nominal;
seamless switching and sustained rate remain unqualified. Invalid frame bounds
are rejected. These are repeated synthetic keyframes, not a physical webcam,
network, motion/color, hardware-decoder or lip-sync qualification. No product
camera capability has been added. Operator-approved deactivation completed;
the temporary app is removed and probe GUI jobs are unloaded. The extension is
inactive. After the operator's ordinary reboot, system-extension enumeration
confirms that its registration is absent.
Deployment paths, signed artifacts and raw evidence stay in private notes/audits.
See [the probe procedure](docs/development/investigations/native-camera-probe.md).

Physical capture now confirms 90 native H.264 and 90 MJPEG buffers at each of
720p and 1080p, with no error-flagged buffers. H.264 headers describe Baseline
level 4.0, 8-bit 4:2:0 with matching dimensions. Both H.264 runs skip V4L2 sequence 1
at startup, but encoded frame numbers remain continuous; do not equate that with
a lost coded picture. The strict no-sequence-gap criterion remains failed.
MJPEG delivers approximately 30 fps with no sequence gaps. This proves bounded
native capture/header validity. The subsequent private Mac decode below passes;
color and sustained performance remain unqualified.

An endpoint-filtered USB monitor observed the existing microphone stream before
PipeWire conversion: 3,000 successful 128-byte completions in three seconds,
96,000 stereo S16LE frames at 32 kHz, with no errors, truncation or monitor drops.
USB descriptors identify PCM, Type I, two-byte samples and 16 significant bits.
No audio file was saved. The video device is closed, its prior format/interval
restored, the monitor module unloaded, and the existing microphone process,
parameters and running state unchanged. Raw evidence and video samples remain
private. No existing capture owner was displaced and no package was installed.

Current stereo implementation: the Client requests 48 kHz interleaved stereo,
encodes 192 kbps constrained-VBR Opus in audio mode with forced stereo signaling,
and keeps 10 ms packets. PMIC version 2 and authenticated launch schema 5 reject
old mono peers. The Mac decoder, producer, drift adaptation, shared-buffer
version 2 and HAL device all use two channels. Device availability checks the
loaded stereo format, preventing advertisement of a still-loaded mono driver.

Validation passes on the authorized Ubuntu Client builder (Qt 6.10.2,
SDL 3.4.2, Opus 1.6.1): dummy capture/mute/backpressure/reopen/failure cleanup,
152 launch checks including old-schema rejection, and 300 synthetic stereo Opus
packets. The fixture measured 193.44 kbps payload at a 192 kbps VBR target.
On the authorized macOS 27/SDK27 development Mac: buffer stress (one million
frames, two readers), HAL property/clock/multireader/silence tests, native Opus
silence/reset/bounds, format/selection tests and all non-installing microphone
probe builds pass with warnings as errors. Apple's decoder preserved the two
independent tones from the Ubuntu encoder (left amplitude 0.062822, right
0.031340, cross-tone amplitude below 0.000018). This qualifies component channel
separation, not installed audio routing, microphone fidelity or lip sync.
The encrypted microphone FFI mute/reopen/generation/bounds test passes locally.

Physical Mac decode now passes all 360 captured frames (90 each of H.264 and
MJPEG at 720p/1080p). VideoToolbox reports hardware acceleration for H.264 and
software decoding for JPEG; output is matching-size NV12. H.264 NAL payloads
are unchanged while Annex B framing is adapted to Core Media length prefixes.
No Client encoder or new device capture was used. This is decode qualification,
not color, sustained timing, network preservation or application acceptance.

Next: finish stereo live session and installed-device audio testing;
implement native camera capture/transport
and authenticated extension production. Clock-drift/loss and real application
acceptance remain required. USB monitoring is a diagnostic reference, not
product capture. The selected microphone implementation is Opus; native PCM or
Bluetooth mSBC preservation is no longer an implementation gate. Capture/test
coordination and deployment details stay in private notes; credentials remain
in the OS Keychain/password manager. The stereo candidates above are installed.

Synchronization validation passes: all 62 CI-policy tests, seven package
collection tests, main/feature release-version contracts, both microphone wire
and queue unit tests, and the encrypted microphone FFI test (direct and setup
entry points, mute/reopen/generation/bounds). The portable microphone buffer
stress test passes one million samples with two readers, bounds, silence and
reset checks. These are Linux debug/portable checks, separate from the synthetic
Mac probe results above; neither constitutes live camera, Core Audio, hardware
or release-performance qualification. The default-feature
Rust build emits two existing unused-telemetry warnings in vendored Quinn.
The follow-up main merge changes documentation only; runtime sources and pins
match the tested synchronization, so these test results remain applicable.
Documentation whitespace/reference checks and commit privacy hooks pass.

Current maintained gitlinks:

| Input | Commit |
| --- | --- |
| Shared Client | `bfea688c287b0698123ea0fdf29aeaf21950290b` |
| Kymux | `3f7a9d8618978287186e5d6ce0eaa067743cb06c` |
| Linux Host | `5829bf7c335440a8b25c3330643eacb4d914f00a` |

Prior package provenance and recursive pins remain in main's linked HANDOFF.
The stereo-only candidate above does not contain product camera support.
Kymux is initialized at its exact pin from the verified
local repository for transport tests. Client is initialized on the matching feature branch for stereo implementation.
Linux Host remains uninitialized and unchanged.
