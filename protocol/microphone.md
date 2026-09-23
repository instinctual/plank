# Reverse microphone audio (in development)

This extension is not yet advertised or activated by shipping Host/Client
code. Existing even-numbered Host-created endpoints and the native/2 ALPN
remain unchanged. Do not infer support from the existence of this document.

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

Activation/mute control and capability advertisement remain implementation
gates. An old or unauthorized generation must never enter the device buffer.
No input selection, microphone capture, audio injection or public service
capability is enabled merely by compiling this transport component.
