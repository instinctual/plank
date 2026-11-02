# Authenticated macOS preview launch

Experimental, on `macos-host` only. The actual Host advertises HEVC Main10 and
fixed capture; component-only fixtures still advertise zero capabilities.
The ordinary Client uses this authenticated media contract. This does not
replace Linux PLS1 negotiation or claim completed LoginWindow deployment.

After TLS 1.3 certificate approval, `/plank/auth/start` and `/plank/auth/respond`
authenticate the active desktop's owner. `GET /plank/topology` returns the exact
schema-13 fixed-capture descriptor. The preview then accepts an authenticated
`POST /plank/launch` with `Authorization: Bearer <HTTP token>` and a JSON body.
No credentials or tokens are accepted in URLs. A missing launch handler leaves
the route absent (404); authentication itself does not enable capture.

After authentication, both display preparation and launch check the graphical
worker's current, non-prompting screen/input permissions before changing modes
or creating a transport lease. Missing permission returns HTTP 403 with exactly
`{"state":"denied","error":"host_permissions_required"}`. This is an error
extension, not a change to the success manifest or transport ABI.
Unauthenticated callers still receive 401 without permission details. The Client
maps only this fixed code to local instructions; arbitrary Host text is not
displayed. Permission denial does not alter display topology. Failed launch
and rejected display requests revoke that attempt's HTTP token (and any
claimed lease); retry requires fresh authentication. A display-readiness
HTTP503 retains the still-authorized setup context for another readiness
request, without extending its expiry. Unauthenticated or
wrong-peer requests cannot revoke another attempt. Successful display
preparation retains its token for launch. The Client stops automatic reconnect
on HTTP403, since operator consent cannot be recovered by repeated logins.
Capture/input still recheck access at startup to cover revocation races.

Authentication capacity/verification contention returns `{"state":"busy"}`,
distinct from `{"state":"denied"}` for rejected authentication. The Client
reports busy as HTTP503 locally, not an incorrect-password message. Pending
challenges are bounded at 16; unused authenticated setup tokens are bounded at
four. After successful account/ownership verification, a new token supersedes
unused tokens for the same verified account and peer. A full token table does
not prevent that verification/replacement. Account UUID and UID, not an
unverified username, define identity. Different accounts sharing a relay/NAT
remain independent. Active stream leases are separate and are never replaced
by a login attempt. Failed passwords cannot invalidate setup or stream access.
An authorized topology-readiness HTTP503 likewise retains the setup context.
Rejected/cancelled topology retrieval and failed topology/display reply delivery
revoke it. This avoids repeating password verification merely to wait for a
display. Ownership/peer checks and the original five-minute expiry still apply
to every request; no keepalive or poll renews that expiry.
Unobserved client abandonment remains bounded by replacement and the five-minute
setup expiry. No account details or secrets enter errors. The wire format is
unchanged. Matching Client recovery retains this context until explicit
invalidation or launch consumption. It stops on rejected authentication,
permission denial or TLS failure; an expired readiness token may be refreshed.
The configured Host Timeout bounds each automatic recovery window. In Ask mode,
the local prompt pauses new control requests until Keep Waiting; an in-flight
bounded request may finish but cannot trigger more work behind that prompt.
Disconnect cancels the paused worker. Login/logout recovery otherwise remains
automatic. These rules do not apply credentials to bookmark discovery polls.

Desktop Clients use the independently versioned contract in
[media-feature-negotiation.md](media-feature-negotiation.md). Launch envelope7
is the only accepted external format; the shared request vector is
`tests/protocol/macos-preview-launch-v7.json`.

The top-level fields are `schema_version: 7`, `transport: "plank-native/2"`,
`required_features`, `capture_generation`, `capture_id`,
`max_udp_payload_size` and `features`. The negotiated desktop feature carries
exact even pixel dimensions (2–8192), the selected VideoToolbox HEVC encoding
profile, frame rate60 and bookmark bitrate10000–150000 kbit/s.

The MTU is the complete QUIC UDP payload ceiling (1200–65527), not Ethernet MTU
or encoded NAL size. Numeric validity does not establish the actual path MTU.
Malformed values, incompatible required features, wrong profiles and stale
geometry fail. Bounded additive optional hints are permitted by the envelope.
There is no implicit resize, profile substitution, takeover or fallback port.

A successful reply contains envelope7, `state: "connecting"`, an independent
one-use `transport_token`, `udp_port`, the exact `max_udp_payload_size`, the
selected `capture`, transport agreement, required features and actual enabled
feature profiles. There is no legacy `services` object. Clipboard, microphone
and camera availability remain limited by the authenticated desktop and actual
Host resources. Device activation additionally requires the existing consent
and acknowledgement flow; availability alone does not authorize capture.

The UDP port is the same number as the approved HTTPS control port. QUIC uses
the same leaf certificate; the Client pins the certificate it approved for
HTTPS, not a new trust decision or a request-selected certificate. Launch does
not instruct the Client to connect to another host/address. Bind address and
key/certificate files are trusted Host configuration, never JSON fields.

The original HTTP token is consumed. Replay fails even before QUIC connects.
The native transport secret proves possession for that connection; its endpoint
must reach READY within the claim's 15-second activation window. Capture starts
only after lease activation. Failed/expired HTTPS reply delivery revokes the
original token's claimed lease. An exception during launch also revokes it.

Native data controls retain existing PLD1 encoding: disconnect, keyframe request,
reference-range invalidation (implemented by forcing a keyframe), and bitrate
updates. Bitrate acknowledgement contains requested/applied/peak values in that
order. Malformed/unsupported controls fail the session. System audio is Opus,
stereo 48 kHz, 5 ms packets (one stream, one coupled stream, mapping 0/1).
Keyboard, absolute mouse, buttons, scrolling and normalized pen use native input.
No separate cursor, raw-HID or generic-touchscreen capability is claimed.
See `macos-pen-input.md` for pressure, validation and cleanup. Retired launch
schemas4–6 are rejected; no version-string adapter or mono audio fallback remains.
The native library itself retains its shared Linux endpoint implementation.

The Client now has a typed manifest parser and explicit native service flags.
Audio/input/normalized pen are required for this manifest. It sets
`LI_FF_DYNAMIC_VIDEO_BITRATE | LI_FF_ENCODER_TARGET_ACK | LI_FF_PEN_TOUCH_EVENTS`. The embedded cursor needs no local
cursor channel. Common-c skips absent service workers;
the Client does not start an audio receiver without negotiated audio. Linux
PLS1 setup explicitly retains all three services and its existing checks.
This internal Client/common-c struct change is not a transport wire ABI change;
the two must be rebuilt together, without an old-struct fallback.

The ordinary Session calls the pinned HTTPS launch, then consumes this manifest
instead of sending a Linux setup exchange. Capture pixels remain host-native;
Scaled-Span fits them at presentation. A changed topology requires fresh
authentication/geometry instead of silently reusing stale dimensions.

Mac display preparation uses `POST /plank/display` schema **3**, with exactly
five fields: `schema_version`, `width`, `height`, `scale`, `encoding_mode`.
See `tests/protocol/macos-display-v3.json`. Width and height are even backing
pixel counts from 2 through 8192; scale is integer 1 or 2. Logical desktop
dimensions are pixels divided by scale and may be odd. Booleans, fractional
values, missing/extra fields and prior schemas are rejected. Matching Host and
Client display contracts are required; no silent 1x downgrade. Launch supports
schema7 and fixed-capture topology remains schema13 (already carrying both geometries).

For macOS Clients, Match Client reads the current CoreGraphics mode's backing
pixels and logical bounds, preserving the user's current "Looks like" setting
rather than guessing from panel-native pixels. One display or two horizontally
arranged displays at the same 1x/2x scale form one canvas. Mixed-scale layouts
fail explicitly and can use a manual mode instead. Manual modes and Linux
Client Match Client remain 1x; Linux Host EDID policy is unchanged.

The Host registers at most one additional custom 60 Hz mode alongside its
presets, with logical dimensions for HiDPI, only applying changed settings
while an existing output is online. Preparation confirms exact backing pixels,
logical bounds and selected encoder profile; launch validates the resulting
topology. Recovery retains the successful scale. Size bounds are not a promise
of encoder support for every size. No nearest-preset substitution or global
display preference is used.

Schema6 negotiates the optional PCAM camera lane separately from microphone.
The Host advertises camera capability only for the authenticated desktop user
when its signed application contains the camera extension. This does not prove
extension activation/approval. Explicit camera-on waits for the root broker and
extension lease before capture is acknowledged; absence or failure is reported
as camera unavailable. The Client starts with camera off, including reconnects.
`camera.md` defines activation, recovery and the local producer boundary.
