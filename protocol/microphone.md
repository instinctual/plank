# Reverse microphone audio (in development)

This extension is implemented on the native-media-investigation candidate branch,
not released. Existing even-numbered Host-created endpoints and native/2 ALPN
remain unchanged. Mac launch schemas5/6 request `microphone: true`; schema7 negotiates microphone
feature3 (timestamped stereo) or feature2 (legacy stereo) independently. Schema4 peers retain desktop connectivity with microphone
disabled. The authenticated reply advertises availability only for a
desktop worker with the installed stereo virtual input. Linux Hosts do not advertise
this capability. Merely accepting an audio endpoint never authorizes capture.

After authenticated capability agreement, the Client registers its first
KyProto audio-source endpoint (ID 1, odd Client parity); the Host connects an
audio sink with that ID. Both use AudioProtocol::UnreliableFec and the existing
QUIC connection. Kyber needs no modification. Endpoint establishment belongs
inside the existing session cancellation scope and has a bounded deadline.

This is the same Kymux stack (`kyproto`/`kynet`) and authenticated connection
used for Host-to-Client desktop video and sound, with the source/sink direction
reversed. Camera likewise uses a reverse video endpoint on that connection.
Reliable controls and FEC media share the established transport; no extra
listening port or separate media connection is needed.

Audio is stereo Opus, 48 kHz, 480 samples per channel (10 ms) per packet.
The Client uses OPUS_APPLICATION_AUDIO, 192 kbps total, constrained VBR and
forced stereo signaling. This is a quality-oriented lossy mode, not native PCM
preservation. VBR is not a hard packet-size or instantaneous bitrate ceiling.
Capture converts the selected source to interleaved stereo float at 48 kHz;
a mono source cannot gain an independent second channel through conversion. The KyProto codec
record uses OPUS and frame_size 480. A microphone media payload contains:

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII PMIC |
| 4 | 1 | Envelope version 2 or 3, as negotiated |
| 5 | 1 | Channels: 2 |
| 6 | 2 | Samples per channel: 480, big-endian |
| 8 | 8 | Nonzero activation generation, big-endian |
| 16 | 8 | First sample index in activation, big-endian; multiple of 480 |
| 24 | 8 | Version3 only: first decoded sample capture time, Client CLOCK_MONOTONIC nanoseconds |
| 24 (v2) or 32 (v3) | 1–1275 | One Opus packet |

Version2 remains byte-for-byte unchanged. Version3 requires a nonzero capture
timestamp no larger than INT64_MAX minus10ms; timestamps increase within an
activation. Each lane accepts only its negotiated envelope version. The KyProto
outer PTS remains the sample index divided by48 (milliseconds).

The complete envelope is bounded to1299 bytes for v2 or1307 bytes for v3 and validated before decoding.
The Opus decoder must independently enforce one stereo 480-sample frame; envelope
metadata is not proof of valid compressed content. KyProto owns packetization
and FEC. Oversize/bad-version/zero-generation/misaligned-time records fail
validation. The unit suite includes fixed byte vectors for both versions.

PLD1 type 8 (`SET_MICROPHONE`) has three big-endian u32 words: generation high,
generation low, flags (enabled=1, automatic Host input selection=2). Type 9
(`MICROPHONE_APPLIED`) echoes generation and state: off=0, pending=1, active=2,
unavailable=3. Generations are nonzero and strictly increase for every command;
selection policy is fixed for the session. Mute closes Client recording before
waiting for the reliable command queue. Active capture waits for the matching
Host acknowledgement and normal OS permission. Invalid controls fail closed.

The source queue holds six packets (60 ms), the receiver eight (80 ms), and
packets older than 100 ms are discarded. The source accepts one complete Client
capture batch before its asynchronous sender must run; a two-packet queue
dropped valid audio-server bursts in physical camera/microphone tests. Capacity
does not add a wait: the sender drains available packets immediately.
Overflow evicts the oldest packet;
generation changes clear both queues. Late or out-of-order microphone media is
discarded without terminating video. Endpoint creation/failure is bounded and
does not stop otherwise healthy output audio/video. All endpoint futures share
the session cancellation scope.

The Host native Opus decoder validates stereo/480 samples per channel, then a bounded PCM
producer absorbs independent clock drift and supplies silence on starvation.
Its decoded PCM queue remains bounded to 60 ms of samples and separately drops
PCM that has waited 100 ms in that queue, both before appending and before
rendering. Fresh arrivals cannot renew old samples' age. Expiry requires fresh
priming, including after starvation leaves a partial packet. Mute clears queued
PCM. Smoothed queue occupancy controls a maximum one-frame adjustment per
480-frame output block, retaining the target reserve after consumption so
capture batches do not cancel the clock correction. Both channels use the same
interpolation. These receipt times bound local queue age independently of source
capture timestamps; they do not establish an end-to-end latency bound.

Timestamped capture on Ubuntu uses PipeWire's per-buffer cycle time and reported
capture graph/resampler delay, on the same CLOCK_MONOTONIC timeline as V4L2.
It does not use the time when the encoder thread polls the audio queue. A bounded
packetizer preserves source timing across graph quanta, discards partial data
across source gaps and expires stale PCM. Opus lookahead is subtracted so the
packet timestamp describes the first decoded sample; sequence gaps reset the
encoder and decoder. No audio callback encodes or accesses the network.
See PipeWire's [buffer clock](https://docs.pipewire.org/structpw__buffer.html) and
[reported latency](https://docs.pipewire.org/structpw__time.html). Accuracy depends
on hardware/graph latency reporting and requires physical A/V qualification.

The Host retains source timing through PCM queueing and drift correction. Each
rendered block anchors its first consumed source sample to its scheduled HAL Host
time. Camera presentation uses that fresh anchor, refreshed every10ms while the
virtual microphone is being read. Mapping expires after100ms and extrapolates
at most150ms; no fixed long-term Client/Host oscillator ratio is assumed.
Silence, mute, driver clock resets and teardown clear the anchor. Camera-only
sessions and legacy microphones retain arrival-based presentation. A live anchor
that cannot map a camera timestamp safely causes a bounded frame drop and keyframe
request. Camera IPC separately validates receipt age so a future presentation
timestamp cannot refresh stale frames.

Ubuntu offers microphone3 then2; the macOS Client currently offers2. An older
Host selects2 and uses the existing SDL capture path. Optional unavailable input
does not disable desktop streaming. No native-camera transcoding is introduced.
The existing root coordinator admits the signed current desktop worker using
kernel UID/PID/audit-session identity plus its current registry generation.
A fresh shared region is allocated for each producer lease; retired producers
never get a later session's region. Root admission expires independently of
producer-writable PCM. XPC and mapping operations never run in the realtime
HAL callback. The driver sanitizes fixed-size blocks into private sample history.
The virtual input exposes 48 kHz, interleaved stereo float32 with left/right
channels. Both channels share timestamps and drift correction. Shared-memory
and control version 2 reject the previous mono layout; the Host checks the
loaded device format before advertising microphone availability. Launch schema4
keeps microphone disabled through its compatibility adapter; mono envelope
version1 is not accepted on a negotiated stereo lane.

Automatic selection is owned for the producer lifetime. It remembers the prior
input UID and restores only if PLANK is still selected; later user choices win.
Muting keeps the virtual input selected and silent, not a physical fallback.
Manual selection never changes the default. Disconnect/worker replacement
revokes production; an orphaned writer cannot keep admission alive.
