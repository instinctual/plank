# macOS Host feasibility probes

These are standalone probes, not a Host package. They deliberately do not use
the Linux-only root qualification CMake project or change its dependency gates.
See `docs/development/plans/macos-host.plan` for phase order and acceptance requirements.
macOS 27 and SDK 27 or newer are required; all binaries target macOS 27.0.

The standalone native-camera format and extension/consumer probes use
`scripts/test/build-macos-native-camera-formats.sh` and
`scripts/test/build-macos-native-camera-probe.sh`. They generate synthetic H.264
input and test native coded output versus decoded NV12. See
[the procedure](../../docs/development/investigations/native-camera-probe.md)
for signing/provisioning, explicit activation, the consumer matrix and cleanup.
They neither capture a physical device nor integrate a camera into the Host.

The focused embedded-cursor app is built separately with
`scripts/test/build-macos-embedded-cursor.sh` and accepts only `--cursor` in Aqua.
See `docs/development/build/macos-build-runbook.md` for the five-phase owned-window pixel test,
signing, installed-app backup/restoration and limits. It is not a new Client or
the authenticated A/V probe, and must not run in LoginWindow.

The newer standalone system-audio probe uses
`scripts/test/build-macos-audio-probe.sh`, not `build-probes.sh`. Its installed app
accepts `--audio` only and temporarily replaces the approved Probe app entry
point. See `docs/architecture/macos-audio.md` and the audio section of the Mac build runbook
for playback/capture scope, backup, signing, execution and cleanup. Do not run
an older probe mode against that installed audio-only executable.

## Passive desktop inventory

The standalone pressure-delivery probe is built with
`scripts/test/build-macos-tablet-pressure.sh SOURCE NEW_OUTPUT`. It uses the existing
Probe signing identity and requires macOS/SDK27. `--inspect` posts nothing;
the graphical runner's `--tablet-pressure` mode is Aqua-only and sends generated
tablet events exclusively to its own temporary window/process. It requests no
permissions and requires existing input consent. See `docs/development/plans/macos-tablet.plan`
for measured pressure/proximity results and limits. Do not run other probe modes
against this single-purpose executable or replace the production Host with it.

Status: compiled and tested on the dedicated development M4 Mac, macOS 27.0 /
SDK 27.0. The reference Mac remains read-only. See
`docs/development/investigations/macos-host-investigation.md` for measured results and pending gates.

Build on the authorized Mac with its selected Xcode SDK:

```sh
probe_dir=$(mktemp -d /tmp/plank-macos-inventory.XXXXXX)
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
  -framework Foundation -framework CoreGraphics \
  probes/macos/desktop-inventory.m -o "$probe_dir/desktop-inventory"
"$probe_dir/desktop-inventory"
```

This reports public CoreGraphics geometry and checks existing capture/input
permission without requesting it. It does not capture pixels, inject events,
change a display mode, modify services, or collect user/device serial identity.
No dependencies are installed. Temporary compiler output is not a release.

Permission preflight describes this executable in its current launch context,
not a future signed graphical agent. A false result from SSH is not evidence
that LoginWindow capture is unsupported. Display `builtin` is an API flag, not
proof of a physical panel; geometry does not establish who created a display.
Do not stop PCoIP to test display lifetime without user coordination.

Validation: compile with warnings treated as errors; parse output as JSON;
compare mode/backing dimensions with `system_profiler SPDisplaysDataType`.
Later captures and input probes need separate explicit operating procedures.

## Build all probes

HEVC 4:4:4 branch qualification adds `--pattern-hevc444-4k` and
`--pattern-hevc444-5k` to this multi-mode build. These are desktop-only owned
chart tests at 3840x2160 and 5120x2160, not product encoder defaults. See
`docs/development/investigations/macos-hevc-444-investigation.md` for pending gates. The matching pixel
sampling unit is `tests/video/macos-pattern-sampling.m`, linked with
`pattern-validation.m`, AppKit, QuartzCore, VideoToolbox, CoreMedia/CoreVideo
and the probe include directory. It requires no live capture or OS input.

On the authorized development Mac, from the copied source directory or checkout:

```sh
probe_output=$(mktemp -d /tmp/plank-macos-probes.XXXXXX)
# Select the intended Apple Development identity from this list:
security find-identity -v -p codesigning
export PLANK_MACOS_SIGNING_IDENTITY=REPLACE_WITH_SELECTED_40_HEX_SHA1
bash probes/macos/build-probes.sh "$probe_output"
```

Only Apple SDK frameworks are used. All twelve Objective-C sources compile with warnings as
errors. The app requires an explicit, valid certificate-backed development
identity; there is no ad-hoc fallback. Apple Development signing is not Developer
ID distribution signing or notarization. Do not call these outputs a product
or install them on production Macs. Private keys stay in the Mac keychain;
never export them or store account credentials in the repository.

Signing preflight: a matching identity is not necessarily valid. If codesign
cannot build its chain, check that Apple's matching WWDR intermediate is installed
as an ordinary certificate, not a new trusted root. For Apple Development G3,
use Apple's certificateauthority page, verify against the existing Apple root,
then `security add-certificates -k LOGIN_KEYCHAIN AppleWWDRCAG3.cer`. Do not set
Always Trust or import a custom trust root. A locked login keychain may still
cause errSecInternalComponent after the chain is fixed: unlock it interactively
with `security unlock-keychain LOGIN_KEYCHAIN`, never a password argument.
Prove private-key usability by signing/verifying a disposable binary before
replacing the installed app. Certificate-creation, account login and 2FA stay in
Xcode. The identity hash is supplied by the operator/builder, not hardcoded here.

The app link includes `-Wl,-sectcreate,__CGPreLoginApp,__cgpreloginapp,/dev/null`
and verifies that exact Mach-O section/segment before signing. This pre-login
declaration is present in [Apple's IOHIDFamily build settings](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily.xcodeproj/project.pbxproj).
It is not an Info.plist permission, entitlement or TCC grant. Adding it in probe
build 11 changed the original HID pointer test from a construction stall to
successful LoginWindow motion/restoration. Keep it as a qualified probe input;
revalidate on the final macOS 27 release rather than assuming a stable contract.

## LoginWindow probes

`virtual-display-api` inventories runtime signatures without creating a display.
`virtual-display-lifecycle` is an isolated, undocumented-API experiment: it creates
one 1080p60 display for ten seconds, verifies actual dimensions, releases it, and
allows five seconds for removal. These fixed dimensions are a test case, not
the proposed product mode list. An allocated object is not a passed test.

Run inventory and lifecycle binaries in the actual graphical pre-login session:

```sh
sudo bash probes/macos/run-graphical-probe.sh loginwindow \
  "$probe_output/desktop-inventory" probes/macos/probe-agent.plist
sudo bash probes/macos/run-graphical-probe.sh loginwindow \
  "$probe_output/virtual-display-lifecycle" probes/macos/probe-agent.plist
```

For Aqua, run the same script as the desktop user, without sudo, substituting
`"gui/$(id -u)"` for `loginwindow`. Root is required only for LoginWindow.
The runner uses the `loginwindow` domain (without appending the loginwindow PID),
stages files in a root-owned temporary directory, bootstraps a one-shot agent,
waits at most 40 seconds, then unregisters it and removes that invocation's files.
It does not install a LaunchAgent in `/Library` or change login configuration.
SSH's Background session is not an equivalent graphical test context. An empty
SSH display list or `CGDisplayIsOnline` returning -1 must not count as success.

## Capture permission step

The development app has bundle ID `la.instinctual.PLANK.Host.Probe`. Install the
verified app as root-owned `/Applications/PLANK Host Probe.app` on the dedicated
Mac only. Do not replace an existing app implicitly. In the logged-in user's
Terminal, run:

```sh
open -a "PLANK Host Probe"
```

Allow the app in System Settings → Privacy & Security → Screen & System Audio
Recording and **Device Control and Data Access** (the new name for the privacy
Accessibility permission on macOS 27). This is not the main Accessibility
section in the settings sidebar. Normal launch now opens a modeless permission
window and calls `AXIsProcessTrustedWithOptions` with its prompt option once
after the event loop starts. This requests OS approval rather than asking the
operator to find and add the app manually. macOS controls whether a previously
denied prompt is repeated; Request Control and Open Settings buttons remain
available. The timer only checks status, never repeatedly requests permission.
Request Recording separately invokes the screen-capture consent API.
Quit the probe afterward. This setup mode posts no
input and does not start a capture. Do not modify TCC databases, disable SIP, or
assume root grants access. Signed identity and cross-session permission persistence
remain qualification gates; ad-hoc signing is not the release provisioning design.

Capture must now be explicitly requested with `--capture`; normal launch never
captures. The graphical runner supplies that argument for the installed app.
The capture mode runs for at most 20 seconds plus a two-second shutdown
deadline. It reports complete-frame/idle counters, pixel format, dimensions,
IOSurface backing and timestamps. It never saves pixels or window titles.
ScreenCaptureKit itself may cause an OS permission prompt in a graphical user
session. A static desktop may legitimately yield just one complete frame, so
this is not a frame-rate qualification. At LoginWindow, use the runner with the
installed app executable path as its first argument; it retains the bundle identity
instead of copying the executable outside the app. Desktop and post-logout
LoginWindow capture passed with the previous ad-hoc build 2. After transitioning
to Apple Development signing and reapproval, desktop capture passed again and
the same-certificate build-3 update retained consent without another prompt.
The unchanged signed build 3 also passed post-logout LoginWindow capture with
both preflight checks allowed. No input has yet been injected; cold-boot and
continuous handoff behavior remain unqualified.

## Owned-display capture and input delivery probes

The installed signed app accepts two additional qualification modes through
the same runner's optional fourth argument:

```sh
sudo bash probes/macos/run-graphical-probe.sh loginwindow \
  '/Applications/PLANK Host Probe.app/Contents/MacOS/plank-host-probe' \
  probes/macos/probe-agent.plist --capture-virtual
```

`--capture-virtual` creates one temporary 1920x1080@60 display using the shared,
runtime-checked experimental helper in `virtual-display-probe.h`. It captures
that exact display ID, verifies actual dimensions and BGRA IOSurface delivery,
then releases it and verifies removal. It never substitutes the main display.
This is private-API feasibility, not a production virtual-display commitment.
The output contains metadata only; no images are stored or examined for content.

`--input` opens a temporary PLANK window, requires that it is active/key with
our receiver as first responder, and then posts a bounded sequence through
public Quartz event APIs. Only probe-tagged events are counted in our view:
motion, left down/drag/up, right down/up, scroll and keyboard down/up.
It never logs user keys or supplies a login credential. Losing owned focus
stops the test. Down/up pairs are posted together; the cursor and prior app
focus are restored on normal exit. No global event tap or persistent agent.
Use `gui/UID` as the desktop user for this window-based test. An inability to
focus a test window at LoginWindow is not proof that LoginWindow input fails.

`--pointer` tests only global cursor motion to two positions derived from the
main display's current bounds, then restoration. It performs no clicks or
typing and compares observed cursor coordinates with the requested positions.
Both input modes are experimental and must run through the bounded runner.
Current evidence: build 8 delivered all nine tagged event types to the owned
Aqua receiver (mask 511/511). Builds 11 and 12, with the pre-login executable
declaration, passed LoginWindow HID pointer motion/readback/restoration.
Build 12's regular NSWindow still could not acquire active/key focus even with
`canBecomeVisibleWithoutLogin=YES`; the guard refused all keys/buttons.
Actual login-field input remains unqualified. Do not equate a receiver-window
focus limitation with failed delivery into the real LoginWindow UI.
The operator saw **no visible motion** during five build-12 pointer runs despite
all readbacks passing. Readback is not visible-cursor qualification. Resolve
which cursor/display is being observed before further input changes.

`--pointer-session` is an explicit comparison using the combined-session source
and the session event entry point; `--pointer` retains HID source/entry point.
There is no automatic source fallback. Before adding the executable declaration,
build 10's session path returned normally but neither requested cursor position
matched readback, and the operator saw no movement. This failed comparison does
not supersede the now-passing original HID path. Graphical audit-session
identity was checked against loginwindow and matched. Next coordinate actual
login-screen input observation; do not type credentials or submit a login.

The app remains a permission setup UI by default. None of these input/display
experiments runs merely by opening the application.

## Hardware encoding

### Live capture-to-encoder handoff

The signed app's `--encode-h264` and `--encode-hevc` modes use the same bounded
graphical runner. They capture the current main display without changing modes
or creating a display. They do not post input, request permissions or save
pixels/bitstreams. Use LoginWindow as root, or Aqua as the logged-in user:

```sh
sudo bash probes/macos/run-graphical-probe.sh loginwindow \
  '/Applications/PLANK Host Probe.app/Contents/MacOS/plank-host-probe' \
  probes/macos/probe-agent.plist --encode-hevc
```

The SDK 27 `SCStream.h` lists both `420v` and `x420`. Each exact SCK IOSurface
pixel buffer is passed unchanged to VideoToolbox (hardware required; H.264
High or HEVC Main10 respectively). There is no application CPU pixel mapping,
copy or separate transfer stage. Internal framework copies are **not measured**.
The probe sets 20 Mbps, 60fps expected rate, real time and no frame reordering;
these are bounded qualification inputs, not product defaults or new profiles.

At most three encode frames are in flight. A serial queue owns mutable state;
output handlers return to that queue. Stop after 180 submissions or 15 seconds,
drain for at most three seconds, invalidate and exit. The outer runner also
enforces its 40-second deadline. Bad surfaces, nonmonotonic input/output PTS,
missing encoded buffers, hardware rejection, overflow, drops or incomplete
draining fail. A static screen may produce few complete frames; idle callbacks
are counted separately and must not be reported as 60fps throughput.

Encode timings cover submission to callback, including startup samples.
Capture-age diagnostics use the SDK-documented Mach-absolute
[displayTime](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime),
not an assumed mapping from media PTS. Missing/future display timestamps are
explicitly counted. Passing handoff is not decoded precision or color acceptance:
build 13's x420 buffers lacked color attachments despite the requested BT.709
capture color space. Known-pattern capture/decode comparison is still required.

### Animated chart and color gates (Aqua only)

`--pattern-h264` and `--pattern-hevc` display a temporary non-key, mouse-ignoring
chart over the current main screen: eight RGB bars, 32 grayscale steps and a
Core Animation moving marker. They refuse root execution and never cover the
real LoginWindow. No display mode change, keyboard injection or button event.
The window closes on normal completion; the runner removes the process/window
on timeout. Do not operate other apps through the mouse-ignoring chart.

The existing handoff test then runs for at most 900 submissions or 15 seconds.
At frame 30 only, diagnostic code reads 40 source YCbCr triples and requests a
keyframe. It compares source samples with the declared chart matrix, decodes
that keyframe on a separate validation queue, and compares the result with the
expected output matrix. Tolerances are 4/6 code values in 8-bit-equivalent units
for source/roundtrip respectively. Diagnostic sample math is not an in-stream
CPU conversion stage; ordinary live modes do not map pixels or decode frames.
Passing these 40 sample points is not whole-image or native 10-bit precision
qualification. Short chart throughput is not a sustained performance soak.

**These modes save one keyframe only after source chart samples pass** in a
new private `/tmp/plank-chart-bitstream.XXXXXX/` directory, file mode 0600.
Failure of source chart verification stops the test without decoding/saving a
keyframe. This sample gate is diagnostic, not proof that every pixel is the chart.
Its path is printed for independent FFmpeg inspection. The Annex B writer is
shared with the synthetic encoder probe; no extra packetization implementation.
Keep chart artifacts off the repository and remove exact obsolete files after
evidence is retained. Ordinary `--encode-*` modes still save no images/video.

Current experimental SDR contract uses sRGB transfer with BT.709 primaries.
The known chart measured BT.709 matrix for SCK 420v, BT.601 matrix for x420.
On the tested beta, 420v retains a BT.709-transfer attachment despite requested
sRGB samples, while x420 omits color attachments entirely. The probe explicitly
declares measured input metadata; VideoToolbox produces BT.709-matrix/sRGB
output. Only metadata is set; the exact SCK pixel buffer is submitted.
This is an empirically tested **probe contract**, not a universal production
rule for unlabeled buffers. Requalify both paths on other/final OS builds.

Build 18 passed both 1080p animated-chart paths, 900/900 frames each, with no
drops/overflow. Independent pinned FFmpeg decode confirmed the samples and
video-range BT.709-matrix/sRGB tags. See the investigation for timings/limits.

The additional `--pattern-h264-2160` / `--pattern-hevc-2160` modes are **not
qualified**. Builds 19/20 created a temporary output but did not initially get
the requested mode. Build 20 explicitly selected an exact non-mirrored 4K mode;
the capture was 4K but its pixels did not match the chart, and removal was not
confirmed before process exit. Post-exit inventory returned to one 1080p output.
Do not use these results as color/performance qualification. Next isolate
AppKit chart placement and owned-display lifetime before repeating media tests.
Build 21 adds the fail-closed chart artifact guard; it does not fix the 4K path.

Subsequent unlocked-desktop tests passed 4K chart color/encode/decode checks:
H.264 build 21 and HEVC build 22 each completed 900/900 frames without drops or
overflow. The operator confirmed that leaving Screen Sharing ends/locks their
desktop view, so keep it connected during coordinated chart tests and verify
unlocked state separately. The earlier missing-chart samples are not evidence
of a bad 4K capture implementation.

The **pre-exit removal gate remains open**. `display-mode-lifecycle` isolates
this without AppKit, capture or encoding. Run it through the graphical runner
with no mode argument for creation/release alone, or `--select-mode` to force
a real change between 1080p and 2160p on its owned output. Fresh processes are
required per case; never reuse display IDs. Plain release passes; a real mode
change with CGDisplaySetDisplayMode retains the output until process exit even
after a weak reference confirms object destruction. A no-op mode selection
does not reproduce it. A session-scoped configuration comparison and an active
CFRunLoop cleanup timer did not fix a real mode change. No global restore or
permanent configuration was used. Build 22 drains a scoped autorelease pool;
this improves lifetime visibility but does not resolve this OS behavior.
Treat process-lifetime ownership as a design constraint, not a passed
in-process reconfiguration/teardown gate. `--restore-mode` on the standalone
mode probe changes and restores the original mode on that same owned output;
this comparison also failed to remove it before process exit.

### Display-owner process boundary

`display-owner-lifecycle` runs through the graphical runner with no explicit
mode. Its parent launches its own executable as a bounded child, with a private
inherited pipe carrying only a fixed-size display/geometry result. The child
creates a virtual display, makes a real mode change and holds it briefly. The
parent independently verifies the active geometry. It then tests normal child
exit and SIGKILL of that exact NSTask child; both must remove the output while
the parent remains running. The parent has a twelve-second per-case deadline;
the child independently exits after its bounded hold. No capture, pixel output,
input, permissions, persistent agent or production IPC endpoint is involved.

Four repetitions of each case passed in Aqua and four more in LoginWindow
(sixteen cases total) on the development Mac. This qualifies a candidate ownership
boundary, not a complete macOS Host. Next test parent-side capture/encode of a
child-owned output, then orderly resolution replacement. LoginWindow runs used
the exact same executable as root after operator logout; no input or permission
changes were involved. Login/logout continuity
and final-OS behavior still require coordinated qualification.

Separate tests of stable resolution-specific serial and product identities did
not select native 4K automatically on this macOS 27 beta: both still started at
1080p, although they could be removed cleanly without mode selection. The media
helper retains the original diagnostic identity; do not add random identity
retries or assume the behavior reported on another OS version applies here.
Those experiments used only two additional fixed identities. macOS may retain
their display profiles; deleting unrelated system ColorSync files is not cleanup.

### Bounded session-handoff controller (build 42)

For capture-independent timing comparisons, the standalone `hardware-encode`
accepts `OUTPUT_DIRECTORY --color-timing` or `OUTPUT_DIRECTORY --cadence-timing`.
The former compares three serial 4K Main10 synthetic ramp cases at the same
20 Mbps target: BT.709, sRGB transfer, and sRGB plus 601-to-709 matrix conversion.
The latter uses the last color case with ten one-second inter-submission waits
between active phases. It deliberately retains synthetic 1/60 PTS increments
and one immutable source surface: this is not an exact model of SCK timing or
surface ownership. Forty synthetic frames are encoded per case, excluding the
first ten from summary timing. It writes synthetic Annex-B output only to a
fresh directory and does not capture the desktop or alter the installed app.
These are timing comparisons, not new color/profile qualification results.

`run-session-handoff.py` is a temporary administrator-run qualification tool,
not a packaged Host service. Copy it and the freshly built `session-observer`
and `desktop-inventory` into a root-owned directory, non-writable by group/others.
It requires the signed app installed at its canonical `/Applications` path,
an exact `--app-sha256`, and explicit operator-authorized desktop `--uid`.
Run with `/usr/bin/python3`; the dedicated Mac's Xcode supplies that interpreter.
No new runtime dependency is added to PLANK packages.

Build 34 adds opt-in `--timing-mode retain-sample` and `--timing-mode synthetic-pts`
controller comparisons. The default `baseline` invokes the unchanged handoff
mode. Retaining the entire CMSampleBuffer through the VT output handler tests
its lifetime without CPU pixel copies. Synthetic PTS substitutes monotonically
increasing 1/60 timestamps only at encoder submission; it is explicitly not a
streaming policy or A/V-sync-safe workaround. Actual input geometry/timestamp
validation, color metadata, hardware requirement and three-frame bounds remain.
Run each separately on an otherwise idle desktop; the controller still checks
session authority and cleanup. No image or encoded desktop payload is saved.
Build 35 adds `relative-pts`: subtract only the first capture PTS, preserving
actual inter-frame intervals. This separates absolute epoch from synthetic
cadence effects. Baseline still passes original SCK timestamps untouched.
Build 36 adds `low-latency`, requesting the native low-latency encoder
specification without fallback. Build 37 adds `encoding-speed`, setting only
the native speed-over-quality property. These are mutually exclusive timing
experiments; neither changes the default. A successful timing test is not
decoded-format/color/quality acceptance or permission to change production
encoder policy. The current Main10 low-latency combination failed setup and
cleaned up before capture; do not describe it as a working HEVC option.
Build 38 also has `--pattern-hevc-2160-speed` through the graphical runner:
the existing animated 4K HEVC chart with speed priority and a strict desktop
session guard. It is bounded to the original short chart test and must pass
source-pattern and decoded-color gates. Build 40 waits at most three seconds
for its own chart window to be compositor-visible at the target display bounds,
pumping the main run loop; failure closes the chart and refuses capture. It
reports only owned-window geometry. This does not replace the actual captured
source-pattern check or permit arbitrary desktop artifacts. Baseline and speed
moving-chart runs now pass format/color checks and cleanup with no drops or
overflow. These short small-marker tests are not sustained full-motion quality
or throughput qualification; speed priority remains opt-in.

Builds 41/42 add `--pattern-hevc-2160-mixed` and
`--pattern-hevc-2160-mixed-speed`: desktop-only 180-second chart runs using the
existing long-run owner lifetime, three-frame limits and post-stop timing
buckets. The graphical runner deadline is 210 seconds only for these modes;
ordinary modes retain 40 seconds. A main-run-loop timer alternates nine seconds
of marker motion with nine seconds without an animation. Window close
invalidates that timer. Build 41's constant-value animation group kept capture
near 58 fps, so its clean run was not sparse-cadence qualification. Always check
the measured capture buckets before claiming idle phases were exercised.

Build 33 adds probe-only fixed one-second timing buckets in handoff mode.
`media_timing` reports complete capture callbacks, application queue overflow,
encoder callbacks, maximum submit-call duration, submit-to-encoder-callback
time and callback-to-serial-queue processing delay. Buckets use monotonic
seconds since media initialization; slot 180 also contains bounded teardown.
They print only after capture stops, with a maximum of 181 lines per worker.
`capture_stop_elapsed_s` locates retirement relative to those buckets. This
does not change the three-frame limit, encode properties or lifecycle checks.
Callback time is not pure hardware execution time or glass-to-glass latency.

The default `--seconds 180` bounds the controller (allowed range 10–180). It
observes machine-level console changes through the passive native observer,
launches unique temporary LoginWindow or Aqua jobs, waits for a verified first
encoded frame, and retires the old job before launching a replacement. It uses
only the installed probe's `--handoff-session` mode. That worker independently
checks its own graphical security session and pins capture to its owned display.
Its lifetime is at most 180 seconds; its private display child has a 200-second
backstop and exits on parent-pipe EOF. Existing short probes are unchanged.
Initial session announcements can precede graphical identity readiness. The
handoff worker waits at most five seconds for the unchanged strict predicates;
no display or capture starts before they pass. Background SSH still refuses.

Controller retirement uses SIGUSR1 against its exact launchd job label, allowing
capture drain/encoder release before owner exit. Independent inventory must
have observed the live owned display and then confirm its removal. Inventory
is run as a separate read-only temporary
graphical job in the current LoginWindow/Aqua domain. Background root inventory
can report no displays at LoginWindow and must not be used to prove removal.
If macOS tears down the session first, process/display reclamation is logged separately
from orderly shutdown. Missing final counters leave the strict media gate
unqualified. Lifecycle completion never conceals a media overflow/drop failure.
Unexpected worker exit stops the test, without same-session restart. Optional
`--inject-worker-crash` kills only this controller's first ready job and should
produce a failed run with verified resource reclamation.

An unavailable console pauses replacement; a different desktop UID refuses the
run. This is operator-selected test scope, not remote-user authentication.
There is no public IPC/network endpoint or persistent launchd installation.
Generated root-owned directories retain only plist and bounded diagnostic text;
worker output files are writable only by their corresponding test UID, whose
same-account control of its process is not a product authentication boundary.
Do not promote this diagnostic orchestration into production without peer
authentication, session/input/transport contracts and full negative tests.

Run the pure parser/inventory tests with:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s probes/macos -p 'test_*.py'
```

For live qualification, start while the authorized user is on the desktop,
wait for `media-ready`, request operator logout, then wait for sign-in readiness
before requesting login. Never substitute reboot/automatic login for this test.

### Session boundary preparation (build 29)

`session-observer` runs for 15 seconds in the graphical runner and prints only
changed phase/numeric identity metadata. It subscribes to the two SDK-declared
CoreGraphics session notifications with a 500 ms readback fallback. It does not
capture, inject input, create displays, authorize users or switch sessions.
Run its `--self-test` directly to exercise synthetic identity changes and malformed
number inputs. The signed app's `--encode-session` requires the caller's own
Security framework session to have graphical access, plus matching CG and system
console state. It chooses the probe's 1080p LoginWindow / 4K desktop policy, uses
the existing display-owner child, and runs bounded HEVC capture/encode.

Session notifications revoke the media scope without automatic resumption,
even if a fast round trip restores the same UID. A 250 ms identity check backs
up notifications. `--encode-session-revoke` injects a local synthetic revocation
after the first encoded frame; it never posts fake OS session notifications.
Both stop capture and drain/invalidate encoding before the owner exits.
These are opt-in probe modes, not an integrated machine supervisor or transport
handoff. The original media/color qualification modes remain unchanged.
Real LoginWindow identity, login/logout notification timing, fast user switching
and cross-agent continuity need operator-assisted testing. Lock handling and
input authorization are not qualified by this observer. Direct SSH invocation
must fail initial identity validation, even if CG reports the console user.

### Initial-mode comparison (standalone)

`display-initial-mode` runs through the graphical runner with no explicit mode.
It creates/releases four displays sequentially in the same owner process:
1920x1080, 1440x932, 3840x2160 and 1708x1072. It keeps the PLANK diagnostic
identity, physical dimensions and 4096x4096 maximum capacity fixed, sets HiDPI
off, and supplies each desired size only as the initial 60 Hz mode. It never
calls a public mode-switch/configuration API or changes global display policy.
This isolates the initial-mode/stable-capacity hypothesis suggested by the
read-only PCoIP observation; it does not claim to reproduce its private internals.

Actual live pixel geometry, bounds, object destruction and output removal are
checked. Each create/removal wait is bounded to five seconds; a removal failure
stops the matrix to avoid accumulating displays. A fresh read-only child of the
same executable inspects the target's pixel/point mode and refresh rate in the
same graphical session, avoiding the owner's unavailable mode objects. This
observer is not a display owner. Its lifetime is bounded to three seconds.

Optional runner mode `--descriptor-comparison` isolates four 4K cases: original
physical size, 641x401 mm, exact 4096x2160 at that size, and original physical
size with a 150 ms run-loop interval before applying initial settings. Capacity
and diagnostic identity stay fixed. `--hidpi-comparison` compares HiDPI off/on
at 3840x2160 and 4096x2160 with 641x401 mm physical size. Neither mode is a
product fallback or linked into the signed media app. Both retain exact native
pixel/bounds readiness requirements; observer output distinguishes a real
Retina backing surface from a wrong-resolution result. No repeat application,
random identity, explicit mode switch or preference reset is performed.

LoginWindow results: the three smaller sizes matched, but the 4K request became
1920x1080, independently confirmed as 1080p pixels and points, not Retina 4K.
All four displays removed while their owner survived. Repeat in Aqua before
drawing a session-wide conclusion. Do not replace build 27's working owner path
with this unqualified simplification. The signed media app is unchanged.

### Integrated display-owner/media qualification

Build 24 adds `display-owner-probe.m` to the signed application. The parent
captures/encodes the exact child-owned display ID; it no longer creates/resizes
the 4K chart output itself. The same installed executable starts a child with
strictly bounded dimensions and private anonymous pipes. Only fixed numeric
display/geometry/status data cross the report pipe. EOF on the control pipe
releases the child, including on parent exit. An independent child deadline
bounds a leaked control descriptor. This is a standalone probe, not a new
launchd service, public IPC endpoint or production privilege boundary.

Use the usual graphical runner and signed application path with:

- `--encode-h264-owned` / `--encode-hevc-owned`: capture a child-owned 4K output
  for at most fifteen seconds. No chart, input, pixel readback or saved images;
  these can run in LoginWindow.
- `--encode-owned-replace`: 1080p H.264, orderly teardown, then 4K HEVC, all in
  the same parent. Both media and cleanup gates must pass; total runner deadline
  remains forty seconds.
- `--encode-owned-crash`: kill only the exact child after its first frame has
  encoded. The parent must detect owner loss, stop capture/encoding, verify the
  display disappeared, and remain alive. Expected stream failure 8 becomes a
  qualification pass only after successful crash cleanup.
- `--pattern-h264-2160` / `--pattern-hevc-2160`: existing desktop-only chart
  tests now use the child owner. Coordinate an unlocked desktop with the user.

Normal teardown must stop SCK, drain/invalidate VideoToolbox and release capture
references before closing the owner's pipe. Output removal is checked while the
parent remains alive. Timeout/error paths fail rather than claim a clean pass.
Do not confuse a mostly static login screen's complete-frame count with moving
content throughput. Requalify desktop color, continuous login/logout handoff and
the final macOS release separately.

### Synthetic encoder-only baseline

```sh
probe_streams=$(mktemp -d /tmp/plank-vt-output.XXXXXX)
"$probe_output/hardware-encode" "$probe_streams"
```

Tests H.264 High 8-bit 4:2:0 and HEVC Main 10 10-bit 4:2:0 at 1080p and 2160p.
Hardware encoding is required and independently queried; rejected settings,
dropped frames, timeout, or software substitution fail the case. Uses RealTime,
no frame reordering, 60-fps timestamps, and video-range BT.709 synthetic ramps.
It writes synthetic Annex B streams only, refusing existing output files.

Forty frames per case, one frame in flight; first ten excluded from callback-time
statistics. CPU generation of the immutable ramp occurs before timing. These
short, static serial samples do not prove moving-footage throughput, a zero-copy
capture pipeline, long-session stability, or glass-to-glass latency. Specialized
VideoToolbox LowLatencyRateControl is not enabled/tested by this probe.
Validate generated streams independently with the retained FFmpeg on linux-client-builder:
profile, pixel format, range, BT.709 tags, no B frames, all 40 frames decoded.
No package build/install or dependency change is needed for this validation.

### Live bitrate roundtrip diagnostic

On the authorized dedicated Mac only, compile `bitrate-roundtrip.m` with:

```sh
xcrun clang -O2 -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
  -framework Foundation -framework CoreVideo -framework CoreMedia \
  -framework VideoToolbox bitrate-roundtrip.m -o bitrate-roundtrip
./bitrate-roundtrip
```

This standalone test uses CPU-generated 1080p moving texture, matching the
Host's full-range Main10 hardware encoder settings. It performs 150 → 10 →
150 Mbps changes, reads back the properties, and counts encoded bytes and
drops before transport. Each phase repeats identical source frames; rates are
calculated from 60-Hz media timestamps, not wall-clock execution speed. No
screen capture, network, credentials, GUI, input, installed Host change, or
output video file is involved. Run without a concurrent user stream to avoid
encoder resource competition. The process has a 120-second safety deadline.

Separate invocations accept `--ordered`, `--clear-limit`, `--keyframe`,
`--average-only`, `--recreate`, or `--long` (ten media seconds per phase).
These are diagnostic comparisons, not supported Host configuration switches.
Successful execution reports measured behavior, not automatic performance
acceptance. Low-target frame drops are counted instead of suppressing the
final high-rate test. Actual capture, motion quality and A/V continuity need
separate qualification before an encoder lifecycle change ships.
