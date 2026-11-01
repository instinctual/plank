# Host-aware bookmark options and Mac display matching

Branch: `bookmark-host-options`, based on accepted main `d6c4598`.
Accepted and merged September 8: Client main `a803e0dc`, root acceptance tip
`cef37c8`, both published. Later root closeout changes are documentation only.

## Scope

Enable Match client display(s) for the existing macOS Host, and filter Add/Edit
capture and encoding choices by a reachable Host's advertised capabilities.
This is a Client-only change. No Host, input, media, transport or decoder
policy change is required.

## Behavior

- Public PLANK metadata identifies the supported Linux/Mac contract. It is
  only a UI hint, never authentication, certificate trust or exact-format proof.
- Address entry is debounced; at most one fast-fail lookup runs at a time.
  Stale replies cannot filter another address or a closed dialog.
- Known Linux Hosts show NvFBC/native-X11 and their existing encoding models.
  Known Macs show ScreenCaptureKit and the two Apple VideoToolbox profiles.
  Unreachable, unknown and unsupported Hosts retain all manual choices.
- Mac bookmarks preserve either Match client display(s) or a fixed resolution.
  Existing fixed bookmarks remain fixed. Filtering does not rewrite bookmarks
  until the operator saves them.
- At authentication, Qt screen geometry and device pixel ratio resolve the
  native-pixel request before creating session windows. The existing
  authenticated display schema 2 requests that size and the selected profile.
  The session uses the selected Qt screens; a topology change fails
  clearly instead of launching mis-scaled video/input.
- One or two horizontally arranged client monitors map to one Mac virtual
  canvas. The existing qualified resolutions and 5120x2160 maximum apply.
  Unsupported combinations require a fixed resolution; there is no silent
  downscale, arbitrary-resolution extension or new dual-Mac-output feature.
- Reconnect uses the same native-client canvas and existing authenticated
  generation/profile validation. Linux Match Client behavior is unchanged.

## Validation and next step

linux-client-builder Qt6.10.2: topology suite 16 tests pass; shared QML capture chooser
suite 3 tests pass. Coverage includes native4K/5K, 125%/200% logical geometry,
two2560x2160 screens, oversized/stacked/empty layouts, supported/unknown feature
contracts, delayed stale discovery replies and offline/manual choices.
These are automated logical/QML checks, not physical-monitor acceptance.

Intermediate1.0.65 clean compile/package gates pass. Review adds queued local
authentication-error completion (preserving the caller's asynchronous UI
contract) and a locked copy of authenticated geometry. The final candidate
advances to1.0.66;1.0.65 is internal validation only, not the handoff package.
The actual NvComputer persistence/parser test also passes, preserving Match
and fixed layout, both Apple profiles and independent profile bitrates.

The shared-selector label gate now follows PlankCaptureSourceBox.qml and
requires both dialogs to use that component. The new QML/topology/persistence
tests are part of normal Client package preflight.

The clean1.0.66-bookmark-host-options Client package is built and retained with
its checksum in artifacts/packages. Source root f7832bfd50cc0816e92cbe2ae85609818cd2eb03,
Client a803e0dc6d2e0846d4153d0a1c8dced8267fc39b. All package preflight, compile,
private runtime, manifest, version, dependency, logging and autostart-absence
gates pass. Existing FFmpeg deprecation/Quinn dead-code warnings remain.
Final packaged UI smoke passes real public Mac discovery, Add/Edit round-trip,
both Apple profile choices, Match/fixed controls and offline/manual selection.
No QML binding/type errors were recorded. Rendered screenshots were inspected;
they and build logs are in ignored build/bookmark-host-options-records.

No candidate was installed by the agent on a builder or End-User client. Development NUC
was unreachable (no route). No Host restart, authentication, stream or display
change was performed by the UI smoke test.

**Accepted September 8:** the operator reported "that passes" and requested
commit, push and merge. This accepts the candidate's requested bookmark
behavior; it does not independently document every resolution, scaling or
multi-monitor combination. Existing1.0.64 Mac Host remains installed.
No new package, tag or deployment accompanies this source integration.
The accepted DEB/checksum and qualification logs/screenshots remain retained.
After publication, this task's exact linux-client-builder candidate/test directories
were removed; canonical repositories and prepared dependencies were preserved.

## Packaged UI smoke test

`tests/protocol/client-bookmark-ui-smoke.cpp` is a standalone Linux test-only
preload, never linked or shipped with the application. It opens the actual
packaged Add/Edit dialogs, queries a specified live Mac's public metadata,
checks filtered models and Match/fixed controls, and saves screenshots. It
creates one bookmark only inside explicitly isolated XDG paths; it never
authenticates or launches a stream. Compile with `g++ -shared -fPIC -std=c++17`
and the `Qt6Core Qt6Gui Qt6Quick Qt6Qml` pkg-config flags. Run the extracted
Client ELF with that library in LD_PRELOAD, `QT_QPA_PLATFORM=offscreen`,
`QT_QUICK_BACKEND=software`, fresh XDG_CONFIG_HOME/XDG_STATE_HOME/XDG_CACHE_HOME
and a private0700 XDG_RUNTIME_DIR. Set PLANK_UI_SMOKE_HOST explicitly to the
authorized development Mac and PLANK_UI_SMOKE_DIR to the screenshot directory.
Keep a30-second external timeout. Never preload it into an installed/live
Client or use an existing user's settings.
