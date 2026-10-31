# PR33: temporary macOS display mirroring

## Integration status

The operator authorized merging `macos-display-mirroring` into main on October
31, alongside Client connectivity, at package version **1.2.10**. Installed
physical-display and headless/default-off checks remain pending. No combined
mainline package was built or published as part of that merge.

PR33's later head `712a4759783e5d8b9b637e48cf973b239bca8063` was reviewed and
the operator authorized integration on October 31. `cf31832` adds virtual-display
identity readiness; `712a475` corrects the physical-trial status. The integrated
`macos-display-readiness` branch retains the renamed setting and fixes the new
fixture's use of the removed `singleDisplay` property. Combined-source hosted
validation passed and the implementation is integrated into main. Exact-source
signing approvals below are unchanged.

## Follow-up readiness review

Virtual-display creation can return an ID before WindowServer publishes its UUID.
The correction moves adoption into the existing six-second, asynchronous readiness
loop and keeps mode selection and mirroring behind confirmed ownership. It does
not add a fixed sleep. Cancellation/timeout before identification require worker
retirement, while reused-ID protection and restoration remain in place.
Default-off desktop operation and LoginWindow bypass the new adoption requirement.

The author's [unsigned hosted run 41241150325](https://github.com/cnoellert/plank/actions/runs/41241150325)
passed on SDK27, including 150 readiness assertions and 247 layout assertions.
The added fixture assumed two physical displays. Our integration expands it to
nine scenarios, including zero physical displays or dummy plugs: first connection,
changed-resolution reconnect reusing the sole PLANK output, mirroring enabled
and disabled, LoginWindow, cancellation and timeout. All Quartz/virtual-display
and power calls are substituted; no installed acceptance is implied.

Combined source `b6a9839ce79ae157a4c221f100b74a9a664f8d0b` passed
[unsigned hosted build 41250675727](https://github.com/instinctual/plank/actions/runs/41250675727)
on SDK27/minimum26.7: all nine readiness cases and 289 assertions, 247 layout
assertions, ordinary Host/transport regressions, native Installer preflight and
final app permission gates. The source comparison confirms only existing
configuration/property/diagnostic renames differ from the reviewed production
fix. No Client, Linux Host or transport implementation changed. This check
produced no signed distribution package and changed no installed Mac.

The corrected trial notes explicitly say that default-off behavior passed on
26.7 but enabled mirroring failed before streaming. Physical layout restoration
was not accepted. Earlier successful candidate builds did not contain the new
readiness fix. Installed headless and physical-display qualification remain
separate from the combined-source build checks.

## Built mirroring candidate

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

The 1.2.08 approved branch and signing-request registry remain unchanged.
Current candidate source `4dbe000d71229d5d8b97ce9ec92e0f1014502386` passed
[signed hosted build 41235998822](https://github.com/instinctual/plank/actions/runs/41235998822),
including the renamed native parser, 247 synthetic layout assertions, actual
TLS/QUIC disconnect/failure/abandoned-preparation tests and all 767 session
assertions across 24 scenarios. Ordinary Host regressions and Installer,
Developer ID, notarization, stapling and Gatekeeper checks passed. The original
PKG and checksum were verified after download; exact artifact provenance is in
`HANDOFF.md`. No installation or physical-display acceptance is implied.
The source is now integrated by the operator's explicit request; installed
gates remain pending. No Mac session was interrupted to build or collect it.
See [the investigation decision](../investigations/macos-display-mirroring.md).

## Original reviewed candidate

Reviewed [PLANK PR33](https://github.com/instinctual/plank/pull/33) at
`696815c3bc33598f4401a21d95749c369d0f92a6`. The approved test candidate is
`ba454f8713675e54e189e1d748ca00f94fbdffa4` on `macos-host-test`, version 1.2.08.
It combines that PR with main `ab92c128749d2db8b25d3b932510a865a7e624e2`, including
the native Installer requirements preflight. Only the handoff required a merge
resolution. No dependency pin changed.

## Original review recommendation

The original review recommended an isolated signed candidate before mainline
integration. The operator subsequently authorized merging the reviewed source;
this does not approve later commits or establish physical display/session
acceptance. Hosted fixtures do not prove real monitor behavior.

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
