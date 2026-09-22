# PLANK native transport library

This AGPL-3.0-or-later Rust library is the PLANK-owned boundary around
the pinned Kyber/Kynet and Quinn transport, shared by Linux and macOS products.

The public C ABI is
`include/plank_transport.h`. A caller supplies copied endpoint
configuration, starts one opaque endpoint, waits or polls its state, and stops
and destroys it. Rust owns its Tokio runtime and worker threads; it does not
call back into Host or Client C++ while a C++ lock is held. Error text remains
owned by the endpoint and is copied into caller-provided storage.

ABI version 7 provides the certificate-gated pre-session boundary. Session
setup starts with a reliable KyProto data endpoint. The Client receives the
peer leaf certificate, validates it against
the PLANK certificate profile, and explicitly approves it before any
application queue is enabled. PAM, ownership, display, and launch setup then
run on that reliable endpoint. Video, audio, and input endpoints are registered
on the same QUIC connection only after both peers authorize the session.

The version-1 `LAUNCH_RESPONSE` JSON payload carries the exact accepted
`video_format`, `host_feature_flags`, and
`reference_frame_invalidation` capability, plus the Opus sample rate, channel
count, stream counts, packet duration, and channel mapping. The Client must
install those host capabilities together with the codec/audio values before it
starts common-c. Missing local-cursor support or malformed capability values
fail the connection; there is no legacy setup fallback.

Complete Annex-B
frames use `VideoProtocol::UnreliableFec`, raw Opus uses
`AudioProtocol::UnreliableFec`, input uses KyProto's reliable input protocol,
and non-input control uses its reliable data protocol. Kyber owns media
packetization, RaptorQ, ordering, QUIC, and protocol statistics; PLANK
does not add GameStream RTP, media AES, or Reed-Solomon on this path.
KyProto currently emits repair symbols equal to 30% of each video or audio
object's source-symbol count, rounded up, with a minimum of two repair symbols.
This is fixed transport policy rather than a host configuration setting.

Each outbound lane has an independent wake-up and bounded queue, preventing a
notification for one protocol from being consumed by another. Complete video
metadata is carried in a small PLANK prefix inside the RaptorQ object
and removed after reconstruction. The native product path uses the same QUIC
connection for all registered protocol lanes.

## One sender policy

There is no application-level datagram pacer, optional pacer object, timer wait,
or paced-baseline build. KyProto submits each prepared datagram to Quinn;
Quinn's own congestion window, packet scheduling and bounded queue remain.
The Host's shared rate policy uses a 1 Gbps budget floor on every platform,
retains the existing RTT/window bounds and permits larger derived budgets.
This is transport headroom, not an encoder bitrate or guaranteed link speed.
The Client's existing default Quinn controller is unchanged.

Linux Host packaging selects `quinn-telemetry`. The macOS Host can additionally
select `macos-source-first` for its existing FEC submission order/diagnostics;
neither that feature nor default features change the sender policy. Removed
`linux-fast-send`, `macos-fast-send` and `PLANK_MACOS_FAST_SEND` switches must
not be restored for comparisons. Sender traces report FEC and Quinn work, not
the deleted pacer/sleep counters. Both sender variants require the same loss
and delivery-performance gates.

## Native wire generation and RaptorQ

The native QUIC ALPN is **`plank-native/2`**. This generation pins RaptorQ
**2.0.1** in both the production library and standalone probe lockfiles. Its
RFC 6330 repair-symbol numbering is incompatible with the RaptorQ 1.x builds
that used the `kymux` ALPN. Source symbols still have ESIs `0..K`; repairs
start at `K`, not the extended internal block size `K'`. The library handles
the conversion to internal symbol IDs. The source-first sender uses the same
systematic bytes and the library's repair encoder.

Both peers offer only the current ALPN. Old/new pairs fail TLS negotiation
before KyProto authentication, setup data or media endpoints become available.
There is no fallback, dual decoder, or extra negotiation round trip. Update
Host and Client together; a reconnect cannot repair a version mismatch. An
upgraded Client reports a matching-build requirement on a TLS protocol mismatch;
an older Client retains its existing TLS error reporting. Other certificate/TLS
failures are not relabeled as version errors. The C ABI and setup-envelope
version are unchanged; neither is the native FEC compatibility gate.

`native_version_tests.rs` exercises rejection in both directions, for setup
and direct-media entry points, plus unknown/missing ALPN rejection. The native
loopback runner requires these checks, matching-peer media byte equality and
three controlled-loss matrices. KyProto's FEC tests include fixed repair-byte
vectors, small-object repair-only recovery and multi-block/sub-block recovery.
No legacy RaptorQ crate is added to the product to perform compatibility tests.

## Cancellation and shutdown

Native endpoint stop/destroy cancels the entire asynchronous lifecycle, not
just active streaming: listener accept, QUIC/TLS handshake, KyProto
authentication, endpoint-ready waits, certificate approval, pre-session setup,
and setup-to-stream promotion all observe the same durable stop predicate.
Stop issued before a phase begins is retained; unrelated notifications do not
cancel a live endpoint. A recorded failure also cancels pending work while
preserving its original error. Completed setup cannot revive a stopping,
stopped or failed endpoint.

Cancellation drops the pending lifecycle future instead of waiting for its
configured handshake timeout. The Host then closes its QUIC endpoint and
retains the existing **one-second maximum** connection-close drain, outside
the cancelled operation, including on establishment errors. This lets the
peer observe teardown without giving an unreachable peer an unbounded wait.
Stop joins the worker before returning; start and stop serialize publication
of its join handle. Destroy includes stop and still requires exclusive ownership
of the endpoint pointer, as with any C ABI object destruction.

`native_cancellation_tests.rs` covers retained/spurious notifications, dropped
operations, failure preservation, concurrent start/stop, and real silent QUIC
handshakes. The native loopback runner additionally stalls both peers at
authentication/endpoint setup and during promotion, checks prompt stop with
30-second handshake deadlines, and verifies Host close delivery/socket release.
Wire format, ABI, authentication policy and streaming rate policy are unchanged.

## FEC receive validation and bounds

The audio and video FEC receivers validate the complete lane-specific datagram
header before reading fields. A shared validation boundary checks object length,
nonzero symbol/block/sub-block/alignment values, divisibility and partition
bounds, source-block IDs and exact symbol length before constructing or feeding
RaptorQ. Every 24-bit repair ESI at or above `K` is valid, including `K..K'`;
unique-symbol budgets still bound retained state. An object's OTI cannot change
between symbols, including while its reconstructed packet awaits delivery;
video packet sequences cannot move between pending config groups.
Reconstructed media must have a complete media header and a matching payload
length. Codec/config records on the companion reliable stream are also checked
before payload allocation; holes are generated locally, not accepted from peers.

Limits preserve the existing 64 MiB encoded-video frame plus its 16-byte native
metadata envelope, and 64 KiB audio packet, with an additional 12-byte KyProto
media header. Config payloads are limited to 1 MiB video / 64 KiB audio (PLANK
currently sends empty config payloads). RaptorQ accepts at most 131072 source
symbols per object, 56403 per source block, and twice the source-symbol count
plus 32 distinct received symbols per block. Repeated IDs do not grow memory.

Each lane admits at most 128 pending objects; video also permits at most 32
pending config groups. Admission reserves three padded object buffers plus
128 bytes per source symbol and 4096 bytes per source block, against 256 MiB
video / 8 MiB audio budgets. Completed but not yet forwarded objects retain
their charge; consuming or retiring them releases it. These are conservative
admission budgets, **not measured RSS caps**: RaptorQ solver scratch is bounded
separately by the symbol/block limits, and channel, output and Quinn buffers
remain separately bounded. A budget violation fails explicitly rather than
silently dropping arbitrary media.

Parser and processor failures propagate through the public receive result and
cancel companion readers, rather than panicking or merely logging an error
while leaving the endpoint waiting. Receive validation does not change the
ABI, 30% repair policy, 50 ms reorder policy or MTU selection. The current
wire generation and sender policy are documented above. QUIC integrity
protection means ordinary network loss is not malformed media.

The native loopback runner explicitly tests KyProto's real parsers, decoder
boundary and receive state machines through the product lockfile, in addition
to the existing encrypted round trips and three required 150 Mbps loss matrices.

## Receive queue ownership

Video/audio receive queues retain 16 frames / 64 packets respectively and
evict the oldest **unclaimed** item on overflow. Their existing drop counters
count those evictions. The synchronous receiver validates its output capacity
and removes that same front item while holding the queue mutex, then copies
the owned payload and matching metadata after unlocking. A producer cannot
evict an in-flight receive or cause that receive to remove its successor.
Input uses the same claim-before-copy rule, without changing its fail-on-full
receive policy. Concurrent readers cannot claim the same item; completion order
between independent calling threads is not guaranteed.

Insufficient output capacity reports the required size without consuming the
item. An invalid destination likewise leaves it queued. A later producer
overflow can still evict a video/audio item between that error and the caller's
retry; querying the size does not reserve an item. Zero-payload audio hole
notifications remain valid with a null buffer and zero capacity. Queue limits,
wire metadata, FEC and timeout/error codes are unchanged.

`native_receive_tests.rs` exercises the actual C entry points with forced
producer overflow and nested receivers at the unlocked copy boundary, plus
multithreaded FIFO claims, short/invalid buffers, audio holes and failure drain.
The one-shot test hook is thread-local and absent from production builds.

## Reliable-data memory limits

The shared KyProto parser rejects lengths outside 1–1048576 bytes **before**
allocating or reading the payload. The writer uses that same limit; the C ABI
imports it rather than maintaining a separate value. The four-byte big-endian
wire prefix, endpoint IDs, ABI and feature negotiation are unchanged. This
enforces the existing PLANK outgoing contract on incoming traffic as well;
there is no compatibility fallback for oversized packets. EOF is clean only
between records, not inside a length prefix or payload.

The PLANK reliable-data send and receive queues each retain at most 64 records
and 8 MiB of payload, whichever limit is reached first. Both limits apply to
setup/authentication and active sessions on both Host and Client platforms.
At most one additional record (1 MiB) per direction is being read/written by
the serial data task. These are application-payload bounds, not a claim about
total RSS or Quinn's separately bounded stream/socket buffers.

Send pressure returns the existing retryable `TIMEOUT` before making a copy.
Incoming overflow terminates the connection with a size-limit error: reliable
records are never silently evicted. Successful dequeue releases its byte
charge; a short output buffer leaves the record and charge intact. FIFO copy
and removal share one lock, including concurrent C ABI readers. Video/audio
datagrams, RaptorQ, Wacom input and the 512 KiB clipboard limit are unchanged.

`tests/reliable-data.rs` runs the maintained parser regression tests through
the product lockfile. Native queue tests cover byte/count limits, retry and
variable-size accounting. The native loopback runner also floods the actual
encrypted reliable-data receiver in both directions and requires a bounded,
explicit failure with the already queued records preserved.

Run the Rust and real C ABI checks with the pinned toolchain and offline Cargo
cache:

```bash
cargo test --locked --offline \
  --manifest-path protocol/plank-transport/Cargo.toml
cargo clippy --locked --offline \
  --manifest-path protocol/plank-transport/Cargo.toml \
  --all-targets -- -D warnings
scripts/test/run-plank-transport-ffi-loopback.sh
scripts/test/run-plank-transport-native-loopback.sh
scripts/test/run-plank-transport-native-ffi-loopback.sh
```

The native C loopback verifies exact-fingerprint and certificate-profile trust,
pre-session data with media/input blocked, explicit same-connection promotion,
a 192-KiB key frame and metadata, raw Opus, Wacom-like input, and reliable data
in both directions through real encrypted KyProto endpoints. The standalone saturation probe remains useful historical
evidence for the tunneled implementation, but its split-connection and BBR
results are not assumed for the new one-connection native baseline.
