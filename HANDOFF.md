# PLANK handoff

## Current task: native media forwarding investigation

The operator requested preserving webcam/microphone native media output through
transport without Client transcoding and explicitly requested a new branch.
Native does not mean uncompressed.

Branch: `native-media-investigation`, isolated worktree
`build/worktrees/native-media-investigation`. Base root:
`af71d2b404486a9846bca464ddd646b5ab9c738a` from `microphone-forwarding`.
It includes the bounded macOS startup certificate timeout repair. The separate
startup-fix worktree and primary RK3576 research are untouched.

Read [the investigation](docs/development/investigations/native-media-forwarding.md)
for sources, preservation boundaries, integration constraints and probe gates.
API/code evidence supports device-native camera/audio payload forwarding.
Pilot device formats are enumerated; live preservation/compatibility remains
unverified. Camera: native H.264/MJPEG through 1080p30. The USB microphone
exposes S16_LE stereo at 16/24/32 kHz. Latest operator selection is Bluetooth
headphone playback only: A2DP SBC-XQ, internal 48 kHz stereo S16LE sink, with
headset microphone suspended. Effective/configured input is the USB camera
microphone, running at 32 kHz stereo S16LE and linked to PLANK's 48 kHz mono
float input. PLANK's 48 kHz stereo float playback is linked to the headphones.
Earlier headset-mode inventory confirmed mSBC with decoded 16 kHz mono S16LE
in both directions. No streams or device settings were changed by inventory.
All raw inventory and deployment details remain in protected private notes.

V4L2 distinguishes compressed and emulated formats. SDL can expose MJPG bytes
but can also convert requested formats. ALSA `hw:` avoids userspace PCM
conversions. Current Client microphone capture requests converted 48 kHz mono
float PCM and sends Opus; Mac virtual input is fixed at that PCM format.
New native format negotiation/validation and shared endpoint allocation need
product work. Audio FEC's minimum two repair symbols affect wire-rate estimates.
AVFoundation can request device-native compressed samples, but physical camera
driver support and compressed delivery through a Core Media I/O extension remain
unverified. Qualify application passthrough separately from decoded-frame output;
a physical USB connection does not guarantee that an application preserves H.264.
Target automatic format negotiation on one camera, preserving one native network
stream and decoding on the Mac only when needed. Verify where AVFoundation
decodes, and test simultaneous consumers with different format requirements;
the extension's active format is a stream property, not a per-client promise.

SSH key access and uncached passwordless sudo verification succeeded. Query-only
inventory is complete; privileged V4L2 metadata queries were needed because the
SSH account lacked camera-node access. No access policy was changed. The initial
SSH-user PipeWire query was not the desktop graph; read-only queries as the
active graphical user subsequently established the Bluetooth devices and routes.

Next: native H.264/MJPEG and USB stereo-PCM preservation probes, coordinated
around existing camera/audio use. For headset microphone support, separately
investigate encoded mSBC capture before PipeWire decoding and Host decoding;
ordinary capture exposes only decoded PCM and would not preserve that codec.
Do not take over the active Bluetooth transport. Target access details are only
in protected private notes; passwords stay in the password
manager. No package build/install, live capture or product-code change has
occurred in this investigation. Documentation whitespace/local links and a
targeted deployment-data check passed; no product tests were run for these
documentation-only edits.

Unchanged maintained gitlinks:

| Input | Commit |
| --- | --- |
| Shared Client | `8a9d10289bf1547c5cca8ff0dd6d53c3fbe51f14` |
| Kymux | `3f7a9d8618978287186e5d6ce0eaa067743cb06c` |
| Linux Host | `5829bf7c335440a8b25c3330643eacb4d914f00a` |

Prior package provenance and recursive pins remain in the base commit's HANDOFF.
No new candidate exists. Submodules are not initialized in this documentation
worktree; inspection used matching local maintained checkouts at these pins.
