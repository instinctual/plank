# Headless and Multi-Monitor Display Plan

## Objective

Support PLANK hosts with no physical monitor or display emulator while
preserving the qualified NVIDIA Xorg, NvFBC, CUDA, H.264, absolute-input, and
raw-HID Wacom paths. A bookmark may request one or two stable host displays.
The client may present that workspace on one physical display as a scaled span
or map two host displays onto two client displays.

This plan extends the versioned output-topology and scaled-span implementation
documented in `protocol/output-topology.md`. It does not replace that protocol
or introduce a second display-configuration source.

## Product Scenarios

1. A headless workstation exposes one virtual 3840x2160 display and a client
   presents it fullscreen on one monitor.
2. A headless workstation exposes two virtual displays and a single-monitor
   client presents the combined desktop through the existing CUDA scaled-span
   path.
3. A headless workstation exposes two virtual displays and a dual-monitor
   client maps one host output to each local output.
4. A workstation with physical displays continues to use its qualified layout
   unless an administrator explicitly enables PLANK-owned virtual
   outputs.
5. The virtual display identity and geometry survive a client disconnect so
   Flame does not move windows or exchange pen and eraser state on reconnect.

## Fixed Constraints

- Preserve the workstation's proprietary NVIDIA Xorg/DDX, GLX, CUDA, NvFBC,
  and Flame environment. Do not replace it with a headless Wayland compositor,
  Xvfb, a generic dummy DDX, or public-KMS capture.
- Keep one X screen and one desktop coordinate space. Do not use separate X
  screens such as `:0.0` and `:0.1` for separate monitors.
- NvFBC remains the production capture path and CUDA remains the span-scaling
  path. NvFBC 1.9 BGRA8888 remains honestly labeled as an 8-bit source.
- Keep host configuration in `/etc/plank/host.conf` and
  mutable identity/state in `/var/lib/plank/`.
- A client request is constrained by administrator policy. It cannot provide
  arbitrary Xorg options, file paths, modelines, EDID bytes, connector names,
  shell commands, or unbounded dimensions.
- Display topology is selected before consuming PAM launch state. A stale or
  unsupported topology fails clearly.
- The host display remains stable for an active workstation session. The first
  implementation does not dynamically add, remove, rotate, or resize virtual
  outputs while Flame is running.
- Keyboard, absolute mouse, normalized pen, and raw-HID Wacom remain the only
  supported input classes. No removed controller, generic-touchscreen, or
  relative-mouse preference may return as part of this work.
- The End-User NUC remains a manual-install target and is not used for builds.

## Existing Baseline

The current vertical slice already provides:

- authenticated output topology at `GET /plank/topology`;
- stable Linux output IDs in the form `x11:<connector>`;
- a topology generation bound to launch and the active session;
- per-bookmark Native or Scaled-Span transport scaling;
- complete-desktop NvFBC capture for both scaling modes;
- host-side, aspect-preserving CUDA scaling into the negotiated transport
  canvas;
- a shared touch-port geometry for normalized absolute input;
- fail-closed handling of an explicit topology replacement;
- a 3840x2160 qualified client transport ceiling, except for an exact native
  match already proven by the client display resolver.

The remaining work is production qualification of the virtual-output
lifecycle, scaling choices, and larger native canvases.

## Architecture

### 1. Host display ownership

The PLANK supervisor owns headless display preparation because it is
already responsible for boot, GDM/user-session transitions, and media-worker
replacement. The unprivileged media worker may inspect the resulting topology
but must not write Xorg configuration or invoke privileged modesets.

The supervisor prepares only an administrator-approved topology. Generated
runtime material belongs under `/run/plank/display/`; packaged EDIDs
and immutable templates belong under `/usr/share/plank/display/`.
Production code must not rewrite the workstation's canonical Xorg
configuration in place.

The preferred host shape is:

```text
NVIDIA GPU
  `- Xorg display :0, one X screen and one framebuffer
       |- virtual output 1 / stable EDID / stable RandR connector
       `- virtual output 2 / stable EDID / stable RandR connector
```

The two candidate mechanisms are:

1. NVIDIA-connected virtual outputs backed by packaged EDIDs and explicit
   metamodes.
2. A headless NVIDIA framebuffer divided into XRandR 1.5 logical monitors.

Mechanism 1 is preferred if it works on the qualified driver because Flame,
Xinerama, desktop shells, and toolkits are more likely to treat EDID-backed
outputs as genuine monitors. Mechanism 2 is acceptable only if qualification
proves that Flame sees two independent monitors and NvFBC reports stable output
regions. Merely creating a large framebuffer does not qualify as two monitors.

### 2. Requested and actual topology

Bookmarks describe a bounded layout request, not an Xorg implementation:

- layout policy: match the active client displays, use physical host displays,
  use one virtual display, or use two horizontal virtual displays;
- resolved host layout: `physical`, `single`, or `dual-horizontal`;
- width, height, and refresh rate for each virtual display;
- primary display;
- scaling: `native` for an exact 1:1 transport canvas or `scaled-span` to fit
  the complete host desktop into the selected client resolution.

The host returns its actual topology after preparation. The active topology
continues to use opaque output IDs, rectangles, rotation, refresh, primary
state, and generation. Protocol and code must never infer two outputs merely
from a wide video frame.

Initially expose qualified presets rather than arbitrary modelines. Suggested
probe presets are one 3840x2160p60 output, two 1920x1080p60 outputs, two
2560x1440p60 outputs, and two 3840x2160p60 outputs. A preset becomes a product
option only after Xorg, Flame, NvFBC, encoder, decoder, render, and input gates
pass.

`Match client displays` is resolved entirely by the client before launch. One
active client monitor becomes one virtual host display at its native pixel
resolution. Two active client monitors become two virtual host displays,
ordered left to right, at their respective native pixel resolutions. The
resolved request uses the existing bounded `single` or `dual-horizontal` host
protocol; `match-client` is never sent over the wire. More than two monitors,
a non-horizontal arrangement, failed native-mode detection, or a resolution
outside the qualified preset list fails with a clear client error rather than
silently choosing a different topology. The resolved monitor inventory is held
constant through launch retries and transport reconnects so display hot-plug
cannot silently change the active input/video mapping.

The former `Use the host's configured layout` bookmark policy is removed. It
made a bookmark depend on whichever topology happened to be active on the host
and provided no deterministic deployment behavior. `Match Host` (formerly
`Physical displays`) remains an explicit choice for workstations that should use
real attached host monitors. This label change leaves the stored and wire
`physical` layout value unchanged.

### 3. Session lifecycle

Display preparation occurs before the authenticated graphical session is
launched or attached:

1. Resolve the bookmark request against administrator policy.
2. Reuse an identical, healthy active topology when possible.
3. Otherwise refuse a topology change while a workstation session is active.
4. Prepare Xorg and wait for the exact expected RandR topology.
5. Start or attach the graphical user session.
6. Re-enumerate outputs and publish a fresh topology generation.
7. Consume PAM launch state only after the requested topology is satisfiable.
8. Preserve Xorg and the virtual outputs across network disconnects.

Unexpected topology replacement during streaming retains the existing
fail-closed behavior: end media, raise held buttons, cancel pen contact, detach
raw devices cleanly, and require fresh authentication. Seamless hot-plug is a
later feature.

### 4. Capture and transport

The implementation retains one composite video stream and always captures the
complete host desktop. Native scaling requests a transport canvas exactly
equal to the resolved host desktop, preserving one host pixel per encoded
pixel. Scaled-Span uses the existing aspect-preserving CUDA scaler to fit that
desktop into the client resolution. Both policies use the existing
`scaled-span` host capture request; `native` is a client-side scaling policy
and is not sent as a new wire-level display mode.

One composite stream preserves one encoder, one decoder, one FEC timeline, one
bitrate target, one audio clock, and one set of toolbar statistics. It is the
lowest-risk path to dual-display presentation.

Dual 4K creates a 7680x2160 source canvas. The qualified client currently uses
software decoding for the exact 10-bit 4:4:4 identity profile, so native dual
4K60 must be treated as an unqualified performance case. The negotiated
transport dimensions may be smaller than the host workspace for scaled span.
The host workspace, source canvas, and transport canvas must remain distinct in
telemetry and input transforms.

If a combined stream cannot meet the frame-time, codec-dimension, or decoder
cost gates, add synchronized per-output streams as a later protocol feature.
Do not build multiple streams until measurement demonstrates that they are
necessary.

### 5. Client scaling

The client remains native Wayland/SDL3/Vulkan and uses one presentation
window for the complete remote desktop. Bookmarks expose only Native (1:1
pixels) and Scaled-Span. They do not expose a remote-monitor selector or
switch capture between individual host outputs. Native is appropriate when
the client can present the resolved host canvas pixel-for-pixel. Scaled-Span
retains aspect-preserving scaling and explicit letterbox geometry for a host
canvas that is larger than the available client area.

### 6. Absolute input mapping

All input uses the same immutable topology and presentation snapshot as video:

```text
local window position
  -> destination viewport position
  -> host output rectangle
  -> full host desktop coordinates
  -> normalized PLANK absolute coordinates
```

Clicks in letterbox or pillarbox regions do not reach the host. Crossing local
windows crosses the corresponding host-output boundary. A topology generation
change invalidates the transform before another input event is sent.

Normalized pen follows the same mapping. Raw-HID Wacom reports remain
byte-for-byte device data; the host Xorg/Wacom configuration sees the virtual
desktop topology and applies its normal mapping. Qualification must confirm
that Tablet Margins, tip/eraser identity, pressure, ExpressKeys, and reconnect
behavior remain correct with one and two virtual outputs.

## Configuration Model

Add one administrator-controlled `[display]` section to
`/etc/plank/host.conf`. The first qualified implementation uses:

```ini
[display]
startup_layout = physical
```

`startup_layout` accepts only `physical` or `virtual` and defaults to
`physical`. `physical` preserves connected monitors. `virtual` initializes a
safe single 1920x1080 output before GDM and leaves the second packaged output
available but inactive. After authentication, the bookmark independently
selects each output from the qualified 60 Hz mode pool. The preset boundary
keeps arbitrary modelines out of the privileged display-preparation path while
supporting asymmetric Flame layouts such as `3840x2160 + 1280x2160` and
`4096x2160 + 1024x2160`.

Each of the two packaged virtual-monitor EDIDs is exactly 384 bytes: one base block and
two DisplayID 1.3 extension blocks. Three qualified modes occupy the base
detailed-timing slots and the remaining nine occupy the DisplayID blocks, so
the complete pool is advertised exactly once at 60.000 Hz. The canonical EDIDs
prefer the internal 1920x1080 login mode; a bookmark selects another published
mode without replacing the EDID. Keeping the EDID at or below 384 bytes is required by the
qualified Rocky 9 GNOME/Mutter 40 path, which reads at most 400 bytes from the
XRandR EDID property and rejects a truncated property whose length is not a
multiple of 128.

The stable private monitor identities are manufacturer `SCV` and product names
`Display 1` and `Display 2`. Their 160x90 physical-size fields are an
EDID aspect-ratio marker, not a claim about physical dimensions; this lets
Mutter present the product identity without deriving inappropriate DPI from a
fictitious virtual-monitor size. NVIDIA validates the full live-switching pool
when Xorg starts. An authenticated reconnect selects the 60 Hz entry by its
published RandR mode name and rate; PLANK does not enable
`AllowNonEdidModes` or inject runtime modelines with `xrandr --newmode`.

`SCV` is deliberately unregistered and is used only inside the controlled
PLANK fleet. It is not represented as an IEEE-assigned identity. If
the product is distributed beyond that fleet, replace it with the standards-
defined `CID` marker plus an Instinctual IEEE CID/OUI in a DisplayID 2.1
Product Identification Data Block.

The two stable NVIDIA outputs remain available to Xorg so an authenticated
user can switch between single and dual layouts without restarting the
desktop. In a single-output layout, PLANK turns the secondary output
off and sets its standard XRandR `non-desktop` property to `1`; Mutter then
hides it from GNOME Displays instead of showing a connected but inactive
monitor. A dual-output transition first clears `non-desktop` to `0`, then
activates and positions the secondary output. This is the virtual-monitor
hot-plug boundary; it does not modify the immutable EDID or inject a connector.
XRandR transactions run in a short-lived, bounded systemd transient service as
the owning graphical-session account. The root supervisor does not retain
`CAP_SETUID` or `CAP_SETGID`; the system manager establishes the transient
unit's user identity and applies its `NoNewPrivileges`, filesystem, address-
family, and runtime limits.

## Protocol Evolution

Version 4 is the current PLANK headless-layout protocol. The current
client always requests the complete-desktop `scaled-span` capture path and
adds:

- requested host layout and one preset mode per virtual output;
- virtual versus physical output provenance;
- stable virtual output identity;
- source rectangles within a composite stream;
- source-canvas and transport-canvas dimensions;
- capability limits and explicit rejection reasons;
- optional future per-output stream IDs.

The negotiated feature mask is `0x3ff`: version 1's topology generation,
display identity, geometry, presentation mode, and authenticated topology
features; version 2 layout metadata, composite source regions, and exact layout
binding; version 3 independent virtual-output modes; plus version 4
authenticated dynamic host-layout transitions. Launch requests carry
`scHostLayout`, `scVirtualMode1`, and `scVirtualMode2`; the host compares them
with both administrator policy and the live X11 layout before it consumes
one-use PAM state.

Every protocol change requires synchronized host, client, schema, and
test-vector commits. Old or missing fields must fail clearly when a headless
layout is required; there are no deployed legacy clients requiring a silent
compatibility mode.

## Security and Failure Policy

- Authenticate before returning detailed topology, as today.
- Validate topology requests before consuming one-use PAM state.
- Accept only enumerated presets and policy-bounded layouts.
- Keep EDID content and Xorg templates immutable and package-owned.
- Never interpolate client strings into a shell command or Xorg option.
- Run display preparation in a narrowly scoped supervisor helper.
- Refuse unsupported output count, dimensions, refresh, pixel rate, or GPU
  head count with a specific logged reason.
- Time out if Xorg does not publish the exact expected topology.
- Never restart an authenticated user's Xorg session to change layouts. The
  same PAM-authenticated desktop owner may apply an allowlisted XRandR layout
  in that live session; every other account is refused.
- Roll back only generated runtime state after preparation failure; do not
  modify the canonical workstation Xorg configuration.

## Implementation Phases

### Phase H0 - Non-disruptive inventory and probe design

- Record GPU, NVIDIA driver, Xorg command line, Xorg configuration fragments,
  current RandR providers/outputs/properties, EDID state, GDM ownership, and
  NvFBC output inventory on `hardware-test-host`.
- Determine whether the installed NVIDIA stack exposes a documented headless
  virtual-output mechanism and how many heads it permits.
- Add read-only inventory output to the qualification report where useful.
- Design an isolated secondary-X-server test that cannot alter `:0`, GDM, or
  the active Flame session.

Exit gate: one exact, reviewable probe procedure can test a virtual output
without changing or restarting the production Xorg server.

### Phase H1 - Single virtual output qualification

- Start an isolated NVIDIA Xorg server with no physical output dependency.
- Verify a stable connected RandR output, mode, EDID identity, OpenGL/CUDA GPU,
  and NvFBC visibility.
- Verify GDM/user-session feasibility without altering the production display.
- Capture and encode the virtual desktop through the qualified pipeline.

Exit gate: a rebootable one-output topology works without a monitor or dongle
and meets existing capture, color, timing, and session gates.

### Phase H2 - Dual virtual output qualification

- Expose two independent outputs in one X screen.
- Verify XRandR, Xinerama/toolkit screen enumeration, primary output, stable
  geometry, and Flame monitor awareness.
- Exercise dual 1080p, dual 1440p, and dual 4K source canvases.
- Measure NvFBC capture and CUDA scaling without periodic topology polling on
  the capture hot path.

Exit gate: Flame sees two stable monitors and the combined desktop captures
without changing output identity or missing the 60 fps capture gate.

### Phase H3 - Supervisor-owned headless lifecycle

- Add bounded configuration parsing and validation.
- Package immutable display templates/EDIDs.
- Add a narrowly scoped display-preparation helper and supervisor state
  machine.
- Preserve the topology across disconnect and replace only the media worker
  during display-owner transitions.
- Add unit and integration tests for invalid configuration, unsupported modes,
  timeout, active-session refusal, and cleanup.

Exit gate: cold boot, GDM, login, disconnect, reconnect, logout, and service
restart preserve or cleanly recreate the requested headless topology.

### Phase H4 - Bookmark and protocol integration

- Add per-bookmark Match Client, Physical Displays, one-virtual, and
  two-virtual host-layout choices plus Native and Scaled-Span scaling.
- Negotiate requested and actual topology before launch.
- Publish virtual-output provenance and source/transport rectangles.
- Add explicit unsupported/stale-layout client messages and retry rules.
- Update schemas and protocol test vectors.

Exit gate: all bookmark layouts produce the expected host topology or a clear,
non-consuming rejection.

### Phase H5 - Client scaling

- Resolve Native to the exact host desktop pixel canvas.
- Resolve Scaled-Span through the qualified client-resolution limit.
- Capture and decode the complete desktop once in both cases.
- Fail clearly when Native requests an unqualified codec dimension or cannot
  determine the resolved host canvas.

Exit gate: Native preserves exact pixels and Scaled-Span preserves the full
desktop and aspect ratio across restart, reconnect, and client reboot.

### Phase H6 - Input, performance, and reliability qualification

- Validate keyboard, absolute mouse, buttons, scrolling, normalized pen, and
  raw-HID Wacom across every source/destination mapping.
- Validate the four exact H.264 encoding profiles and their color/range rules.
- Measure encoder, decoder, Vulkan, memory, packet loss, FEC, and A/V sync for
  single 4K, dual 1080p, dual 1440p, and dual 4K.
- Run reconnect, service restart, client crash, network loss, multi-hour soak,
  and host reboot tests.
- Decide from evidence whether synchronized per-output streams are required.

Exit gate: the selected production layouts meet the existing PLANK
latency, color, input, security, and reliability gates without a physical
display device.

## Validation Matrix

For every qualified layout, record:

- physical display present versus no physical display;
- cold boot, GDM, authenticated desktop, logout, and reconnect;
- Xorg screen dimensions, RandR outputs, Xinerama/toolkit monitor count, EDID
  identity, primary output, refresh, and topology generation;
- NvFBC screen/output inventory, capture rectangle, source precision, capture
  age, CUDA scale time, and deadline misses;
- requested profile, actual encoder input format, full/PC range, matrix, output
  bitstream profile, decoder surface, and rendered pixel checks;
- Native and Scaled-Span on one- and two-display host layouts;
- client monitor reorder, unplug, and replug behavior for Match Client;
- pointer boundary crossing, letterbox rejection, Wacom tip/eraser/pressure,
  Tablet Margins, ExpressKeys, and reconnect identity;
- requested/actual source and transport dimensions, target bitrate, packet
  loss, FEC recovery, frame holds, A/V drift, CPU, GPU, and RSS;
- absence of Xorg restart, Flame window rearrangement, stuck input, and stale
  topology acceptance.

## Performance Decision Gates

- NvFBC capture-call p95 stays within the 16.67 ms frame budget at 60 fps.
- CUDA scaling and color preparation retain the existing production margin.
- Client decode plus presentation sustains the negotiated cadence without a
  rising render queue or periodic holds.
- Native transport preserves 1:1 pixel geometry without introducing a rising
  decode or presentation queue.
- Dual 4K is not advertised merely because Xorg can create the framebuffer.
  It must pass codec dimensions, encoder cadence, software-decoder cost,
  Vulkan presentation, and soak tests.

## Initial Deliverables

1. A read-only `hardware-test-host` headless-display inventory report.
2. A non-disruptive isolated-Xorg probe and rollback procedure.
3. Evidence selecting EDID-backed NVIDIA outputs or logical RandR monitors.
4. A single-virtual-output prototype behind an administrator-disabled default.
5. A dual-output prototype and performance report.
6. Versioned protocol/test-vector changes and bookmark UI.
7. Client scaled-span and separate-display acceptance results.

No candidate package is accepted until exact source provenance, build-machine
rules, artifacts, installation state, validation evidence, and remaining gates
are recorded in `HANDOFF.md`.
