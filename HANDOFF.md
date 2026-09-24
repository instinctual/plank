# PLANK handoff

## Current task: native media forwarding investigation

The operator requested preserving webcam/microphone native media output through
transport without Client transcoding and explicitly requested a new branch.
Native does not mean uncompressed.

Branch: `native-media-investigation`, isolated worktree
`build/worktrees/native-media-investigation`. Original runtime base:
`af71d2b404486a9846bca464ddd646b5ab9c738a` from `microphone-forwarding`.
Synchronized with main `acb29884bff626c9381169fd94563ec79555984c`.
Its runtime/package source remains `a4ea39eb6fd0c098ebe01e6eb516747b84c71800`;
the latest main commit changes only package-validation documentation.
The investigation checkpoint is `c12504c`; only this handoff required merge
resolution. Main's version, release notes, build runbook, packaging tests and
Client gitlink are retained. The separate startup-fix worktree, main worktree
and primary RK3576 research are untouched.

The current base product version is **1.1.001**; this branch's candidate version
is **1.1.001-native-media-investigation**. Preserve the padded patch component.
Main already contains the accepted microphone and post-reboot certificate
startup repairs. The new Client pin changes only its changelog. No release,
package build or deployment has been performed by this synchronization.
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
occurred in this investigation.

Synchronization validation passes: all 62 CI-policy tests, seven package
collection tests, main/feature release-version contracts, both microphone wire
and queue unit tests, and the encrypted microphone FFI test (direct and setup
entry points, mute/reopen/generation/bounds). The portable microphone buffer
stress test passes one million samples with two readers, bounds, silence and
reset checks. These are Linux debug/portable checks, not native Mac camera,
Core Audio, hardware or release-performance qualification. The default-feature
Rust build emits two existing unused-telemetry warnings in vendored Quinn.
The follow-up main merge changes documentation only; runtime sources and pins
match the tested synchronization, so these test results remain applicable.
Documentation whitespace/reference checks and commit privacy hooks pass.

Maintained gitlinks after synchronization:

| Input | Commit |
| --- | --- |
| Shared Client | `cc511584c41c337569a1efd559a7c3362283d9cc` |
| Kymux | `3f7a9d8618978287186e5d6ce0eaa067743cb06c` |
| Linux Host | `5829bf7c335440a8b25c3330643eacb4d914f00a` |

Prior package provenance and recursive pins remain in main's linked HANDOFF.
No native-media candidate exists. Kymux is initialized at its exact pin from the verified
local repository for transport tests. Client and Linux Host are uninitialized
here; comparison against the retained Client repository confirms that its pin
update changes only the changelog.
