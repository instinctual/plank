# Native PLANK transport probes

These C fixtures exercise the same native transport library and single QUIC
connection used by the Host and Client. They cover media byte equality,
microphone and camera lanes, certificate approval, cancellation and shutdown.
There is no separate transport implementation or dependency lockfile here.

Run the production transport qualification from the repository root:

```bash
scripts/test/run-plank-transport-native-loopback.sh
scripts/test/run-plank-transport-native-ffi-loopback.sh
```

See [the transport contract](../../../protocol/plank-transport/README.md) for
the current wire generation, FEC and queue bounds. The runner also executes
the controlled-loss and delivery-performance gates using the pinned production
dependencies. Hosted qualification does not substitute for installed hardware
and real-network session acceptance.
