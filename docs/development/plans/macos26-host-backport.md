# Native macOS 26.7 Host backport

The operator accepts native Apple Silicon Host support on 26.7, with
Chris (cnoellert) responsible for its hardware and session validation. This is
a supported target, not an experimental designation; the operator does not
need to provide a 26.7 test machine. macOS 27 build/regression checks remain
merge gates. The operator subsequently authorized one Host package covering
26.7 and newer. `PLANK_MACOS_HOST_MIN_OS=26.7` is now the default for mainline
and ordinary CI, retaining SDK27 and the existing dependency pins. A 27.0
candidate remains available only for regression comparisons. No signed package
is repacked or retargeted. Installed acceptance must use the identical package
on 26.7 and 27; the earlier baseline test alone does not qualify the new release.

## Scope

Retain the existing ScreenCaptureKit capture, VideoToolbox encoding, Core Audio,
Quartz input, native account authentication, launchd roles and QUIC transport.
No capture backend, compatibility runtime, Linux service, protocol, entitlement,
signing identity or approval-store change is introduced. The existing guarded
CGVirtualDisplay implementation remains unchanged; it is an undocumented Apple
surface, so public API compilation alone cannot qualify virtual displays.

The build selects one runtime floor for the transport, Host and component
tests. App, camera-extension and audio-driver metadata use the same floor.
The PKG seals that value into its distribution, welcome text and preflight;
an environment variable cannot lower the installed package's requirement.
On 26.7, pkgbuild also represents extended attributes as paired AppleDouble
BOM records. The permission verifier checks those against the validated
expanded payload and matching file modes. Orphans, mismatches and physical
sidecars still fail; no executable permission exception is introduced.

FileVault, exact identity/profile, private-state, permissions and service-drain
checks remain mandatory. Development installation reads the candidate's
validated minimum instead of assuming 27.0.

## Evidence and acceptance

An SDK 27 availability audit of all 48 native Host C/Objective-C source files
passes with target 26.7 and availability warnings treated as errors. The exact
production virtual-class signature predicate also passes on 26.7 without
creating a display or changing its mode. These checks do not establish capture,
input delivery, virtual-display lifetime or LoginWindow permission behavior.

The native build runs the existing synthetic component/authentication/media
tests, including malformed input, trust failures, contact retirement, camera
lifetime and audio-driver bounds. It uses the existing Rust transport and
fingerprint/profile loopbacks. Synthetic sources and fake input remain test
inputs; they do not replace physical acceptance.

The original frozen assembly `1.2.02-macos26-host-backport` completes the full
native Host assembly and component sequence on 26.7 with SDK27. All four
bundle checks pass: Host, camera extension and both audio drivers. The Host
links only Apple system libraries. The existing standalone build executable
successfully returns its version on 26.7. Native Host runtime and transport
sources remain byte exact to the upstream base.

The transport passes 62 Rust tests (nine ignored), six dependency tests and
both fingerprint/profile C loopbacks. The Host sequence includes synthetic
authentication/ownership transitions, 24 media-session scenarios, input/contact
retirement, camera payload/lifetime, audio and driver tests with their existing
sanitizers. This is component qualification, not an installed stream.

The ad-hoc app assembly has restricted test entitlements and no Host profile;
its extra version-only launch attempt was terminated. The retained standalone
executable loads successfully without those app entitlements. No entitlements
were removed to make the app launch. The later protected signed build below supplies the genuine Host profile,
matching certificates and notarization; the original ad-hoc result is retained
as component evidence only.

Before installation, require a clean committed source, complete bundle and
Mach-O minimum checks, matching certificate/profile/entitlements and a
properly signed candidate. The ad-hoc assembly is an uninstalled development
artifact, not a distributable installer or evidence of TCC readiness.

Installed qualification remains separate: desktop picture/input/audio,
virtual-display preparation and retirement, disconnect/reconnect, account
ownership and login/logout, LoginWindow/preboot limits, and optional microphone
and camera activation. Coordinate disruptive opportunities before touching
running sessions. No OS upgrade, installer bypass, TCC reset or automatic
reboot is part of the backport.

## Unified package build and validation

Use the ordinary mainline Host dispatch:

```sh
bash scripts/ci/dispatch.sh macos-host true
```

The default 26.7 floor reaches the fresh Rust transport, Host, all component
tests, camera extension, audio drivers, bundle metadata and sealed installer.
Every arm64 Mach-O and bundle must require no newer runtime; the independent
finished-package checks remain mandatory. SDK27 and the macOS27 hosted runner
remain unchanged. Mainline uses the normal unsuffixed package version.

For a focused regression comparison, a candidate branch may explicitly select
`--macos-host-min-os=27.0`. Both candidate floors retain their version suffix
and original manifest; only the 26.7 package is the standard release product.
The Client 15.0 target and Linux build/qualification contracts are unchanged.

The context/dispatch fixtures cover mainline/default selection, explicit
comparison restrictions, exact pushed source, malformed values and propagation
through signed/unsigned assembly. Catalog tests preserve historical metadata,
retain both comparison floors and reject relabeling or overwrite. The shared
minimum checker rejects binaries or bundle metadata newer than the package's
sealed minimum. Automated tests do not establish installed media/input behavior.

## Signed baseline and remaining acceptance

Chris requested the earlier baseline `bd75c102` on `codex/macos26-host-test`.
Signed [run41144764461](https://github.com/instinctual/plank/actions/runs/41144764461)
passed from `a7aed9b98dbf76cb629141a22447aeae91eaceeb`, whose only difference
is the two-line CI fixture isolation fix. Host, transport and dependency sources
match the requested baseline. Package 1.2.02 is signed, notarized, stapled and
Gatekeeper-accepted; HANDOFF records its exact manifest/hash. The CI correction
is carried into the unified package preparation.

The unified 1.2.05 release includes the already-merged macOS click pairing and
Client display changes. All four products were rebuilt from main source
`a0dc5fae73d7e072d923b5fd499bdd8151313456`, with the ordinary Host default 26.7.
The [signed Host build](https://github.com/instinctual/plank/actions/runs/41147081014)
passed its automated input, package, signing and notarization checks on the
macOS 27 runner. The unchanged package is published in
[1.2.05](https://github.com/instinctual/plank/releases/tag/v1.2.05), with installed
acceptance still recorded as pending. Qualification on the older baseline does
not establish acceptance of this new package. Chris owns 26.7
session testing; the same installer needs 27 validation for picture, input,
audio, virtual-display preparation, reconnect and login/logout. Optional
microphone/camera checks remain separate. Do not publish a shared-package
acceptance claim before those results are recorded.
