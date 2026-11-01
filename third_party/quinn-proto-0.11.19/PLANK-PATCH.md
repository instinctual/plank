# Vendored Quinn integration

Base: crates.io `quinn-proto 0.11.19`, archive SHA-256
`0e750cca55fe4f0439a15d0bb529da9651e79993e8e72c61a899a36d462befbe`.
Original licenses, VCS provenance and upstream tests are retained.

Quinn 0.11.19 incorporates the earlier PLANK send-buffer accounting,
single-datagram capacity and inclusive MTU-boundary repairs. Its native
`DatagramState::make_space_for`, overflow checks, blocked-sender wakeups and
`drop_oversized` return value are used unchanged. The old replacement queue
implementation is removed. Both upstream regression cases and PLANK's retained
MTU/queue tests exercise this implementation.

Remaining local changes:

- Separate queue-capacity eviction and MTU-discard counts/bytes, plus queue high
  water marks. These additions do not choose which packets to drop.
- Owned `ConnectionStats::plank_telemetry` snapshots under `plank-telemetry`,
  with the existing congestion/pacing/RTT observability. No formatting, logging,
  allocation or writer wait occurs under the connection lock. Kynet consumes
  the snapshot after Quinn releases its guard and uses its existing bounded,
  non-waiting diagnostic queue.
- The opt-in `plank-bbr-default` probe feature. Production still supplies its
  explicit PLANK controller; no production congestion policy is changed.

Production and standalone probes patch crates.io to this single directory.
Keep their lockfiles, adapter and the vendor's own test lock synchronized with
compatible Quinn 0.11.12 / quinn-udp 0.5.16. Do not substitute UDP 0.6 merely
because it is a higher independently published version.

Linux Host packaging runs `connection::datagrams::plank_tests`, upstream
`connection::datagrams::tests` and the feature-enabled owned-snapshot test.
Transport tests also cover the real bounded adapter logger and native loss
matrix. Component results do not replace installed session/loss acceptance.

Remove this override only when released Quinn supplies the required diagnostic
surface or its callers are deliberately migrated, and transport qualification
passes. Upstream's security and protocol fixes must not be replaced with the
older local implementation when refreshing the vendor.
