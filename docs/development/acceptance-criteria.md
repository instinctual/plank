# PLANK Linux Acceptance Criteria

## Purpose and authority

This document defines the stable acceptance gates for the supported PLANK
Linux product. It is intentionally a release checklist, not a development
history or an implementation plan.

- `AGENTS.md` defines repository policy, supported product scope, and build
  discipline.
- `protocol/` and the focused architecture/security documents define the exact
  current wire and subsystem contracts.
- This document defines the behavior and evidence required to accept a Linux
  release.
- `docs/development/build/release-build-runbook.md` defines the candidate build and validation
  procedure.
- `HANDOFF.md` records which gates have actually passed for the current source
  and artifacts, plus the next test.

A historical prototype result is not evidence for a new candidate. A hardware
gate passes only on the qualified target hardware with the exact candidate
package. Record unavailable or incomplete checks honestly.

## Supported product boundary

The initial supported deployment is:

- Rocky Linux 9.7 Host with a qualified NVIDIA GPU, proprietary NVIDIA Xorg
  stack, CUDA/NvFBC, and an active local `seat0` X11 session or GDM greeter;
- Ubuntu 26.04 Client on qualified Intel NUC-class hardware using the native
  Wayland, SDL3, Vulkan, PipeWire, and packaged FFmpeg path;
- one controlling remote client, with explicit same-account transfer to a
  replacement client; and

There are no deployed legacy PLANK versions. A candidate must not add silent
Sunshine/Moonlight compatibility paths or restore removed product features.

## Authentication and security

A candidate passes only when all of the following hold:

- Every fresh connection authenticates through `/etc/pam.d/plank-host` before
  topology, session, media, or input access is granted.
- Valid local and SSSD/FreeIPA identities succeed when permitted by PAM and
  HBAC. Invalid passwords and locked, expired, disabled, or externally denied
  accounts fail cleanly.
- Root login is denied by default. The root-owned
  `security.allow_root_login` override never bypasses PAM/SSSD/HBAC or active
  desktop ownership.
- A user session can be attached or transferred only by the account that owns
  the active desktop. Another account cannot view or control it.
- A second client receives an explicit active-session conflict. Takeover
  requires local confirmation, revokes the old input path first, preserves the
  Host desktop, and prevents the displaced Client from reconnecting
  automatically.
- Passwords, PAM responses, one-use tokens, certificate private keys, and raw
  tablet serials never appear in arguments, environment variables, URLs,
  persistent settings, diagnostics, or logs.
- TLS 1.3 and the PLANK certificate profile protect the control plane. Native
  QUIC uses the launch-provided certificate fingerprint and one-use session
  credentials. There is no pairing database or persistent trusted-client
  record.
- Malformed protocol records, unknown endpoints or feature bits, invalid or
  replayed tokens, expired launch state, certificate mismatch, and
  unauthenticated requests fail closed without leaking desktop contents,
  identity, or credentials. HTTPS `/serverinfo` may advertise a nameless
  `PlankOccupied` bit so other Clients can show `In Session`.
- The PAM broker socket, TLS private key, machine state, Host configuration,
  and persistent Host logs retain their documented root ownership and modes.
- PLANK does not decide whether an address is LAN, WAN, VPN, or approved.
  Deployment access control remains an administrator-owned firewall and
  routing responsibility.

Security validation includes success and failure paths, abrupt peer loss,
broker restart during authentication, queue exhaustion, and teardown while
input is active.

## Session and display lifecycle

The machine-level Host service must start at boot and select only an active
local X11 `seat0` user or greeter session. It must not assume a UID, display
number, Xauthority path, audio socket, or workstation-specific connector.

Acceptance requires:

- connection at GDM followed by the bounded transition into the authenticated
  desktop without an application hang or duplicate login workflow;
- same-account reconnect and explicit takeover without logging out the Host;
- rejection of a cross-account attachment;
- cleanup of the one-use launch reservation after success, failure, timeout,
  or disconnect;
- correct behavior across login, logout, lock/unlock, Host reboot, Xorg
  replacement, and Client process failure; and
- no orphaned PAM worker, transport session, virtual input device, display
  lease, or audio resource.

The topology contract in `protocol/output-topology.md` is authoritative.
Qualify physical, one-virtual-display, and two-horizontal-virtual-display
layouts at the supported mode combinations. Native presentation must preserve
one host pixel per client pixel. Scaled-Span must aspect-fit once, use explicit
letterbox geometry, and never rescale an already fitting canvas.

For a physical-display Host, a temporary remote layout must restore the exact
pre-session NVIDIA MetaMode. A forced exact-restore failure must leave one
validated physical output usable at a safe mode. Recovery must not reboot the
Host or restart an authenticated user's display manager.

For a headless Host, the packaged virtual display must support GDM, one- and
two-display login, reconnect, and resolution changes using only qualified
modes. A one-display request must not leave a second output active. Display
identity, generation, source rectangles, and virtual/physical provenance must
match what the Host actually applies.

An unexpected topology replacement must stop the stream, cancel active pen
contact, release held keys/buttons, suspend or detach virtual devices as
appropriate, and require fresh authentication. It must never continue using a
stale video or input transform.

## Video and color

The exact bookmark profile is a contract. The Host must acknowledge and
produce the same capture source, encoder backend, codec, bit depth, chroma
sampling, range, and color transform defined in
`protocol/encoding-profiles.md`. Silent substitution is a failure.

The qualified default is H.264 High 10 4:4:4 full-range identity GBR. Decoder
selection is internal and profile-specific: the Client validates a real
exact-format hardware test frame first, then uses the exact software decoder
for the same profile. If neither path preserves the requested tuple, the
connection fails clearly.

Every supported profile must pass:

- negotiation and acknowledgement tests for supported and deliberately
  unsupported tuples;
- capture-source reporting that labels NvFBC as an 8-bit source even when its
  encoder surface is expanded to 10-bit;
- the Experimental label and 10-bit-only profile restriction for Native
  X11/XShm capture;
- grayscale ramps, near-black/near-white values, saturated single-pixel colors,
  color charts, and representative moving Flame footage;
- full-range and identity-GBR metadata verification, including `Y=G`, `U=B`,
  `V=R`, and no YCbCr matrix for identity profiles;
- decoded pixel comparison at a lossless or suitably high-quality setting;
- correct cursor exclusion from captured frames and correct custom cursor
  shape, hotspot, visibility, and transitions on the Client;
- static, changing, scene-cut, and high-motion content at bookmark bitrates;
  and
- honest on-screen and log reporting of capture source, encoder, codec,
  precision, chroma, range, decoder, presentation path, dimensions, and frame
  rates.

At every advertised resolution, the complete capture, encode, transport,
decode, and presentation pipeline must sustain the requested 60 fps without
sustained queue growth. Capture, encode, network, decode, and render timing
must be measured separately. A static-frame result alone does not qualify a
profile.

## Native transport and network resilience

The only production data plane is native PlankTransport using KyProto/QUIC and
RaptorQ. The configured TCP control endpoint and UDP transport use the same
port number; the packaged default is `28989`. Legacy RTSP, RTP media sockets,
STUN, UPnP, and alternate data-plane switches must remain absent.

Both peers must negotiate and apply the same fixed complete QUIC UDP payload
ceiling before RaptorQ packetization begins. Automatic mode derives a
conservative value from the selected route; manual override remains available.
A missing, invalid, oversized, or mismatched value fails launch rather than
fragmenting silently.

Validate each accepted profile and representative bitrate at:

- zero loss;
- at least 0.5%, 1%, 2%, 5%, and 10% independently random Client-ingress
  packet loss;
- deterministic burst loss;
- reconnect after a temporary complete outage.

The 0.5% test must not cause visible corruption, progressive delay, or a frozen
stream. For higher-loss points, record source symbols, repair symbols,
pre-FEC loss, post-FEC loss, recovered objects, unrecoverable objects, QUIC
loss/RTT, queue high-water marks, and the first visible failure. Loss injection
must be removed and normal routing verified after every run.

Exercise bookmark and live-toolbar bitrate changes from 10 through 150 Mbps.
The active request, Host acknowledgement, encoder target, observed incoming
rate, and short-term peaks must remain distinguishable. Congestion or loss must
not create unbounded sender, QUIC, decoder, or presentation queues. Audio and
critical input must remain responsive while video is saturated.

The toolbar and on-screen statistics must derive shared values rather than
independent calculations. At minimum, validate network/decode/render frame
rates, capture and codec precision, encoder target, incoming video bitrate,
pre-/post-FEC video packet loss, network latency, queue drops, and timing.

## Keyboard, mouse, cursor, and toolbar

Acceptance includes:

- left/right modifiers, system shortcuts, NumLock state, keypad input, key
  repeat, and release of every held key at disconnect;
- absolute mouse positioning, left/middle/right buttons, dragging, and wheel
  scrolling across Native and Scaled-Span presentation;
- correct transforms with letterboxing, unequal Host/Client resolutions,
  fullscreen, borderless, decorated windowed mode, and dual-display layouts;
- a compositor-owned local mouse cursor with Host-provided custom shapes and a
  Host-authoritative visible cursor while Wacom owns pointer motion;
- no duplicate cursor, cursor warp, click offset, or drag-scale divergence;
  and
- a toolbar that reveals at the configured top-edge delay, auto-hides, pins,
  moves horizontally with live dragging, changes active bitrate, minimizes,
  toggles fullscreen where supported, and disconnects.

Toolbar input must be local and reliable at 100% and deliberately tested 125%
desktop scaling. Pointer events consumed by the toolbar must not reach the
remote desktop underneath it. The toolbar must remain usable while the Host is
unreachable or the stream is reconnecting.

## Wacom

The raw-HID contract and model fallback rules in `protocol/wacom-hid.md` are
authoritative. Qualify at least one current descriptor-driven Intuos Pro and
one first-generation PTH-x51 fallback device. Where practical, repeat with
different tablet sizes on the Host and Client.

Validate:

- proximity, hover, tip, pressure, tilt, distance, eraser, side buttons, tool
  identity, and physical axis geometry;
- supported pad controls, ring/strip, touch, feature reports, and output
  reports on raw-HID models;
- Tablet Margins, edge behavior, cursor image/position, and pen strokes in
  Autodesk Flame;
- one- and two-monitor layouts, unequal resolutions, Native and Scaled-Span,
  reconnect, focus loss/return, takeover, hot-unplug, and Flame restart;
- simultaneous presence of a physical Host tablet without duplicate local and
  remote input; and
- suspend/reattach without changing application-visible XInput identity when
  device identity and descriptors are unchanged.

Tip/button transitions must use the reliable ordered path. Hover motion may be
coalesced but must remain smooth under changing video load. Disconnect and
failure cleanup must leave no stuck tip, eraser, button, tool, grab, or UHID
device state.

## Audio and synchronization

The Client follows the operating system's selected output device. The Host
captures the selected authenticated desktop's audio without exposing another
user's stream. Stereo Opus at 48 kHz is the qualified baseline.

Acceptance requires:

- audible end-to-end delivery through the Client's default PipeWire sink;
- bounded decode, jitter, and output queues with zero decoded-block skips in a
  normal two-hour changing-content run;
- video-master correction with at most 20 ms accumulated relative drift and at
  most 20 ms/hour fitted drift after the documented warmup;
- a synchronized flash/tone test for absolute A/V offset and jitter;
- controlled packet-loss recovery without audible discontinuity within the
  qualified budget; and
- correct sink replacement and complete cleanup across login transitions,
  reconnect, takeover, disconnect, and Host session changes.

## Reliability and performance

Run, at minimum:

- repeated authenticate/connect/disconnect and immediate reconnect loops;
- GDM-to-desktop transition, same-user takeover, Host reboot, Client restart,
  display-server replacement, and temporary network outage;
- explicit Host-unreachable timeout behavior for both Ask and Disconnect
  policy;
- a 15-minute changing-content acceptance run for each release candidate; and
- an eight-hour representative session with moving video, audio, normal input,
  and periodic toolbar interaction.

During soaks, record Host and Client CPU/GPU use, RSS, queue depths, frame
rates, capture/encode/decode/render times, network RTT/loss, FEC recovery,
audio drift, and input responsiveness. RSS and queues must stabilize rather
than grow without bound. Input and toolbar operations must not wait behind a
video frame or media backlog.

Unexpected Host loss must leave the Client UI, local cursor, toolbar, and
disconnect controls responsive. Policy may automatically disconnect or show a
native Wait/Disconnect prompt after the configured timeout; it must not depend
on the desktop environment's force-quit dialog.

## Packaging and deployment

Build packages only on the dedicated builders and follow
`docs/development/build/release-build-runbook.md`. Install the exact hash-verified RPM and DEB on
their respective test targets; never rebuild on a test or End-User machine.

For both packages, verify:

- clean package assembly from exact root and recursive-submodule commits;
- manifest, ownership, permissions, runtime-library closure, license notices,
  and absence of unexpected files or network services;
- clean install, upgrade, rollback, and uninstall on fresh supported-OS
  images;
- preservation of administrator-owned conffiles during package operations;
  and
- removal of package-owned services and runtime state without deleting
  administrator data unexpectedly.

The Host RPM must enable the machine service at boot, install only the
documented PAM/systemd/udev/firewall integration, retain one configuration
source at `/etc/plank/host.conf`, and keep mutable state under
`/var/lib/plank/`. It must not enable a firewall service in an administrator's
zone automatically.

The Client DEB must install the interactive application and private FFmpeg
runtime with the documented RUNPATH. It must not install, enable, or launch a
systemd user service, desktop autostart entry, or per-user shell configuration.
Administrator policy belongs only in `/etc/plank/client.conf`.

Production release artifacts must be signed. Development candidates may be
unsigned but must be labeled and retained with their size, SHA-256 digest, and
complete source provenance.

## Release evidence and definition of accepted

An accepted Linux release has:

1. a clean, pushed root commit and exact pushed Host, Client, common-c,
   qmdnsengine, and Kymux commits;
2. reproducible, hash-recorded Host RPM and Client DEB artifacts;
3. passing repository, Host, Client, protocol, negative-security, package, and
   qualification tests applicable to the candidate;
4. real NVIDIA Host and Intel Client evidence for every advertised capture,
   encode, decode, presentation, display, input, Wacom, and audio path;
5. the random/burst-loss, reconnect, takeover, 15-minute, two-hour A/V, and
   eight-hour soak gates above;
6. no unresolved critical security defect, persistent corruption, stuck input,
   unbounded resource growth, or silent format fallback; and
7. a current `HANDOFF.md` that identifies the artifacts, hashes, machine state,
   completed evidence, remaining limitations, and next safe action.

If a gate is intentionally deferred, remove or clearly label the associated
product capability. Do not advertise an unqualified path as supported.
