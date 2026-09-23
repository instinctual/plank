# Reverse microphone audio (in development)

This extension is implemented on the microphone-forwarding candidate branch,
not released. Existing even-numbered Host-created endpoints and native/2 ALPN
remain unchanged. Matching macOS launch schema 4 requests `microphone: true`;
the authenticated reply's services map advertises availability only for a
desktop worker with the installed virtual input. Linux Hosts do not advertise
this capability. Merely accepting an audio endpoint never authorizes capture.

After authenticated capability agreement, the Client registers its first
KyProto audio-source endpoint (ID 1, odd Client parity); the Host connects an
audio sink with that ID. Both use AudioProtocol::UnreliableFec and the existing
QUIC connection. Kyber needs no modification. Endpoint establishment belongs
inside the existing session cancellation scope and has a bounded deadline.

Audio is mono Opus, 48 kHz, 480 samples (10 ms) per packet. The KyProto codec
record uses OPUS and frame_size 480. A microphone media payload contains:

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII PMIC |
| 4 | 1 | Envelope version 1 |
| 5 | 1 | Channels: 1 |
| 6 | 2 | Samples: 480, big-endian |
| 8 | 8 | Nonzero activation generation, big-endian |
| 16 | 8 | First sample index in activation, big-endian; multiple of 480 |
| 24 | 1–1275 | One Opus packet |

The complete envelope is bounded to 1299 bytes and validated before decoding.
The Opus decoder must independently enforce one mono 480-sample frame; envelope
metadata is not proof of valid compressed content. KyProto owns packetization
and FEC. Oversize/bad-version/zero-generation/misaligned-time records fail
validation. The unit suite includes a fixed byte vector.

PLD1 type 8 (`SET_MICROPHONE`) has three big-endian u32 words: generation high,
generation low, flags (enabled=1, automatic Host input selection=2). Type 9
(`MICROPHONE_APPLIED`) echoes generation and state: off=0, pending=1, active=2,
unavailable=3. Generations are nonzero and strictly increase for every command;
selection policy is fixed for the session. Mute closes Client recording before
waiting for the reliable command queue. Active capture waits for the matching
Host acknowledgement and normal OS permission. Invalid controls fail closed.

The source queue holds two packets (20 ms), the receiver eight (80 ms), and
packets older than 100 ms are discarded. Overflow evicts the oldest packet;
generation changes clear both queues. Late or out-of-order microphone media is
discarded without terminating video. Endpoint creation/failure is bounded and
does not stop otherwise healthy output audio/video. All endpoint futures share
the session cancellation scope.

The Host native Opus decoder validates mono/480 samples, then a bounded PCM
producer absorbs independent clock drift and supplies silence on starvation.
The existing root coordinator admits the signed current desktop worker using
kernel UID/PID/audit-session identity plus its current registry generation.
A fresh shared region is allocated for each producer lease; retired producers
never get a later session's region. Root admission expires independently of
producer-writable PCM. XPC and mapping operations never run in the realtime
HAL callback. The driver sanitizes fixed-size blocks into private sample history.

Automatic selection is owned for the producer lifetime. It remembers the prior
input UID and restores only if PLANK is still selected; later user choices win.
Muting keeps the virtual input selected and silent, not a physical fallback.
Manual selection never changes the default. Disconnect/worker replacement
revokes production; an orphaned writer cannot keep admission alive.
