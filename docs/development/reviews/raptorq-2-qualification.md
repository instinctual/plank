# RaptorQ 2.0.1 upgrade qualification

This coordinated, breaking transport upgrade is developed on `raptorq-upgrade`,
from the complete `code-review-fixes` checkpoint, root
`91eba02d39c0923008a3f7c9595636aa2b891d09`. It retains the identity, PAM,
parser/allocation, FEC validation, cancellation and render-shutdown fixes.
It is not a merge to main or a deployed release.

## Wire contract

The [upstream 2.0.0 release](https://github.com/cberner/raptorq/releases/tag/v2.0.0)
changes repair IDs to RFC 6330 Encoding Symbol IDs. Version
[2.0.1](https://github.com/cberner/raptorq/releases/tag/v2.0.1) adds performance
improvements; upstream speedup claims are not PLANK benchmark results.
KyProto pins `=2.0.1`; production and probe locks carry the same crate checksum.
No other runtime dependency version changes.

For a block with `K` source symbols and `K'` extended internal symbols, old
RaptorQ used wire repair IDs starting at `K'`; 2.x starts at `K`. The retained
standalone compatibility probe drops three source symbols from a deterministic
5000-byte object. Both same-version combinations recover exact bytes. Both
mixed-version combinations complete with **incorrect bytes**, rather than
necessarily reporting a decode failure. That is why release-number warnings
or no-loss testing are insufficient.

The shared Kynet fork offers only `plank-native/2` during native QUIC TLS.
Old peers offering `kymux` are rejected before KyProto auth/setup/media; there
is no dual decoder, legacy fallback or additional setup round trip. The C ABI,
setup envelope and endpoint manifest are unchanged. New peers report that both
Host and Client need matching builds; old Clients retain their old TLS-error
wording. Only TLS `no_application_protocol` is translated to this message.

The receiver no longer mistakes valid repair ESIs `K..K'` for implicit padding.
All length, partition, symbol-count, consistency, allocation and pending-object
bounds from the security review remain. Source-first transmission still uses
the existing systematic bytes and upstream repair encoder. The 30% repair
policy, MTU, queue sizes, rate controller, 1 Gbps send-budget floor, encoder
settings and codec precision are unchanged. During qualification the operator
also authorized deleting the disabled application datagram pacer, its optional
fields/timers, platform feature switches, paced-baseline build selection and
obsolete diagnostic columns. All builds now use the same existing sender
budget policy; Quinn's own scheduling remains. This removes a confusing test
selection without relaxing the delivery-performance checks.

## Test contract

- Fixed upstream-generated repair-byte vectors (including ESI), decoded through
  both audio/video datagram layouts, plus repair-only recovery of small objects.
- Multi-block/sub-block repair, systematic-byte equality and malformed-packet,
  memory-budget, deduplication and telemetry tests.
- Actual TLS mismatch rejection in both directions for native setup and direct
  media sessions, also rejecting unknown or missing protocol identifiers.
- Matching-peer encrypted video/audio/input/data and both C ABI trust modes,
  including setup promotion, bounded cancellation and queued control at close.
- Three consecutive 150 Mbps / 60 fps loss matrices per sender configuration,
  injecting 0/0.5/1/3/5% datagram loss. Each run checks 900 complete frames,
  byte equality, before/after-FEC telemetry and per-phase delivery performance.

Use pinned Rust 1.89.0 and the locked dependency graph. On Linux, the normal
Host selection is `quinn-telemetry`. To additionally exercise the macOS
source-first algorithm on that builder, use `quinn-telemetry,macos-source-first`.
Both now use the identical sender policy without platform overrides. Do not
present these Linux runs as native macOS/Apple Silicon qualification.

Results and remaining package/hardware gates are recorded in HANDOFF. Full
Linux/macOS Host/Client packages must be rebuilt together, with a new candidate
version and branch-qualified filenames/banners. Existing pre-upgrade artifacts
must not be relabeled or mixed with new peers. No machine deployment is implied
by local transport qualification.
