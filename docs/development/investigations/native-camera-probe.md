# Native camera application-delivery probe

This standalone experiment tests macOS camera-extension format negotiation.
It is not a PLANK Host feature or an installed product candidate. Use only the
authorized Apple Silicon development Mac, macOS27/SDK27, deployment target27.0.
See [the native-media investigation](native-media-forwarding.md) for the source
preservation boundary and measured device capabilities.

## Components and scope

- `probes/macos/native-camera-fixture.m` creates one synthetic 320x240 H.264
  frame and provides a VideoToolbox decoder and coded-payload digest helper.
  Encoding creates test input; no forwarding path uses this encoder.
- `native-camera-formats.m` tests format-description construction and local
  decode. It neither installs a device nor requests privacy permissions.
- `native-camera-extension.m` advertises one camera, one source stream and two
  formats: H.264 and NV12. It retimes copies of the same H.264 payload, or lazily
  decodes that fixture once while serving NV12. Each streaming interval has a
  30-second host-clock limit. It logs format selection and decode counts.
- `native-camera-consumer.m` selects only the probe's fixed synthetic device ID.
  It inspects advertised formats or checks 30 samples by default, with an
  optional `--frames 1..180` bound for overlapping consumers. Capture
  requires existing camera consent and has an eight-second frame deadline plus
  a 20-second process backstop. It cannot select a physical camera or microphone.

Repeated keyframes isolate delivery mechanics; they do not test inter-frame
dependencies, motion, throughput, latency or keyframe recovery. Pixel checks
cover dimensions and format, not decoded color accuracy. Constructor and local
decode success do not imply extension IPC or application-delivery success.

## Non-installing test

Set `PLANK_SOURCE_ROOT` to the matching source checkout on the authorized Mac.
Choose a new, absent output directory outside the source tree:

```sh
bash "$PLANK_SOURCE_ROOT/scripts/test/build-macos-native-camera-formats.sh" \
  "$PLANK_SOURCE_ROOT" "$PLANK_PROBE_OUTPUT"
```

Both scripts verify OS, architecture and SDK and compile with warnings as
errors. This script prints source hashes and a JSON report. Inspect every
format's `constructed` field separately from `h264_decode_to_nv12`. The generic
secure-archive result is diagnostic only; it is not the camera framework's
cross-process delivery test. On the tested beta, all four constructors and
H.264-to-NV12 decode passed while generic archiving failed for all four.

## Extension build and signing

The build script accepts `--unsigned` for compilation/plist checks or `--sign`
for a certificate-backed build. Neither mode installs, activates or notarizes.
An unsigned result is not runnable extension qualification.

Signing inputs must be supplied privately through the environment:

- `PLANK_MACOS_TEAM_ID`: authorized developer team.
- `PLANK_MACOS_SIGNING_IDENTITY`: Developer ID Application certificate SHA-1.
- `PLANK_MACOS_APP_PROVISION_PROFILE`: absolute path to the matching Developer
  ID provisioning profile, authorizing the app ID
  `la.instinctual.PLANK.NativeCameraProbe` and system-extension installation.

The camera extension ID is `la.instinctual.PLANK.NativeCameraProbe.Camera`.
The app and extension share a team-prefixed application group. Generate the
required profile using the developer account/Xcode signing tools; a certificate
or a successful unprovisioned export does not substitute for the profile.
The script checks profile identity, team, capability, certificate and expiry,
embeds it in the app, signs inside out, and verifies the bundle seal. Keep
profiles and account identifiers outside Git. This check does not replace
Apple's runtime entitlement validation.

```sh
bash "$PLANK_SOURCE_ROOT/scripts/test/build-macos-native-camera-probe.sh" \
  "$PLANK_SOURCE_ROOT" "$PLANK_PROBE_OUTPUT" --sign
```

If an unlocked desktop keychain is unavailable from SSH, use the authorized
graphical session as described in the
[Mac build runbook](../build/macos-build-runbook.md). Remove temporary launchd
jobs afterward; do not change key access policy to make background signing work.

For Developer ID activation, notarize the complete app and staple its accepted
ticket, then require strict signature and Gatekeeper assessment. Use an existing
authorized Keychain notarization profile; update expired credentials interactively
with `notarytool store-credentials`. Never pass passwords in command arguments,
environment, plists or repository files. Build/sign/export success alone does
not establish notarization or activation.

## Application-delivery matrix

Stage the verified app at `/Applications/PLANK Native Camera Probe.app`, refusing
to overwrite an unrelated/existing installation. The build inherits the caller's
umask: before installation, normalize only this new app's directories and
executables to `0755` and data files to `0644`, then repeat strict signature and
Gatekeeper checks on the staged copy. Launch the following explicit
arguments through the signed app in the authorized graphical session. Activation
and camera consent use ordinary macOS dialogs. Do not change SIP, Gatekeeper,
TCC databases or system-extension policy.

| Arguments | Required evidence |
| --- | --- |
| `--activate` | Completed activation and extension present/enabled |
| `--inspect` | Exact synthetic device ID; advertised H.264 and NV12 formats |
| `--request-camera-permission` | Operator grants this probe camera access |
| `--capture native h264` | avc1 coded samples; hashes equal extension fixture |
| `--capture pixels nv12` | NV12 image buffers; extension decode counter advances |
| `--capture pixels h264` | Determine whether AVFoundation decodes, renegotiates, or rejects |
| `--capture native auto` / `--capture pixels auto` | Actual selected source/output formats |
| Reopen and overlapping native/pixel consumers | Negotiation behavior, stop/reopen and shared-stream limits |
| `--deactivate` | Completed deactivation; record any remaining registration awaiting reboot |

The consumer's `passed` field checks its requested output type and local sample
consistency. For passthrough acceptance, independently compare
`first_h264_sha256` with the extension's `synthetic_h264_sha256` log. Read the
`la.instinctual.PLANK.NativeCameraProbe` subsystem log for active format, decode
count and stop counters. A stable hash within the consumer is insufficient to
prove equality with the extension's source payload. Preserve output and logs
privately. Ensure mixed-consumer runs actually overlap before accepting them.

Explicit `h264`/`nv12` source cases retain the macOS configuration lock until
capture stops; otherwise AVFoundation can override `activeFormat` during session
startup. The `auto` cases intentionally omit that lock. Holding it is an
experiment on the synthetic device, not a policy for seizing a user's camera.
For overlap tests, start one reader with `--frames 180`, then the other with
`--frames 90`; compare their first/last callback host timestamps. Repeat both
orders. A native-output request with automatic source selection may receive
NV12 and fail the H.264-specific criterion; record the actual source selection.

The measured beta passes compressed hash preservation, framework-decoded NV12,
extension-decoded NV12 and overlapping mixed readers in both orders. The reverse
order exposed slower pixel delivery during source-format switching. See the
[measured matrix](native-media-forwarding.md#synthetic-macos-camera-probe) for
counts, overlap and limits. Source pixel format and application output format
are different contracts; the H.264-to-NV12 case needed no extension decoder.

After testing, deactivate through the app, verify it is inactive, remove the
exact temporary app and unload the probe's temporary GUI jobs. A completed
deactivation can leave a terminated registration awaiting uninstall at reboot;
record that state without claiming the registration is already absent. Do not
remove the containing app while its extension still needs the deactivation request.
If any required gate is unavailable, retain the concrete failure and leave
application delivery unqualified.
