# PlankTransport QUIC probe

This standalone AGPL-3.0-or-later probe exercises Kyber `kynet`/Quinn at the
exact commit pinned by the root repository. It does not link into or alter the
PLANK Host or Client transport.

The probe overrides `quinn-proto 0.11.19` with the exact vendored source plus
a documented DATAGRAM send-buffer accounting backport. See
`third_party/quinn-proto-0.11.19/PLANK-PATCH.md` for upstream commit provenance
and removal criteria.

The default `quinn-bbr` feature explicitly selects Quinn's experimental BBR
controller for qualification. Build with `--no-default-features` to reproduce
the upstream CUBIC behavior. Every result line identifies the active
congestion controller.

Media production uses fixed-capacity application queues: 64 video datagrams
and eight audio datagrams. The single sender always dequeues audio first. On
overflow, the oldest queued item in that lane is evicted so the queue remains
bounded and fresh; result lines report both eviction counts and the total queue
high-water mark.

The server sends a paced synthetic video lane and a 200 Hz audio lane over
QUIC DATAGRAM on a role-authenticated media connection. At the same time, the
client sends a 1 kHz replaceable-motion lane over QUIC DATAGRAM and a 200 Hz
critical-input lane over a reliable bidirectional stream on a separate
role-authenticated interaction connection. Both QUIC connections terminate at
the same server UDP socket and port. The critical-input records are echoed so
the client can report median and p99 round-trip latency while the media data
plane is saturated.

The protocol accepts either connection arrival order. It rejects duplicate or
unknown roles, an invalid bearer token, and connections whose role tokens do
not belong to the same session before starting any media or input lane. The
loopback runner exercises every one of those cases.

Use the pinned Rust toolchain and run:

```bash
scripts/test/run-plank-transport-loopback.sh
```

The defaults are a three-second, 150 Mbps video test on loopback UDP port
47489. They can be changed without editing source:

```bash
PLANK_TRANSPORT_DURATION=10 \
PLANK_TRANSPORT_BITRATE_BPS=100000000 \
PLANK_TRANSPORT_PORT=47490 \
scripts/test/run-plank-transport-loopback.sh
```

The script generates a short-lived certificate in a private temporary
directory, pins its SHA-256 hash on the client, uses a probe-only bearer token,
and removes the temporary directory when it exits. The command-line token is
acceptable only for this qualification utility; the product data plane must
receive its one-time token from the authenticated HTTPS control plane.

For a two-machine run, generate or supply a certificate, then invoke the
binary's `server` and `client` modes shown by running it without arguments.
Open only the selected UDP port for this probe.

```bash
PLANK_TRANSPORT_LOSS_PERCENT=5 \
PLANK_TRANSPORT_LOSS_PATTERN=random \
scripts/test/run-plank-transport-crosshost.sh
```

The Development NUC address, server address, duration, bitrate, port, and loss
percentage are environment-overridable. The runner requires key-based SSH and
passwordless access to the narrowly scoped local `nft` commands. It does not
install a package or persistent service on the client.

`PLANK_TRANSPORT_LOSS_PATTERN=periodic-burst` drops the configured
number of consecutive packets in each 100-packet cycle. The default `random`
mode uses independent random drops. Result lines include per-lane observed
sequence gaps and stale arrivals; stale state is counted and discarded rather
than applied.
