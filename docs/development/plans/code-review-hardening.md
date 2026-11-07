# Code review hardening

Branch: `code-review-hardening`, based on main `b8a0f1a8`.

The operator requested implementation of every finding in the repository-wide
review. Preserve current codec/color, persistent tablet, authentication, and
platform contracts. Build checks do not replace installed session acceptance.

## Work and validation

- [ ] Bound Linux HTTPS requests before buffering; fix the malformed 404.
- [ ] Bound KyProto control frames and propagate control-task failure.
- [ ] Isolate datagram endpoint backpressure and tolerate endpoint retirement.
- [ ] Replace detached common-C termination callbacks with owned completion.
- [ ] Reset transient Linux input state while preserving tablet identity.
- [ ] Bound/cancel Linux PulseAudio operations and capture shutdown.
- [ ] Remove Sunshine path migration and unsupported product alternatives.
- [ ] Remove unreachable AV1 encoding and unused Host utilities.
- [ ] Remove retired Client helpers/tests and retain live Qt regression coverage.
- [ ] Remove unused artwork/XML helpers, game metadata and false audio telemetry.
- [ ] Remove unused alternate transport setup mode; document the shipping flow.
- [ ] Select affected CI products while preserving explicit full qualification.
- [ ] Scope dependency cache keys to actual product dependency inputs.
- [ ] Eliminate redundant compressed-frame copies with bounded owned buffers.
- [ ] Evaluate Native X11 capture overhead without weakening resize/color checks.
- [ ] Run affected component, sanitizer, package and transport qualification.
- [ ] Record exact commits, artifacts, results and remaining installed-test gates.

No release publication, deployment or merge is implied by this branch.
