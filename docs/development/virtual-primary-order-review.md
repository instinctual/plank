# Virtual monitor connector ordering — draft review

## Why this is separate

A headless Linux Host with `display.startup_layout = virtual` already accepts
two qualified virtual modes. In a live trial, GNOME reported the intended
right-hand primary, but Flame opened on the left because the first PLANK
connector (`DP-0`) stayed on the left. Reassigning that connector to the
client's primary side placed Flame's chooser on the intended screen. The
two-virtual-output route then worked, and Host layout readbacks matched the
pretrial state after normal disconnect. This is the workflow demonstrated by the
trial; it does not require changing physical outputs.

## Candidate behavior

This series is refreshed onto released 1.0.143 main and uses the existing
qualified virtual-mode allowlist. The Client discovers its primary display,
translates it into left/right desktop order, and sends `plankPrimaryOutput`
only when an authenticated virtual-startup Host advertises capability
`0x2000000`. Both
manual two-output and Match Client bookmarks use that ordering. Manual mode
sizes still come from the bookmark. Native two-screen presentation uses the
Host output sizes for its stream boundaries when Mac panel pixel sizes differ.

The Host accepts only an in-range negotiated index. It checks both XRandR's
primary flag and whether `DP-0` is on that side. Live and GDM transitions
assign `DP-0` accordingly; topology reports virtual modes in left/right order
even when connector enumeration changes. Old Clients omit the index and keep
the existing DP-0-left behavior. New Clients omit it for old or physical-startup
Hosts. The private worker-to-supervisor display record advances from
`SC-DISPLAY-3` to `SC-DISPLAY-4`, so those binaries must ship together.

No physical-display helper, temporary mode lease, Retina size setting, codec,
input path, or administrator policy changes belong to this series. The
separate physical-display PRs were closed on 2026-09-19 after the virtual route
met the headless flame-01 workflow. Their branches and evidence remain parked
for later hybrid-workstation testing.

## Evidence and gates

On 2026-09-18, the preceding 1.0.137-based root, Host and Client pins passed the
[hosted build](https://github.com/cnoellert/plank/actions/runs/35382202995),
including Rocky Host, Ubuntu Client, SDK 27 Mac Client and Mac Host jobs. A
separate [SDK 27 development-bundle run](https://github.com/cnoellert/plank/actions/runs/35386142008)
used those same code pins and produced a locally signed Client with macOS 15.0
minimum. Bundle integrity, local signature and startup were verified on
Portofino (macOS 15.7.4). The exact Host RPM was installed on flame-01
(Rocky 9.5); the Host configuration and XRandR/NVIDIA layout were unchanged by
installation.

With the two-output manual bookmark, the signed Client completed workstation
sign-in and streamed a 4480×1440 canvas. XRandR showed 1920×1200 left on
DP-2 and 2560×1440 right and primary on DP-0. The operator confirmed both
fullscreen windows mapped to the intended Mac displays and Flame's project
chooser opened on the Eizo. After a normal disconnect, both outputs, their
positions and primary assignment remained the same, and mouse and stylus
buttons were released. An abrupt Client process exit also left that layout,
the Host services and released input state intact. The Host log recorded a
transport-loss error after the forced exit and an NvFBC release error on both
normal and forced disconnect; the services stayed active.

The Host already had DP-0 on the Eizo side before this installation, so the
first live session alone did not exercise connector reassignment. A subsequent
test closed the Client cleanly and temporarily reduced the Host to one
2560×1440 DP-0 output at +0+0. That state remained stable before reconnect.
The unchanged two-output bookmark then caused the Host to expand to a
4480×1440 canvas with DP-2 at 1920×1200+0+0 and DP-0 primary at
2560×1440+1920+0; NVIDIA's MetaMode agreed. The signed Client connected and
streamed that full canvas. This exercises the live single-to-dual connector
transition. The operator also confirmed a fresh connection after the earlier
forced exit. After unlocking the desktop, the operator confirmed Flame's
project chooser opened on the Eizo. No project was opened. After a normal
disconnect, XRandR and NVIDIA still reported the same 4480×1440 layout,
DP-2 left and DP-0 right and primary. The Host and PAM services remained
active, and mouse and stylus buttons were released.

The previous paired development build passed a single-to-dual reconnect on
the headless hardware-test Host. The operator confirmed that Flame opened on
the intended primary screen, and NVIDIA, XRandR and GNOME readbacks matched
the original virtual layout after normal disconnect. That live result is
historical evidence from the earlier combined build; it does not qualify this
newly isolated source.

After an X server restart during tablet hotplug, a later Flame launch put both
its chooser and main UI on the left output despite XRandR marking the right
output primary. Flame's application log recorded its main UI at `0,240` on
`1920×1200` and its alternate UI at `1920,0` on `2560×1440`. A successful
pre-restart launch recorded those assignments in the opposite order. The
restarted NVIDIA MetaMode listed the left connector first; the earlier live
single-to-dual transition had listed the right, primary connector first.
Reordering only those MetaMode entries at runtime preserved both rectangles,
the XRandR primary and the Plank stream. On the next Flame launch, its log
placed the main UI at `1920,0` on `2560×1440` and the alternate UI at `0,240`
on `1920×1200`; the operator confirmed the chooser appeared on the intended
primary screen. The display helper now writes the primary connector first in
its boot MetaMode too. Its isolated Linux shell test passed. The exact-source
[hosted build](https://github.com/cnoellert/plank/actions/runs/35402337659)
passed all four product jobs, and the checksum-verified Host RPM was installed
on the hardware-test Host. A clean reboot with that package first generated the
expected single-output login layout. After Match Client workstation sign-in,
the newly started user X server read a dual-output MetaMode listing the right,
primary connector first. NVIDIA and XRandR reported `DP-0` at
`2560×1440+1920+0` and `DP-2` at `1920×1200+0+0`; Xinerama head 0 was the
right output. Plank retried while the new X server started, reconnected
automatically after the GDM-to-desktop handoff on its fifth attempt, and
streamed the full `4480×1440` canvas. Flame's new application log
placed its main UI at `1920,0` on `2560×1440` and its alternate UI at `0,240`
on `1920×1200`. The operator confirmed the chooser appeared on the Eizo.
This qualifies persistence through a clean Host reboot and one authenticated
GDM-to-user handoff on this hardware.

The Client and Linux Host branches were then merged with their released
1.0.143 main branches, and the root integration was merged with 1.0.143 while
pinning those combined revisions. The subrepository merges were conflict-free:
the released Client contributes its absolute-coordinate edge correction and
the released Host contributes immediate Linux mouse-button delivery.

The first refreshed exact-source hosted build exposed an intermittent failure
in the Linux Host's existing progressive transport-loss test at 3% and 5%
loss. Rocky 9.7 diagnostics isolated the failure from the display changes.
Kernel UDP receive-buffer errors and Quinn outgoing-datagram evictions remained
zero, while failed observations ended with roughly one frame's datagrams not
yet forwarded and KyProto advanced past an incomplete frame. Larger Quinn send
and receive buffers, 512- and 1024-datagram minimum congestion windows, a
100 ms FEC ordering deadline and a 1 Gbps application pacer all reproduced a
skipped frame in the unchanged production test. A 12-run instrumented test
passed only after its receiver and timing behavior had changed, so it is not
acceptance evidence. [Root PR #11](https://github.com/instinctual/plank/pull/11)
remains a draft diagnostic record. Its unproven transport change has been
removed from this display integration; this candidate uses the released
1.0.143 transport code.

The refreshed root head `686847f` then passed the complete
[upstream hosted build](https://github.com/instinctual/plank/actions/runs/35414725644):
policy, Rocky 9.7 Host, Ubuntu Client, SDK 27 Mac Client and SDK 27 Mac Host.
The fork's exact-head
[build](https://github.com/cnoellert/plank/actions/runs/35414723019) passed the
same jobs on its unchanged second attempt after the existing loss test skipped
one frame on the first. The locally signed macOS 15
[development-bundle run](https://github.com/cnoellert/plank/actions/runs/35414858597)
used that root head and the same Client `eea44a2` and Host `c927e2b` pins. Its
packaging gate checked 106 product Mach-O deployment targets, its archive hash
matched the manifest, and the extracted app passed strict deep signature
verification with the operator's Developer ID identity. It remains an
unnotarized local test build.

The upstream Host artifact targeted Rocky 9.7 and recorded the tested PR merge
commit `485d3b8`, whose second parent is exact root head `686847f`. Its manifest
pins Client `eea44a2`, Host `c927e2b` and released Kymux `6f3df8e`. The RPM's
SHA-256 was `88ed093b95364864acd7bba320100ef9edcc681cab41c5a9c02cdcf7ef9250b8`.
It was installed on flame-01 after that workstation was upgraded to Rocky 9.7.
The existing Host configuration checksum was unchanged, both Host services
restarted active and enabled, and the pre-session GDM layout remained one
1920x1080 primary DP-0 output.

From that single-output login state, the exact signed Client authenticated with
Match Client displays. The user X server came up as a 4480x1440 canvas with
1920x1200 DP-2 on the left and primary 2560x1440 DP-0 on the right. NVIDIA's
MetaMode listed the primary DPY-0 first. The stream negotiated 4480x1440 at
60 Hz, 50 Mbps. The operator confirmed both Mac windows and Flame placement.
Flame 2026.2.1 independently logged `Main UI position:1920,0 size:2560x1440`
and `Alt UI position:0,240 size:1920x1200`, placing its main UI on the Eizo.

An XInput trace of the exact session recorded the stylus across root X
coordinates 466 through 3875, covering both outputs. It recorded 11 matched
tip press/release pairs, two matched side-button press/release pairs, and
pressure from 0 through 59,413. The operator confirmed pointer placement,
clicks and visible pressure response. Mouse and stylus buttons all read up
afterward. During a subsequent Portofino sleep/wake, the Host reused the stable
raw-HID endpoints as generation 8. The operator confirmed the session resumed;
90 Host-side samples retained the same canvas, positions and primary output,
and both Host services and released input state remained healthy.

A final normal Client disconnect removed the authenticated PLANK login while
retaining the exact 4480x1440 XRandR and NVIDIA layout. Both Host services
remained active, Flame was closed, and all mouse and stylus buttons read up.
The transport summary recorded zero QUIC packet loss, zero KyProto drops and
zero audio or video send-queue drops. After explicitly recording the Client's
clean-disconnect request, the Host still emitted the previously observed
nonfatal NvFBC context-release and native-endpoint-ended messages; asynchronous
encoder teardown completed. That shutdown log noise remains visible rather
than being treated as a clean diagnostic result.

The refreshed source is therefore qualified on Portofino macOS 15.7.4 against
flame-01 Rocky 9.7 for display ordering, Flame placement, Wacom input and
sleep/reconnect. The same Client package still needs live macOS 27 acceptance.
Unavailable macOS 27 hardware is an open gate, not a passed test.
