# Native macOS 26.7 Host backport

The operator authorized investigating a native Apple Silicon Host on 26.7.
The regular Host remains 27.0 by default. This candidate explicitly selects
`PLANK_MACOS_HOST_MIN_OS=26.7`; SDK 27 and the existing dependency versions remain
required. It is not a repack of a signed 27-only installer.

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

The clean committed candidate `1.2.02-macos26-host-backport` completes the full
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
were removed to make the app launch. A genuine Host profile, matching signing
certificates and the protected signing path are the next packaging gate.

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

## Build selection

Use the normal runbook's clean source and retained Cargo/Rustup paths, adding:

```sh
export PLANK_MACOS_HOST_MIN_OS=26.7
export PLANK_BUILD_BRANCH=macos26-host-backport
```

Build a fresh transport archive with `build-macos-transport.sh`, then pass it
to `build-macos-host.sh` or the protected `build-macos-host-pkg.sh` flow.
Use a branch-qualified candidate version. All nested bundles must declare 26.7
and every linked arm64 Mach-O must require no newer runtime. The build reuses
the existing minimum checker for the app, extension and both audio drivers.
Retain build/source hashes and operational receipts privately; publication of
a candidate does not promote 26.7 to a fully qualified supported platform.
