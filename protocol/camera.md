# Native camera lane (in development)

This transport foundation is not advertised by the current products and is not
part of the stereo microphone candidate. Client capture, authenticated launch
and activation controls, Mac producer admission and camera-extension integration
remain required before enabling it. Registering an endpoint does not authorize
camera access. Existing native/2 desktop lanes and their IDs are unchanged.

The Linux capture component now reads direct V4L2 MMAP buffers without a video
encoder or libv4l conversion. It rejects emulated/coerced modes, bounds buffers,
validates basic coded framing and monotonic timestamps, copies native bytes and
restores the prior device mode at close. Its standard force-keyframe request can
fall back to the descriptor-verified UVC H.264 picture-type control, requesting
IDR with SPS/PPS. The physical camera passed three such requests within 140 ms.
Requests are limited to two per second; an accepted control still requires a
validated recovery frame before dependent pictures may resume. Product capture
activation, authenticated controls and Host integration are still outstanding.

The Mac sample builder independently checks coded framing and dimensions,
activation, sequence, timestamps and fixed format metadata. H.264 parameter sets
must match throughout an activation; JPEG is bounded single-scan baseline. It
rejects progressive JPEG and H.264 SVC/MVC. H.264 NAL bytes survive the required
Annex-B-to-length-prefix adaptation; JPEG remains byte-identical. Its output
component returns compressed samples directly or lazily decodes NV12 when pixels
are requested. Switching to pixels and recovering from discontinuity require an
independent frame. These serial components do not establish producer admission,
camera registration, clock synchronization or product capability advertisement.

The pilot's driver sequence skips an index at H.264 startup despite continuous
coded frame numbers. Capture conservatively marks that discontinuity so the
transport can recover. A reported 30 fps interval is not a promise of actual
30 fps: the current device's auto-exposure policy permits a lower frame rate.
Preserve actual capture timestamps and qualify timing separately.

Reverse endpoint allocation is fixed by authenticated session capabilities:
microphone ID1, then camera ID3; a camera-only session uses ID1. Recording/mute
switches do not change allocation. Enable microphone first when negotiated.
Camera registration waits for microphone allocation, separately from its media
readiness. A bounded setup failure disables camera, leaving other media intact.
All futures belong to the existing session cancellation scope.

The camera uses KyProto `VideoProtocol::UnreliableFec` with codec `CAM1`, rotation
and frame size zero and an empty initial configuration. Each media record is one
PCAM envelope plus exactly one native payload. Its outer PTS equals the capture
timestamp and its key flag matches the envelope. No video encoder or decoder
belongs in the transport. The fixed v1 modes are native H.264 Annex B or MJPEG,
1280x720 or 1920x1080, nominal 30 fps. Device capture must independently prove
that the mode is native, accepted and not emulated.

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII PCAM |
| 4 | 1 | Envelope version 1 |
| 5 | 1 | Flags: independent frame=1, discontinuity=2; no other bits |
| 6 | 2 | Header size 64, big-endian |
| 8 | 8 | Nonzero activation generation |
| 16 | 8 | Increasing frame index in activation |
| 24 | 8 | Client monotonic capture timestamp, microseconds |
| 32 | 4 | ASCII H264 or MJPG |
| 36, 38 | 2 each | Width, height |
| 40, 44, 48, 52 | 4 each | V4L2 colorspace, transfer, YCbCr encoding, quantization |
| 56 | 4 | Original V4L2 sequence |
| 60 | 4 | Reserved zero |
| 64 | 1–4194304 | Native captured payload bytes |

All multibyte integers are big-endian. Color values are preserved, not guesses
about decoded RGB. Accepted numeric bounds are respectively 0–12, 0–7, 0–8 and
0–2; the receiving codec/platform must also support their interpretation.
Format is fixed within one activation. Generation must increase on reactivation;
zero disables and clears queues. Frame index UINT64_MAX, timestamp zero and
timestamps exceeding INT64_MAX/1000 fail validation. The latter permits safe
nanosecond conversion. Metadata and key hints do not establish codec validity:
the Host must independently validate compressed contents and dimensions.

The source holds at most two frames, the receiver three. Queue age is limited
to 150 ms at each boundary; these bounds are not a network latency guarantee.
Overflow, expiry and sequence gaps discard dependent H.264 until an independent
frame arrives. Recovery requests are level-triggered for the current generation;
the caller must rate-limit them and request an actual camera keyframe. MJPEG
frames are independent. A discontinuity may be added to delivered metadata;
native payload bytes remain unchanged. Short receive buffers retain the queued
record, subject to ordinary bounded overflow/expiry.

C and Rust consume the same synthetic `tests/protocol/camera-v1.hex` vector.
Tests cover metadata/bounds, stale generations, format changes, queue overflow,
expiry and keyframe recovery. The encrypted C-ABI fixture covers camera-only
and camera-plus-microphone allocation, direct/setup-promoted connections,
byte equality, short-buffer retry, mute and reactivation. These are transport
component tests; live capture, sustained loss, timing/color, application delivery
and camera/microphone synchronization remain separate acceptance gates.
