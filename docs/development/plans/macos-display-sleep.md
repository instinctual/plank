# macOS display wake and idle sleep

## Problem

An idle display slept during an authenticated remote session. Capture reported
an inactive output; subsequent preparation attempted a mode change before wake.
After worker retirement, WindowServer rejected the replacement's fixed virtual
display identity as already registered. A short administrator-requested console
wake cleared that rejection and the same running worker created its display.
This was display idle sleep, not a running screen saver or a Host process crash.
Private machine evidence is retained outside Git.

## Implementation

- Authenticated display preparation requests console wake before creating,
  reconfiguring or snapshotting a display layout. Existing displays must be
  active and not asleep. A truly headless first launch can create its initial
  output without waiting for a nonexistent physical monitor.
- Preserve the existing six-second preparation deadline, authority checks and
  main-queue ownership. Retry rejected registration at most once per 250 ms
  inside that deadline, always using the same identity. Do not manufacture
  another monitor, restart WindowServer or change sleep preferences.
- A failed first preparation can wake the existing desktop without inventing
  a previously successful mode, allowing topology and preparation to retry.
- Hold `PreventUserIdleDisplaySleep` during preparation and during an
  authenticated stream's connection/streaming lifetime. Release it on every
  failure, cancellation, stop and abandoned-owner path, before capture drain.
  A failed power assertion stops that operation clearly rather than silently
  promising protection that was not obtained.
- Use the same console-user activity type as actual remote input. Wake is a
  one-time connection action, not periodic fabricated input. Screen lock,
  explicit sleep and lid-close policy remain under macOS control.

No Client, Linux Host, transport schema or administrator configuration changes
are required. The macOS Host retains one package for macOS 26.7 and newer.

## Validation

The production display implementation is exercised with substituted Quartz and
IOKit calls on the SDK27 hosted worker. Cover active-but-asleep outputs, delayed
wake before custom/HiDPI mode changes, initial headless creation, delayed stale
registration cleanup, cancellation, wake failure, power-assertion failure and
balanced assertion release. Existing physical-mirroring/identity and headless
readiness tests remain required.

The real QUIC/synthetic capture session fixture checks that protection exists
only after session start, remains during streaming, and is gone before deferred
capture stop. Existing authorization, topology-change, startup-timeout, teardown
and owner-abandonment cases must all release it. Also cover unstarted owners and
power-assertion creation failure.

Hosted tests and a signed candidate are pending. Installed acceptance must
verify reconnect from display sleep, custom/HiDPI resolution selection and a
session exceeding the configured display idle timer, followed by disconnect
with no remaining PLANK idle-display assertion. Preserve the user's desktop;
do not induce logout/reboot or explicit sleep without authorization.
