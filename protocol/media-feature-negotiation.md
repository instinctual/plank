# Independent media feature negotiation

The macOS Host and shared Client negotiate media features separately. This
contract uses the existing authenticated TLS control connection and native
`plank-native/2` QUIC transport. Linux Host PLS1 negotiation is unchanged.
Older transport protocols are not restored. Product version equality is not a
requirement for peers implementing this envelope.

After authentication and topology retrieval, before display preparation or
launch, the Client sends `POST /plank/negotiate` with its bearer token. The
request has `schema_version: 1`, `transport: "plank-native/2"`, a
`required_features` array and a `features` object. Each feature offers an array
of supported profiles in preference order. The Host selects the first common
profile for each feature. The response has envelope1, `launch_schema: 7`, the
same transport and required features, and a selected profile or null per feature.
The shared vector is [media-feature-negotiation-v1.json](../tests/protocol/media-feature-negotiation-v1.json).

| Feature | Schema | Contract |
| --- | --- | --- |
| desktop | 1 | Exact selected HEVC Main10 4:2:0 or Rext10 4:4:4 VideoToolbox profile |
| audio | 1 | Host output: Opus, 48 kHz, stereo, 5 ms packets |
| input | 1 | Keyboard, absolute mouse and normalized pen |
| clipboard | 1 | Existing clipboard transfer; macOS Client only |
| microphone | 2 | Client input: Opus, 48 kHz, stereo, 10 ms packets |
| camera | 1 | Native H.264 Annex B and MJPEG reception; Ubuntu Client capture |

Desktop, audio and input are required. Unsupported optional features become
null or may be omitted; they do not prevent connection. Unknown optional
features and additional fields are ignored within the size limits. Unknown
required features, unsupported required profiles, incompatible transport or
envelope versions return HTTP426. Malformed fields return HTTP400. There are
at most 16 envelope fields, 32 features, 16 required names, eight offers per
feature and 32 fields per profile; existing HTTP body limits also apply.
Integers cannot be booleans or fractions. Feature schemas change only when
their semantics or wire format becomes incompatible; additive optional fields
do not require a new envelope or unrelated feature version.

Negotiation is read-only. It does not open devices, change displays, claim a
stream lease, grant capture consent or renew the setup token. Existing
owner/peer/expiry checks run before and after negotiation. Rejection or failed
reply delivery revokes the setup token. Successful negotiation retains it.
The Client binds its cached agreement to the authenticated context, selected
video profile and pinned certificate.

Launch7 contains `schema_version`, `transport`, `required_features`,
`capture_generation`, `capture_id`, `max_udp_payload_size` and `features`.
Its desktop feature adds exact `width`, `height`, `frame_rate` and `bitrate_kbps`.
Existing geometry, encoder, authorization and one-use launch checks still apply.
The Host validates this self-contained selection again; no prior negotiation
state grants authority. The reply contains schema7, state, transport token, UDP
port, MTU and capture descriptor, plus transport, required features and selected
features. It has no legacy `services` object. Runtime availability may disable
an optional feature at launch. An unavailable required feature prevents launch.
Camera/microphone activation still requires the separate acknowledgement and
device permission flows. The final launch reply governs device access.

## Explicit adapters for existing peers

| Older launch schema | Desktop/audio/input | Reverse microphone | Camera |
| --- | --- | --- | --- |
| 4 | Preserved | Disabled (old mono packet format) | Disabled |
| 5 | Preserved | Stereo schema2 when available | Disabled |
| 6 | Preserved | Stereo schema2 when available | Schema1 when available |

The new Host accepts the exact old request and returns the exact old reply
shape and schema. It never sends new optional fields to these strict parsers.
All requests normalize to one internal media configuration. No duplicate mono
decoder, old transport implementation or weaker authentication path is added.

A new Client uses an adapter only after `/plank/negotiate` returns HTTP404 and
a separate, certificate-pinned `/serverinfo` identifies a known older release:
1.0.156, 1.0.157 and 1.1.001 map to schema4; 1.1.002 maps to schema5; 1.1.003
maps to schema6. Branch suffixes are allowed. Unknown versions fail clearly.
TLS failure, changed identity, denied authentication, timeout, malformed data,
redirects and HTTP426 never trigger a fallback or launch retry. This finite
version table bridges releases that predate feature negotiation; new releases
use advertised feature contracts. Selected video quality is never downgraded.

Tests cover both adapter directions, omitted/unknown optional features,
required-feature rejection, exact profiles and real TLS request sequences.
Installed mixed-version streaming and application camera/audio acceptance
remain separate hardware gates.
