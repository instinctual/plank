# macOS Client build inputs and procedure

Build one experimental Apple Silicon Client for macOS15 and newer with SDK27
or newer. The deployment target is 15.0 throughout the app, dependencies, and
DMG; there is no separate reduced-capability macOS15 edition. Newer APIs must
use runtime availability checks so macOS27 retains its capabilities. The Host
stays macOS27-only. Read the canonical release runbook first. Linux builder/test
roles remain unchanged. Use clean Git worktrees and verified Git bundles
imported dependency-first, with recursive fetch disabled.

`macos-client-target.sh` exports the common deployment policy. Do not set
`PLANK_MAC_CLIENT_MIN_MACOS=27.0` from an old shell: it is rejected instead of
silently producing a different package. The dependency cache includes the
target and policy file, forcing a fresh build of older 27-minimum libraries.
Local prepared dependencies must be fully bootstrapped again when changing
this target; an FFmpeg-only rebuild is insufficient. Every bundled Mach-O must
contain arm64 with a minimum OS no newer than15, and the app plist must say15.0.
The build runs real Mach-O positive/negative fixtures for this gate on the Mac.
The same resulting DMG must pass live acceptance on macOS15 and macOS27; the
hosted SDK27 build alone cannot establish that. See
[the current integration review](../macos15-integration-review.md).

For hosted candidates use [GitHub builds](github-builds.md), including the
exact-input dependency cache and explicit clean-bootstrap option. The local
recipe below is for separately authorized/self-managed builders, not a silent
fallback from a failed hosted run.

Install Xcode/SDK27 and accept its license before bootstrap. Required tools are
Apple clang/make/git, Python3 with `venv`/pip, curl, tar, patch and CMake. The
bootstrap finds the official CMake app in `/Applications/CMake.app/Contents/bin`
or `cmake` on PATH; install CMake separately, as Xcode does not supply it.
Rust1.89.0 bootstrap is covered by the Host runbook. Signing certificates are
not needed for these dependency/application compilation steps; see
[building a fork](from-source.md) for the separate distribution requirements.

The dedicated Mac retains its canonical clone under `~/dev/plank` and private
inputs under `~/Library/Caches/plank-build`. Export these machine-specific
values explicitly; never infer a path from an old candidate directory:

```bash
export PLANK_CANONICAL_ROOT="$HOME/dev/plank"
export PLANK_DEP_ROOT="$HOME/Library/Caches/plank-build"
export PLANK_WORK_ROOT="$PLANK_DEP_ROOT/work"
export PLANK_MAC_CLIENT_DEPS="$PLANK_DEP_ROOT/macos-client-deps"
export PLANK_QT_ROOT="$PLANK_DEP_ROOT/qt-6.10.2/6.10.2/macos"
export PLANK_RUSTUP_ROOT="$PLANK_DEP_ROOT/rustup-1.89.0"
export PLANK_CARGO_ROOT="$PLANK_DEP_ROOT/cargo"
export PLANK_BUILD_BRANCH=macos-client
```

Bootstrap Qt once with a private Python venv and aqtinstall3.3.0:

```bash
python3 -m venv "$PLANK_DEP_ROOT/bootstrap/aqt-3.3.0"
"$PLANK_DEP_ROOT/bootstrap/aqt-3.3.0/bin/pip" install aqtinstall==3.3.0
"$PLANK_DEP_ROOT/bootstrap/aqt-3.3.0/bin/aqt" install-qt mac desktop \
  6.10.2 clang_64 --outputdir "$PLANK_DEP_ROOT/qt-6.10.2" \
  --archives qtbase qtdeclarative qtsvg qttools qtshadertools
```

Official Qt archives contain both architectures; product builds select arm64.
The installer verifies the upstream archive checksums. Retain its installation
log and Python dependency inventory. No Homebrew dependency on moving versions.

Set `PLANK_SOURCE_ROOT` to a complete source checkout with the exact Client
gitlink initialized BEFORE preparing FFmpeg. Then run:

```bash
bash "$PLANK_SOURCE_ROOT/scripts/build/bootstrap-macos-client-deps.sh"
```

The script pins archive SHA256 values and prepares private OpenSSL3.5.5,
Opus1.5.2, SDL3.4.2, SDL_ttf3.2.2, FreeType2.14.1 and FFmpeg9.0.1. It applies
the same required HEVC identity-GBR patch as Linux (also enables VideoToolbox
format probing). A missing Client checkout is an input-preflight error, not a
compiler failure. `ffmpeg` as the optional argument resumes only that stage.
Candidate builds must independently reverse-dry-run that patch and verify its
hash. Private dylibs must be bundled with relocatable install names, licensed,
signed and closure-checked before any package is offered to a user.

SDL3.4.2 uses its unmodified native fullscreen Spaces implementation. Match
Client requests the usable logical/backing area below a display's camera inset;
non-notched displays retain the complete area. No content-size delegate patch
or custom fullscreen hint is required. The changed bootstrap/cache inputs force
a fresh hosted dependency build after removal of the experimental SDL patch.
For local prepared dependencies, rerun the complete bootstrap, not FFmpeg-only.

The current packaging path is qualified; each new candidate still requires its
affected live acceptance gates. Do not use the old upstream setup-deps/prebuilts
workflow.

## Build and package

Initialize Client, common-c, qmdnsengine and Kymux at their exact gitlinks from
verified local Git bundles/mirrors. Do not initialize the Linux Host to build
this Client. Import Client bundles before root bundles and always fetch with
`--recurse-submodules=no`. The Mac canonical origin may still be an old
bootstrap bundle, so fetching that origin is not a source update.

```bash
bash "$PLANK_SOURCE_ROOT/scripts/build/build-macos-client.sh" \
  "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/client-build"
```

For repeated local Wacom tests, `stage-macos-client-dev.sh` can use a stable
code-signing identity from the local keychain. Set
`PLANK_MACOS_DEV_SIGNING_IDENTITY` to its 40-character SHA-1 identifier before
staging. The default remains ad hoc signing. Every changed ad hoc build has a
new `cdhash` requirement, so macOS may reject its prior Input Monitoring grant;
the operator must approve any new grant through System Settings. A signed
development app remains unnotarized and is not a distributable release. Do not
put signing-key passwords in scripts or environment variables.

For a self-contained PKG and DMG containing that installer, in the signing SSH session:

```bash
export PLANK_MACOS_SIGNING_IDENTITY=DEVELOPER_ID_APPLICATION_SHA1
export PLANK_MACOS_INSTALLER_IDENTITY=DEVELOPER_ID_INSTALLER_SHA1
export PLANK_NOTARY_PROFILE=plank-notary
bash "$PLANK_SOURCE_ROOT/scripts/package/build-macos-client-dmg.sh" \
  "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/client-package"
```

Output must be a new directory. An optional absolute `PLANK_MAC_CLIENT_BUILD`
may point to a retained build; qmake/make still run, and staging/closure/signing
are fresh. Unlock the signing keychain interactively in that SSH session, not
by putting a password in arguments, environment, scripts or notes. Preserve
the session through signing. PKG and DMG must pass notarization, staple and Gatekeeper;
collect both exact files in the artifact catalog and compare SHA256 on both ends.
No installer service/autostart is created; uninstall by quitting and moving
the app to Trash. The PKG creates root-owned `/etc/plank/client.conf` only if
absent; existing policy is preserved. It ships the latest reference template in
app Resources. Host installation/permissions are separate and unchanged. See
[macOS configuration](../../user/macos-configuration.md). Before packaging, run
`scripts/test/build-macos-configuration.sh SOURCE NEW_OUTPUT`; this compiles and
tests the actual configuration installer against temporary fixtures, not the
installed machine. Signing CI already provisions both Developer ID identities.

## Known failure signatures

- Optional media permission requests belong to the ordinary launcher, not
  session constructors: microphone consent completes asynchronously before the
  bookmark UI is created; attached USB Wacom Input Monitoring is requested there
  without opening devices. CLI autoconnect and toolbar toggles query grants
  only. See [permission timing](../../user/permissions.md), including denial,
  hot-plug and OS-controlled exceptions. `macos-microphone-permission.mm` uses
  fake AVFoundation authorization and `client-microphone` uses SDL dummy input;
  neither native build test may request real TCC consent or open hardware.
- macOS system shortcuts require the Client's Accessibility authorization when
  Capture system keyboard shortcuts is enabled. The session-scoped public
  Core Graphics modifying tap queues keyboard input for the existing input
  handler; it does not post synthetic OS input or change global preferences.
  Native stream focus, the fullscreen/always policy, and capture release gate
  activation. Missing permission prompts once per process in the ordinary
  launcher at startup (only if shortcut capture is enabled), or when enabled
  later in Settings. CLI autoconnect never prompts; open the ordinary launcher
  first to authorize it. Session creation, focus changes and permission
  revocation never display permission UI. A silent one-second main-run-loop
  check detects authorization changes. Revocation, tap timeout,
  focus loss, queue failure and teardown discard pending input and release
  remote keys. Capture is retried only after rechecking permission and focus.
  The authorized tap stays registered during ordinary focus loss; background
  keys pass through untouched before their key data is inspected. Returning to
  the stream re-arms forwarding on the first key using native AppKit focus and
  active-Space state, not cached SDL focus or a later timer tick. Do not disable
  the tap on every focus loss: that prevents first-key recovery after a Spaces
  swipe. Explicit capture release and revoked permission still block re-arm;
  teardown/revocation remove the tap. Test repeated three-finger swipe-away and
  return without an intervening click, not just the first connected shortcut.
  Ctrl+Alt+Shift+Z remains the release toggle; mouse/trackpad gestures, Fn/media
  controls and explicit menu/Dock Quit stay local. Keys are never logged.
  The `mackeyboardcapture` native suite exercises the production callback and
  bounded queue without installing an OS tap or requesting permission. It is
  not proof of live TCC, Command-Tab/Command-Space or Spaces behavior: test the
  signed app with permission granted/denied/revoked and focus changes on both
  supported Mac OS versions. Do not enable SDL's optional private CGS grab
  path or restore global hotkey suppression as an alternative.
- A visible toolbar flashing during a stats update can be a Metal overlay
  publication race. Build/upload the replacement before exchanging the texture
  under the overlay lock, and preserve the old image on allocation failure.
  Do not publish an empty slot except for an explicit hide. Every Mac Client
  build runs `macmetaloverlay` against the production updater with deterministic
  allocation/upload stalls, allocation failure, concurrent readers and lifetime
  checks. The test uses Metal resource doubles without a desktop/GPU; it does
  not replace the native GPU presentation probe or live flicker acceptance.
- Command-Q reaching the Host and also quitting PLANK is duplicate native
  shortcut handling, not a transport disconnect. SDL queues the key before
  AppKit can activate the local Quit menu. The shortcut guard prevents local
  activation while captured. Explicit menu/Dock shutdown is owned by
  MacApplication, which waits for Session readyForDeletion before Qt exits;
  do not restore the removed Qt-to-SDL Quit bridge or treat sessionFinished
  as completed cleanup.
  The `macquitshortcut` native suite runs in every Mac Client build and checks
  native menu dispatch, capture transitions, restoration and queued SDL input.
  The macapplication suite checks real Qt application lifetimes separately.
  Shortcut tests use a harmless Quit target rather than an active remote app;
  a live captured Command-Q/menu/Dock test is still required for acceptance.
- Rust1.89 proc macros fail under SDK27 stripping: retain `RUSTFLAGS=-C
  strip=none`, as for the Host. Missing macros here need not mean missing Cargo
  inputs; do not redownload them blindly.
- Private pkgconf filters its own prefix as system flags: require
  `PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1` and `PKG_CONFIG_ALLOW_SYSTEM_LIBS=1`.
- Qt6.10.2/SDK27 Clang21 `__yield` declaration: the Mac arm64 build includes
  `arm_acle.h` explicitly. Standalone Qt test projects must receive the same
  `QMAKE_CXXFLAGS+=-include arm_acle.h` input; they do not inherit app.pro's
  flags. The hosted outputtopology gate covers this. Do not change Linux flags.
- FreeType's optional zlib pkgconfig dependency is not available from the SDK:
  bootstrap disables that optional compression backend; SDL_ttf fonts work
  through retained FreeType. Do not introduce a moving Homebrew dependency.
- macdeployqt includes unrelated server-database plugins referencing
  `/opt/homebrew` or `/usr/local`: package only SQLite in the SQL plugin
  directory. Every retained Mach-O still passes the external dependency gate.
- Bash3.2 plus nounset rejects an empty feature array: use the guarded array
  expansion in `build-macos-transport.sh`; default Client features are valid.
- Headless version/help checks use `QT_QPA_PLATFORM=offscreen`. A real GUI
  session is needed for functional presentation/input acceptance.
- `macdeployqt` normally ships only Cocoa. Explicitly retain the offscreen
  plugin for the packaged headless gate; do not skip a failed launch check.
- A retained build requires **recursive** `qmake -r` regeneration. Without it,
  subproject Makefiles can retain the previous source path and compiled
  version despite a correct new Info.plist. The independent executable-version
  gate caught this during .94 packaging. Never relabel that older binary;
  regenerate all subprojects and rebuild before signing.
- Qt's SecureTransport backend rejects TLS1.3 with `Failed to set protocol
  version`/network error99. Mac startup must select the bundled OpenSSL backend
  and require TLS1.3 support before opening network requests. A file-closure
  check and a version string alone do not prove authentication works: retain
  the packaged live-connection gate. The unauthenticated
  `tests/video/macos-client-tls.cpp` probe distinguishes backend availability
  from Host reachability without sending credentials. It must run from an app
  bundle when testing bundled OpenSSL lookup (a bare CLI has no Frameworks
  directory for Qt to discover). Bare build-time TLS tests instead receive
  `DYLD_LIBRARY_PATH="$PLANK_MAC_CLIENT_DEPS/install/lib"` for those same pinned
  libraries; this is not a packaged runtime setting or a substitute for the
  bundled gate. See the pinned [Qt6.10.2 loader source](https://github.com/qt/qtbase/blob/v6.10.2/src/plugins/tls/openssl/qsslsocket_openssl_symbols.cpp).
- macOS Local Network privacy can block an otherwise valid packaged Client
  with network error99 while loopback and a separately launched curl work.
  Inspect `/usr/bin/log show --info --debug` for Local Network blocked events
  and the responsible process. SSH-launched GUI children can be attributed to
  the SSH session. Test the installed app through LaunchServices/Applications
  and have the operator approve its normal prompt; SSH authorization is not a
  product prerequisite. Do not edit TCC, lower TLS requirements or treat this
  as Host downtime. Screenshot capture is a separate permission and may still
  fail after network access is authorized.

Current probes are `tests/video/macos-videotoolbox-decode.mm`,
`macos-hevc444-fixture.m`, and `macos-metal-color.mm`. The last loads the actual
Client Metal shader and shared color uniforms, not a duplicate implementation.
Hardware metadata/GPU math probes do not replace live presentation acceptance.
