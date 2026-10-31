# PR33: temporary macOS single-display sessions

Reviewed [PLANK PR33](https://github.com/instinctual/plank/pull/33) at
`696815c3bc33598f4401a21d95749c369d0f92a6`. The approved test candidate is
`ba454f8713675e54e189e1d748ca00f94fbdffa4` on `macos-host-test`, version1.2.08.
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
exercise Quartz. The PR author's reported macOS26.7 build and synthetic-layout,
runtime-release and teardown tests remain author evidence until reproduced by
the hosted candidate build. Check the build linked from PR33 for its exact
result and signed artifact.

Remaining installed tests on the same candidate PKG:

- Verify the default extended-display behavior is unchanged on26.7 and27.
- Enable single display; connect, disconnect and reconnect with physical
  monitors present. Confirm the original modes, arrangement and mirroring return.
- Exercise a preexisting mirrored layout, hotplug, failed setup and crash
  recovery. Verify window and Spaces placement rather than assuming mode
  restoration also guarantees application-window restoration.
- Check login/logout and session takeover, especially delayed display cleanup
  racing a newly prepared session. Chris owns26.7 hardware qualification.

No live machine was changed for this review. The published release is unchanged.
