# Native Apple Client automation

The native Mac pilot and PLANK Vision are integration candidates, not replacements
for the shipping Qt/SDL Client. Use the `Native Apple clients` GitHub Actions
workflow on `apple-native-integration`. The temporary `native-builds` branch is
also permitted while qualifying this automation. Do not merge the pilots into
shipping main merely to enable CI.

All compilation runs on disposable GitHub-hosted Apple Silicon `xcode-27`
workers. No SSH, local Mac, hardware-test machine or private infrastructure repo
is a build input. Public PRs receive no Apple credentials. The native recipe in
the exact Client gitlink supplies the dependency lock and patch verification;
its distinct transport parent must not be replaced with the shipping parent.

## Ordinary builds

Pushes to the integration branch and PRs targeting it compile Release builds for
native macOS, visionOS device and visionOS simulator. They run native policy
tests, retain source/hash provenance and upload seven-day artifacts. Mac stays
Apple Silicon/macOS15+ with SDK27+; Vision uses the recipe's visionOS deployment
target. Compile/test success is not streaming, audio, color or Wacom acceptance.

CI caches checksum-verified archives, the pinned Rust toolchain and locked Cargo
downloads. Prepared dependency libraries and all application/transport objects
are currently rebuilt. No signing files, Keychains, archives or app objects are
cached. PRs cannot save these caches. The first hosted run qualifies the recipe;
do not present an untested cache as a completed clean bootstrap.

SDK27 native Mac builds retain the shipping `strip=none` workaround. Set the
Cargo **release profile** override too: target-only Rust flags do not cover host
proc-macro dylibs with an explicit `--target`. Simulator Metal omits drawable
presentation timestamps, so its build excludes only that diagnostic callback;
real-device and Mac presentation measurements remain enabled. CMake writes
dSYMs outside Xcode's archive folder; collect them explicitly and require their
UUIDs to match the archived executable before upload.

The Mac artifact is an ad-hoc-signed, self-contained pilot ZIP for inspection,
not a notarized install package. The Vision device artifact contains an unsigned
Release `.xcarchive` with dSYMs. Neither is a TestFlight installation. Simulator
compilation does not claim a simulator runtime or headset was exercised.

## TestFlight

Manually dispatch this same workflow at a pushed integration commit, supplying
its exact `source_sha`, numeric marketing `version` and `testflight=true`.
The build number is `run_number.run_attempt`, so reruns do not reuse an uploaded
build number. The pilot's Settings shows version/build/source branch. Keep the
workflow name/file stable; counter resets require a deliberate version change.

After all unsigned builds pass, the protected `vision-testflight` environment
allows the signing job. It downloads only the device artifact from this run,
verifies its source/version/checksum, and uses Apple's cloud signing to upload
that exact archive. No developer Keychain is copied. Apple API credentials are
temporary `0600` files, cleared on success, error or job cancellation. Upload
logs/account metadata and credentials are not published as build artifacts.
Packaging expands the drawing-receipt Keychain group using the registered
application identifier prefix and includes the matching entitlements for export
re-signing; an unsigned build's empty prefix is not a distribution identity.

Environment secrets:

- `PLANK_ASC_KEY_ID`, `PLANK_ASC_ISSUER_ID`, `PLANK_ASC_PRIVATE_KEY`: a team App
  Store Connect API key authorized for this app and cloud distribution signing.

Environment variables:

- `PLANK_APPLE_TEAM_ID`: distribution team.
- `PLANK_VISION_APP_ID`: the App Store Connect numeric app record ID.
- `PLANK_VISION_GROUP_ID`: this app's internal TestFlight group ID.

The workflow's bundle ID is `la.instinctual.PLANK.Client.Vision`. The Client
recipe makes bundle/team configuration explicit; it no longer hardcodes a
contributor's team. An app record must be created once on Apple's website before
uploading. Set the environment's deployment branch policy to exact approved
integration branches only, never every branch/tag or a public PR. Do not reuse
Developer ID/notarization credentials: TestFlight is a different distribution
channel. Forks must configure their own team, app identity and environment.

The job waits up to 25 minutes for Apple processing, then assigns a valid build
to the configured **internal** group. It never submits an App Store release,
creates public testing links or invites arbitrary testers. Add the operator to
that group once in App Store Connect. Internal testers install/update with
TestFlight on their Apple Vision Pro.

An upload is not the same as an installable build. Apple can require export
compliance answers or updated agreements. CI does not guess those answers or
claim the app uses only operating-system encryption. Complete required Apple
questionnaires before assignment; a processing timeout is not permission to
re-upload the same build. Check App Store Connect's exact version/build first.

References: [Apple cloud signing](https://developer.apple.com/videos/play/wwdc2021/10204/),
[creating an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/),
[TestFlight distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).
