# Native camera lane (in development)

Mac launch schema6 or independently negotiated camera feature1 in schema7
enables this optional lane separately from microphone. Earlier peers keep camera
disabled while retaining desktop connectivity. It is not in the installed stereo candidate.
The Ubuntu Client starts with camera off; the toolbar explicitly enables it.
The selected device uses native H.264 when available, then MJPEG, preferring
1080p over 720p within a codec. An explicitly selected missing device fails;
it does not select another camera. Automatic selection uses the first native
compressed camera reported by read-only V4L2 enumeration. No encoder is used.
Existing native/2 desktop lanes and their IDs are unchanged.

The Linux capture component now reads direct V4L2 MMAP buffers without a video
encoder or libv4l conversion. It rejects emulated/coerced modes, bounds buffers,
validates basic coded framing and monotonic timestamps, copies native bytes and
restores the prior device mode at close. Its standard force-keyframe request can
fall back to the descriptor-verified UVC H.264 picture-type control, requesting
IDR with SPS/PPS. The physical camera passed three such requests within 140 ms.
Requests are limited to two per second; an accepted control still requires a
validated recovery frame before dependent pictures may resume. Product capture activation waits for the matching Host acknowledgement.

The Mac sample builder independently checks coded framing and dimensions,
activation, sequence, timestamps and fixed format metadata. H.264 parameter sets
must match throughout an activation; JPEG is bounded single-scan baseline. It
rejects progressive JPEG and H.264 SVC/MVC. H.264 NAL bytes survive the required
Annex-B-to-length-prefix adaptation; JPEG remains byte-identical. Its output
component returns compressed samples directly or lazily decodes NV12 when pixels
are requested. Switching to pixels and recovering from discontinuity require an
independent frame. The production extension adds producer admission and camera registration as
described below. Its integrated signing, activation and application gates remain
pending. Arrival timestamps use the Core Media Host clock; capture timestamps
remain in PCAM. Audio/video clock alignment and lip sync remain unqualified.

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

## Session control and local camera boundary

PLD1 camera controls are valid only after schema6 camera capability agreement:
SET_CAMERA (10) carries increasing nonzero u64 command generation and a u32
flag (0 off, 1 on). CAMERA_APPLIED (11) echoes that generation and state 0 off,
1 pending, 2 active or 3 unavailable. CAMERA_KEYFRAME (12) carries only the
active u64 generation. All words are big-endian. UINT64_MAX is reserved.
Control bounds are shared by Client/Host; malformed controls fail the session,
while optional media/extension failure reports camera unavailable without
terminating desktop media. Recovery requests are limited to two per second.

Root admits the exact current desktop worker's kernel UID, PID, audit session
and worker generation, after XPC code-signature verification. The extension
must have the exact camera identifier and the Host's Developer ID Team.
The extension independently verifies the root service's signature and UID.
Each activation receives fresh shared memory; a retired writer never receives
a replacement's mapping. Root handles leases, not compressed media or decoding.
Producer renewals and registry checks expire within two seconds; consumer
admission expires independently of all producer-writable data. Camera-off,
disconnect and producer/extension loss revoke admission and remove the device.

The mapping contains three fixed maximum-size slots. Atomic word copies and
slot stamps prevent accepting a torn snapshot; sizes/indices/age are bounded
before copying. Parsers see only a private copy. Gaps request an independent
frame. The extension permits at most one media job in flight. Its control queue
can retire the device while decoding is blocked, and stale completions cannot
publish or deliver after revocation. CoreMediaIO/TCC governs application camera
access; media injection uses the separate authenticated producer lease.

Only the first validated native sample establishes the device's immutable
compressed and NV12 formats. Off/reopen removes and recreates the stream with
stable device identity; do not claim seamless app reopen across format changes.
Compressed output retains native samples. NV12 output creates a decoder on
request, with keyframe recovery on format switches. The active format belongs
to the stream; mixed application adaptation requires live qualification.

A newly streaming application also requests a fresh independent picture when
the active format remains compressed: that app may have its own decoder. The
extension observes CoreMediaIO's streaming-client membership as well as stream
start callbacks. It preserves existing readers' decoder state and retries through
the bounded keyframe-request path until an independent picture is delivered
after the latest join. A frame already in flight before that join cannot satisfy
the request. Retiring the stream cancels queued membership notifications.

When microphone3 is active and the virtual microphone is being read, the Host
maps the preserved V4L2 capture timestamp onto the microphone's scheduled render
clock. See [microphone timing](microphone.md). Without a fresh audio anchor,
arrival-based presentation remains available. Camera IPC version2 separates
arrival from presentation time: receipt age remains bounded to150ms even when
presentation is scheduled up to100ms ahead. Decoder completion repeats both
checks. Neither the PCAM camera schema nor native compressed payloads change.
