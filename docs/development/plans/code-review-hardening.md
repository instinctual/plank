# Code review hardening

Branch: `code-review-hardening`, based on main `b8a0f1a8`.

The operator requested implementation of every finding in the repository-wide
review. Preserve current codec/color, persistent tablet, authentication, and
platform contracts. Build checks do not replace installed session acceptance.

## Work and validation

- [x] Bound Linux HTTPS requests before buffering; fix the malformed 404.
- [x] Bound KyProto control frames and propagate control-task failure.
- [x] Isolate datagram endpoint backpressure and tolerate endpoint retirement.
- [x] Replace detached common-C termination callbacks with owned completion.
- [x] Reset transient Linux input state while preserving tablet identity.
- [x] Bound/cancel Linux PulseAudio operations and capture shutdown.
- [x] Remove Sunshine path migration and unsupported product alternatives.
- [x] Remove unreachable AV1 encoding and unused Host utilities.
- [x] Remove retired Client helpers/tests and retain live Qt regression coverage.
- [x] Remove unused artwork/XML helpers, game metadata and false audio telemetry.
- [x] Remove unused alternate transport setup mode; document the shipping flow.
- [x] Select affected CI products while preserving explicit full qualification.
- [x] Scope dependency cache keys to actual product dependency inputs.
- [x] Eliminate redundant compressed-frame copies with bounded owned buffers.
- [x] Evaluate Native X11 capture overhead without weakening resize/color checks.
- [ ] Run affected component, sanitizer, package and transport qualification.
- [ ] Record exact commits, artifacts, results and remaining installed-test gates.

No release publication, deployment or merge is implied by this branch.

## Verification recorded so far

- Portable root packaging/privacy tests: 8/8 passed, including the repaired
  bootstrap fixture that executes the current FFmpeg identity validator.
- CI product/cache/signing policy: 130 tests passed.
- Common-C lifecycle: 941 assertions, including simultaneous failure callbacks;
  AddressSanitizer/UndefinedBehaviorSanitizer pass. Common-C component suites pass.
- Native X11 capture/color and CUDA-registration fixtures pass with sanitizers.
  The existing 5120×2160 depth-30 desktop passed read-only geometry/SHM checks.
  Median capture was 6.07 ms with batched queries and 5.99 ms with cached geometry:
  two queries removed per steady frame, but no material frame-rate gain claimed.
- Shared transport: Linux loss/stall gates passed. On the authorized development
  Mac, the exact hosted `sender-timing` executable passed all three 150 Mbps
  matrices: 2,700 frames, zero unrecovered frames, worst delivery 16.796 ms,
  worst p95 11.827 ms, worst receive gap 23.610 ms. No active session was interrupted.
- Exact Rust integration filters now fail if they execute zero tests. The retired
  setup-promotion fixture is replaced by active certificate-approval cancellation.

Package, Linux HTTPS/audio integration and live installed-session acceptance
must be recorded separately. A local ThreadSanitizer attempt could not link
because that runtime is absent; this is not a ThreadSanitizer pass.

The retained native Apple branch has its own protocol pin and is unchanged.
When rebasing it to ABI 14, remove its `config.session_mode` assignment and
`SETUP_READY` allowance. It does not use common-C termination callbacks.
