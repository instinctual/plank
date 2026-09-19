# Output Topology and Selection

## Scope

Protocol version 13 describes the host desktop after operating-system
authentication and lets the client select one capture output or a scaled span
of the complete desktop. Topology is not available through unauthenticated
discovery. The same topology snapshot must drive capture, presentation, cursor
placement, normalized mouse/touch input, and Wacom mapping for the lifetime of
a stream.

## Feature Negotiation

The host returns `schema_version: 13` and a numeric `feature_flags` field from
`GET /plank/topology`. Version 13 defines these bits:

- `0x1` — output topology publication
- `0x2` — stable selected-output launch
- `0x4` — unified absolute-input geometry
- `0x8` — aspect-preserving scaled desktop span
- `0x10` — topology-generation binding at launch and during streaming
- `0x20` — host-layout and virtual-output metadata
- `0x40` — composite-stream source rectangles for local presentation
- `0x80` — exact host-layout binding at launch
- `0x100` — independently selected modes for virtual outputs 1 and 2
- `0x200` — bounded host-layout activation while GDM owns the active seat
- `0x400` — temporary physical-display leases with exact disconnect restoration
- `0x800` — exact per-session capture-source selection and acknowledgement
- `0x1000` — exact per-session encoder-backend and encoding-mode selection
- `0x2000` — NvFBC 8-bit source expansion into HEVC 10-bit 4:4:4 direct NVENC
- `0x4000` — one fixed complete QUIC UDP payload ceiling for both endpoints
- `0x8000` — authenticated transfer of the one active PLANK session between clients
- `0x10000` — explicit GDM-to-user desktop handoff notice on the native control channel
- `0x20000` — authenticated desktop stage for reconnect progress
- `0x40000` — opaque media-worker instance identity for early replacement detection
- `0x2000000` — bind the first virtual connector to the client-primary side

### Expected desktop handoff status

With `0x10000`, Host-to-Client `PLD1` control type 7 has no payload. Its exact
wire vector is `50 4c 44 31 00 07 00 00`. The root supervisor issues a private
`PLANK-DESKTOP-HANDOFF-1` record only when replacing its greeter worker with a
confirmed active user desktop. The root-authenticated inherited channel lets
that worker announce the handoff before invoking its normal SIGTERM path;
the existing bounded supervisor shutdown remains the fallback. No credentials
or new network listener are introduced.

The notice is advisory: it cannot authorize a session, trigger a reconnect,
transfer ownership or substitute for fresh PAM and topology validation. A
Client accepts only a zero-length notice from the authenticated Host channel
advertising this feature. It is consumed by the next transport close within
five seconds, producing neutral `Opening your desktop...` text. Without the
notice, reconnect shows neutral `Waiting for workstation...`. If the
existing unreachable decision timeout expires, status changes to `Workstation
is taking longer to respond...` and the existing Wait/Disconnect policy applies.
Success clears the notice and restores the normal status color. An abrupt X
failure can prevent delivery; it must fall back to ordinary reconnect, never
guess from the previous screen or suppress a real timeout.

With `0x20000`, a successful PAM HTTPS response additionally includes
`desktop_stage`: `greeter`, `user`, or `unknown`. It is never included in a
challenge or denied response, nor in public discovery. The worker reports a
concrete stage only when its supervisor-attested session ID, UID and class
match the currently active eligible local seat0 X11 session. A closing,
missing, replaced or unmatched session reports `unknown`.

Logout can destroy the desktop X server before its worker sends any final
packet. During reconnect, a successful reauthentication reporting `greeter`
therefore changes the Client status to neutral `Returning to the sign-in
screen...` while topology, launch and transport are restored. Until that
confirmation, neutral `Waiting for workstation...` status remains; neither a network outage
nor a lost X server is assumed to mean logout. A greeter-to-greeter recovery
may use the same wording. The notice is UI-only, carries no user/session
identity, grants no access, and does not change any PAM, desktop-ownership,
shutdown or launch checks. Rendering updates stay on the SDL event thread.
The existing timeout always takes precedence, even if reauthentication finishes
late; completion clears the pending status. Stage reporting itself introduces
no Xlib fatal-handler work or fixed delay; the bounded replacement probe below
is separate from authenticated stage reporting.

Reconnect status must not depend on decoded video frames. The Client pauses
decoding and empties its frame queue during reconnect, so video-overlay text
alone cannot reliably display these messages. On Wayland, progress and timeout
status use the existing desynchronized local reconnect-prompt surface. Progress
has no action buttons; the configured timeout exposes the existing decision
buttons, Keep Waiting restores progress, and completion hides the surface.
The parent-relative prompt geometry is retained throughout, without requiring
a new video-frame commit. Other presentation platforms retain their existing
overlay fallback; the qualified Wayland path never shows both at once.

### Early replacement detection

With `0x40000`, successful launch/resume and HTTPS `serverinfo` responses
include `PlankWorkerInstance`: a nonzero UUID generated once per media-worker
process. This is not the persistent workstation ID, a user/session identifier,
or an authorization token. It publishes no desktop stage through discovery.

After at least one video frame has arrived, one second without a received
video frame permits a credential-free HTTPS `serverinfo` probe. At most one
probe is outstanding, with a one-second request deadline and at least one
second between completed probes. Nothing polls HTTPS during normal video flow.
The Client compares the returned worker UUID with the one bound to its
successful launch and pins the HTTPS leaf certificate SHA-256 to the
certificate already used by that stream's QUIC endpoint. Profile-valid TLS
alone, a timeout, a malformed response, an unchanged UUID or a mismatched
certificate is not proof of replacement and must not tear down the stream.

A changed UUID with the pinned certificate, continuing video silence, and an
unchanged local connection baseline triggers the existing reconnect path
without waiting for QUIC idle expiry. Fresh PAM authentication, desktop-owner
checks, topology binding and native launch remain mandatory. New video cancels
the early waiting UI; takeover/disconnect disable recovery. The probe owns only
address and public identity snapshots, not credentials or pointers to session
state. Its result is applied on the SDL event thread. Normal QUIC timeouts,
configured Wait/Disconnect policy and the safe fatal-X11 exit are unchanged.

The client sends `plankProtocolVersion=13`, `plankFeatureFlags`, `plankDisplayMode`,
`plankHostLayout`, `plankVirtualMode1`, and `plankVirtualMode2` on `/launch`. A client negotiating `0x10`
also sends the exact
`plankTopologyGeneration` returned by the topology endpoint. `single-output` also
requires `plankOutputId`; `scaled-span` captures the desktop bounds and omits it.
An output ID is opaque to the client. Linux/X11 IDs use the current
`x11:<connector>` form, for example `x11:DP-2`; enumeration indices are never
sent as stable IDs.

## Topology Document

The document contains a monotonically changing `generation`, the bounding
desktop rectangle, a `layout` object, and an `outputs` array. `layout.kind` is
`physical`, `single`, or `dual-horizontal`; `layout.virtual_modes` is empty for
a physical layout, contains one administrator-qualified mode for `single`, and
contains the independently ordered left/right modes for
`dual-horizontal`. `layout.startup_kind` reports the concrete boot topology:
`physical`, or `single` for the safe 1920x1080 baseline created by the
administrator's `virtual` policy. `layout.allowed_kinds` explicitly lists the
layouts a bookmark may request. A physical startup lists physical, single, and dual-horizontal; a
virtual startup lists single and dual-horizontal. The current layout can
therefore be virtual while its startup remains physical during a session
lease. The layout also publishes whether the current geometry is virtual and
its output count. Each connected output carries its
opaque `id`, user-facing `name`, desktop `x`/`y`, pixel `width`/`height`,
clockwise `rotation`, `refresh_millihz`, and `primary` state. Coordinates may be
negative. Unknown refresh is zero. Each output also carries `virtual` and a
`configured_mode` and a `source_rect` in composite-source coordinates. Version 13 currently makes the
source rectangle identical to the output rectangle relative to the desktop
origin; keeping it explicit avoids inferring monitor boundaries from a wide
encoded frame.

Each bookmark also sends `plankCaptureSource=nvfbc` or
`plankCaptureSource=x11-native10`. The host echoes the accepted value as
`PlankCaptureSource`; the client fails the launch if it is absent or
different. The client also sends `plankEncoderBackend=software-cuda` or
`nvenc-direct` and an exact `plankEncodingMode`. The host echoes both values as
`PlankEncoderBackend` and `PlankEncodingMode`; a missing or
different acknowledgement fails the launch. `x11-native10` is experimental
and accepts only a 10-bit 4:4:4 identity profile. It never falls back to NvFBC
or accepts an 8-bit profile. Its x264 path converts a same-size packed RGB10
canvas directly to planar GBR10, or performs center-aligned bilinear scaling
and plane generation in that same CPU pass when the negotiated encode size is
different. See `protocol/encoding-profiles.md` for the exact allowed tuples.

Protocol version 13 has one data plane: native PlankTransport. The removed
`plankDataPlane` request and `PlankDataPlane` acknowledgement are not
accepted compatibility switches. Every successful launch returns a PlankTransport
port, canonical TLS certificate SHA-256 fingerprint, and canonical one-use
session token; missing or malformed native credentials fail the launch.
The client also resolves its active route and sends
`plankQuicUdpPayloadMtu=1200..65527`. The host applies that exact complete UDP
payload ceiling before it starts its Quinn listener, echoes it as
`PlankQuicUdpPayloadMtu`, and the client applies the same value before
its endpoint starts. Automatic mode uses the selected route interface MTU with
a conservative cap; the qualified ZeroTier route uses 1344 bytes. Manual mode
is an explicit complete-QUIC-UDP-payload override. A missing, invalid, or
mismatched value fails launch so RaptorQ never packetizes a frame against a
path size that can shrink underneath it.

Bookmarks persist `configured`, `physical`, `single`, or `dual-horizontal` as
their host-layout requirement. `configured` is resolved to the authenticated
topology's exact current layout before launch; it is not sent as a wildcard.
Virtual layouts persist one enumerated mode per requested output. The current
60 Hz allowlist is `1024x2160`, `1280x2160`, `1920x1080`, `1920x1200`,
`2560x1440`, `2560x1600`, `2560x2160`, `3440x1440`, `3840x1600`,
`3840x2160`, `4096x2160`, and `5120x2160`. The host compares the requested
layout and both modes with the live topology before claiming the one-use PAM
launch state. A mismatch returns 425 and submits only the enumerated layout,
modes, and authenticated account UID to the root supervisor. Headless virtual
startup retains its bounded GDM transition. A physical-startup host instead
captures the exact NVIDIA MetaMode and applies a temporary logical layout over
the connected native scanouts without restarting the display manager. The
client retains credentials only in memory, waits for the new topology,
refreshes its generation, and continues launch. When login replaces GDM, the
supervisor takes a new snapshot from the authenticated user's X server and
carries the lease into it. The final stream release restores the exact saved
MetaMode; an abandoned launch restores after its bounded setup deadline.

The client persists the chosen output ID per host UUID. If it has no valid
mapping, it selects the primary output, then the first output as a final
fallback. It must re-fetch after hotplug or a rejected launch rather than
falling back to an enumeration index.

Generation fingerprints are independent of enumeration order and change when
output identity, geometry, rotation, refresh, or primary state changes. The
host rejects a stale launch with status 409 before consuming the PAM session;
the client re-fetches the topology and retries once with the same authenticated
token. During a bound stream the host polls for topology replacement at a
one-second maximum interval. A change ends the stream and runs normal input
cleanup so no pen contact, key, or virtual HID device survives against stale
geometry. Reconnection requires fresh OS authentication; seamless in-stream
topology acknowledgement is reserved for a later protocol feature.

An accepted launch owns the workstation from HTTPS acceptance through queued
native setup, in-flight QUIC negotiation, and the running stream. A second
authenticated client receives status 409 with `PLANK workstation session is
active`; it must not poll or silently displace that owner. With explicit local
confirmation, a version-13 client retries the same launch or resume with
`plankTakeover=1`. The Host accepts that flag only with feature `0x8000`, only
after PAM authentication, and only when the authenticated account still owns
the active desktop. It first revokes the old input path, sends reliable
termination reason `0x80030024`, joins the old stream, and only then starts
replacement display and media state. The displaced client disables automatic
reconnect and reports that its session was transferred. No Host OS logout
occurs, so the user's desktop and applications remain running.

### Virtual connector order (optional `0x2000000`)

On a virtual-startup Host, a Client negotiating `0x2000000` may send
`plankPrimaryOutput=0` or `1` for a dual-horizontal layout. The index refers
to the requested left/right mode order. The Host places its first virtual
connector (`DP-0`, shown as PLK Display 1) on that side and marks it primary.
This lets applications that choose the first connector, including Flame,
open on the same screen as the Mac primary display. Omitting the index keeps
the earlier DP-0-left behavior. A single-output request accepts only `0`;
unnegotiated or out-of-range values are rejected.

GDM preparation and live XRandR transitions use the same assignment. The Host
reports virtual modes in desktop left/right order, regardless of connector
enumeration. Manual two-output bookmarks retain their selected mode sizes;
the optional index changes connector placement only. Host worker and supervisor
use private `SC-DISPLAY-4` messages and must be updated together. The
right-primary topology vector is `output-topology-v13-virtual-primary.json`.

## Launch and Input Rules

The host rejects an unsupported protocol version, unnegotiated feature bits,
an unknown output ID, or an output that disappears before launch. A successful
single-output launch resolves the opaque ID once and stores the capture name in
session state. A scaled-span launch captures the complete desktop rectangle
into the requested stream size without changing aspect ratio; unused pixels
are black. The video touch-port uses the same scale and offsets, so normalized
absolute devices share its geometry. Raw Wacom HID reports remain byte-for-byte
device data and are never scaled by this protocol; the host Wacom/Xorg stack
sees the same desktop topology and applies its normal physical-tablet mapping.

When several host outputs feed one client display, `scaled-span` is the default
PLANK mode. `single-output` remains available when native pixel detail
is more important than simultaneous visibility. `separate-displays` uses the
same one-decoder composite stream as `scaled-span`, but the client presents the
published source rectangles in synchronized local windows. Synchronized
per-output streams remain a future feature and must not be inferred from this
schema.

## Experimental fixed-capture preview extension

The `macos-host` work adds `FixedCaptureFeature = 0x80000` within schema 13.
This is a distinct fixed-capture description, **not** permission to relax the
existing Linux topology requirements. Its exact current feature mask is
`7864433` (`0x380071`): fixed capture, Mac desktop preparation, Mac encoding-profile
selection (`0x200000`), output topology, topology generation,
layout metadata and composite source geometry. All other bits are rejected
for this preview. It is deliberately excluded from the Client's Linux
`SupportedFeatureFlags` launch mask.

`tests/protocol/fixed-capture-v13.json` is the shared Host/Client fixture.
The four root fields are `schema_version`, `feature_flags`, `generation`
(canonical nonzero UUID), and `capture`. The latter contains exactly:

- `id`: a bounded opaque capture-display identifier, not a persistent machine ID;
- `width`/`height`: positive even video pixel dimensions, each at most 8192;
- `logical_bounds`: finite macOS desktop-coordinate `x`, `y`, `width`, `height`;
- `encoding_profile`: the exact experimental Apple tuple described below.

Pixel dimensions and desktop coordinates are intentionally separate. A
3840x2160 capture may cover 1920x1080 desktop points with a negative origin.
Do not assume a 1:1 or fixed 2:1 mapping. This report does not grant input, and
does not claim the capture display is physical, PLANK-owned, or newly created.
The Client represents its single video surface as `layoutKind="fixed"`, with
no virtual modes; Linux bookmark layout changes are not allowed for it.

`MacDesktopPreparationFeature = 0x100000` additionally requires authenticated
`POST /plank/display` before constructing a streaming session. The exact JSON
request is `{ "schema_version": 2, "width": 3840, "height": 2160,
"encoding_mode": "hevc-10-444-videotoolbox" }`; numeric values
are integral, never booleans, and must identify a qualified bookmark mode.
The Client first fetches authenticated topology to pin the certificate, then
sends this request through a fresh TLS 1.3 connection pinned to that certificate.
There is no redirect, new port, unauthenticated mutation, or implicit takeover.
The Host returns the strict topology object above, describing actual pixels,
desktop bounds and the selected encoding profile after the change. Changing
the profile changes the topology generation even at unchanged dimensions.
The Client rejects mismatched dimensions or profile and
uses the returned geometry before video/window/input initialization. Preparing
a display does not consume the authentication bearer; stream launch still does.
An active stream rejects preparation (409); authority loss rejects it (401), and
an unavailable/failed mode returns 503 without starting a differently sized stream.

The desktop agent owns one virtual display for its whole process lifetime and
changes only that display's mode between streams. It neither changes a physical
monitor's mode nor deletes/recreates an output on every disconnect. Agent exit
is the removal boundary. The sign-in agent owns a separate display under its
validated LoginWindow authority; both roles use the requested qualified mode.
This private Apple display API requires dedicated macOS 27 qualification.
Old fixed-capture-only feature masks are no longer accepted
by this matching development Client/Host pair.

The explicit tuple is ScreenCaptureKit (`screencapturekit`) → VideoToolbox
(`videotoolbox`), mode `hevc-10-420-videotoolbox`: HEVC Main10, 10-bit 4:2:0,
full range, BT.709 matrix and primaries, sRGB transfer, no RGB identity.
The additional mode `hevc-10-444-videotoolbox` selects HEVC RExt (`profile: rext`),
10-bit 4:4:4 with the same full-range BT.709/sRGB color contract. It requires
SCK xf44 capture and hardware VideoToolbox Main44410; the accepted 420 mode
continues to use xf20/Main10. Neither mode permits a precision/chroma fallback.
Launch schema 1 already contains `encoding_mode`; it must equal the prepared
topology profile. The reply repeats that exact capture/profile. Client decoder
qualification uses a genuine Apple YCbCr fixture for each mode, never Linux's
GBR-identity fixture. Old feature masks/display schema 1 are rejected by this
matching development pair. Linux schema/feature negotiation is unchanged.
No tuple substitution, NVENC naming, Linux 4:4:4 interpretation or HDR inference
is allowed. A ready media agent advertises Main10 and RExt10 4:4:4 codec bits
(`ServerCodecModeSupport=1049088`) and the complete Mac feature mask; an
unready/non-media endpoint advertises zero capability. Capability advertisement
does not replace the hardware-required encoder creation or exact-format Client
decode gate when activating media.

`GET /plank/topology` retains HTTPS and the current `Authorization: Bearer`
header. The Mac checks the address-bound token and live desktop owner before
reading its main display and again afterward. Missing/invalid authorization
returns 401 without querying geometry; unavailable geometry returns 503.
Cache-busting query identifiers never authorize access. Generation changes
when observed display identity, mode or bounds change. Consistent double reads
reject an observed reconfiguration during the snapshot. Continuous topology
monitoring and matching the actual ScreenCaptureKit frame are required before
media/input launch; this metadata-only check is not that lifecycle gate.

This topology extension does not independently grant input or media authority.
Those remain owned by the authenticated native launch/session lifecycle.
It describes one capture canvas, not multiple independently streamed displays.
The Linux schema-13 fixture and checks remain unchanged.

## Test Vector

`tests/protocol/output-topology-v13.json` represents a physical-startup host
temporarily presenting the Flame-style 3840x2160 primary plus 1280x2160
secondary virtual layout. Parsers must preserve order-independent
identity, geometry, virtual provenance, source rectangles, exact layout
binding, independent modes, allowed-layout capability, startup provenance, and
the primary fallback. The version-1, version-2, version-4, version-7, and
version-8 and version-9 vectors remain historical
evidence only; PLANK has no deployed legacy clients requiring a
silent version fallback.
