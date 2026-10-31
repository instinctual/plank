# PR33: temporary macOS display mirroring

## Current candidate

The operator chose the simpler mirroring implementation after comparing it
with independent virtual displays and physical-output deactivation.
`macos-display-mirroring` integrates the reviewed PR head below into main
`d9e0ca5339f205c1f06bf6c811bb4b6eebb8812d`, with package version **1.2.09**.
The public setting is now `[general] mirror_host_displays`; the internal
configuration/property names follow it. It remains off by default. Session
ownership, capture, rollback and restoration behavior are unchanged from PR33.
The shipped comments distinguish mirroring from disabling physical screens and
from creating one virtual monitor per Client display. No compatibility alias
for the pre-release `single_display` name is included.

The 1.2.08 approved branch and signing-request registry remain unchanged; their
validation below does not count as a build or hardware pass for 1.2.09. Current
source, build evidence and remaining gates are recorded in `HANDOFF.md`.
See [the investigation decision](../investigations/macos-display-mirroring.md).

## Original reviewed candidate

Reviewed [PLANK PR33](https://github.com/instinctual/plank/pull/33) at
`696815c3bc33598f4401a21d95749c369d0f92a6`. The approved test candidate is
`ba454f8713675e54e189e1d748ca00f94fbdffa4` on `macos-host-test`, version 1.2.08.
It combines that PR with main `ab92c128749d2db8b25d3b932510a865a7e624e2`, including
the native Installer requirements preflight. Only the handoff required a merge
resolution. No dependency pin changed.

## Recommendation

Suitable for an isolated signed test candidate. Keep the PR outside main until
physical display/session validation is reported. This is approval of the exact
reviewed source for testing, not blanket approval of later commits or a claim
that hosted fixtures prove real monitor behavior.

## Scope and review

- `[general] single_display` defaults to false. When enabled, PLANK's virtual
  display temporarily becomes the mirror master; physical screens show the same
  workspace. This is not a physical-screen privacy/blackout feature.
- Native app-lifetime Quartz configuration snapshots display identities, modes,
  arrangement and mirror relationships. Application is verified by readback;
  restoration checks identity and does not overwrite a replaced user's desktop.
- Display preparation has a generation and a bounded lifetime. Session release
  occurs after input/media drain; failed setup, abandoned preparation, normal
  disconnect and shutdown also release it. Delayed cleanup cannot restore over
  a newer preparation. The stop notification leaves the session queue before
  acquiring runtime state, avoiding the takeover lock cycle.
- The retained idle virtual display mirrors the restored main display so it
  does not leave an invisible extended workspace. Restoration failure retires
  the graphical worker. Hot-added displays are not silently incorporated into
  the original restoration snapshot.
- The review covered all changed Host code, build/probe/test scripts and
  documentation. No signing-policy, dependency, authentication-policy, input
  posting or transport change was found. The new test command uses the existing
  signing workflow, and no contributor source runs in its request controller.

## Validation

The merged candidate passed 98 portable CI-policy tests, two Installer packaging
preflight tests and whitespace/privacy checks. These ran on Linux and do not
exercise Quartz. The request controller also passed 16 authorization/dispatch
tests (114 total CI-policy tests on main) and its actual GitHub comment-to-build
path was exercised by the owner.

[Hosted build 41223854554](https://github.com/instinctual/plank/actions/runs/41223854554)
then passed on macOS 27 at the exact candidate SHA. It reproduced the 247
synthetic Quartz layout assertions, the actual TLS/QUIC runtime fixture for
disconnect/failure/60-second abandoned preparation, and 767 session assertions
across 24 scenarios, alongside existing Host regressions. Physical displays and
live capture/input were not exercised. The signed package passed Developer ID,
notarization, stapling, Gatekeeper and native Installer preflight package gates;
Installer UI and installation were not performed. Both dependency caches were
reused, and signing material was removed after the run.

[Signed candidate artifact](https://github.com/instinctual/plank/actions/runs/41223854554/artifacts/13051455737):
`plank-host_1.2.08-macos-host-test-macos26.7_arm64.pkg`, SHA-256
`e2c00abb9f329f226724fef760e3cff891f5410fdad58e74186b8fa0b3785aa1`.
The original was downloaded, verified and collected in the local candidate
catalog. Hosted evidence does not independently verify the author's 26.7 session
results, nor establish physical monitor acceptance on either OS.

Remaining installed tests on the same candidate PKG:

- Verify the default extended-display behavior is unchanged on 26.7 and 27.
- Enable display mirroring; connect, disconnect and reconnect with physical
  monitors present. Confirm the original modes, arrangement and mirroring return.
- Exercise a preexisting mirrored layout, hotplug, failed setup and crash
  recovery. Verify window and Spaces placement rather than assuming mode
  restoration also guarantees application-window restoration.
- Check login/logout and session takeover, especially delayed display cleanup
  racing a newly prepared session. Chris owns 26.7 hardware qualification.

No live machine was changed for this review. The published release is unchanged.
