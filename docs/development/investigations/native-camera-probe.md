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

## Private physical-capture decode

The format-probe build also produces `native-camera-decode`. It reads bounded
private records containing a four-byte big-endian payload length followed by
exactly one captured V4L2 buffer. Construct these outside Git from the verified
capture and its per-buffer lengths; check every original payload hash before
transfer and the transferred file hash before testing. Never put the captures
or their machine-specific manifest in the repository.

Run `native-camera-decode h264 WIDTH HEIGHT PRIVATE_RECORDS`, or use `mjpeg`.

The tool accepts at most 300 frames, 4 MiB per frame and 1920x1080 dimensions,
with a 30-second process limit. It opens no devices and produces no image files.
For H.264 it replaces Annex B start codes with length prefixes required by
Core Media, retaining every NAL payload byte. Parameter sets produce the format
description; later format changes fail this bounded qualification. JPEG bytes
are passed directly. VideoToolbox decodes to NV12; errors, drops and mismatched
dimensions fail. This is Host decoding, with no compression session.

All four measured physical captures pass: 90 frames each of 720p/1080p H.264
and MJPEG, with 360 decoded frames and no decoder errors/drops. VideoToolbox
reports hardware acceleration for H.264 and software decoding for JPEG. This
does not qualify sustained timing, color, transport loss or application delivery.

### Physical camera and microphone transport probe

`probes/network/plank-transport/native-camera-live.cpp` joins the actual Linux
V4L2 capture and Client microphone modules to the native encrypted transport.
The Mac receiver uses the production Opus decoder through
`native-audio-stats.c`. It records private camera payloads and per-frame hashes;
audio stays in memory and only aggregate counts/levels are reported. The probe
mutes and reopens the microphone while the camera continues. It uses its own
ephemeral pinned certificate and session token, not the product authentication
or installed virtual-device paths.

Build the exact transport archive on each authorized builder first. In these
commands, `PLANK_SOURCE_ROOT` selects the reviewed source snapshot,
`PLANK_PROBE_BUILD` an external build directory, and `PLANK_TRANSPORT_ARCHIVE`
the matching platform's `libplank_transport.a`. Record root and Client commits
and hashes of separately staged probe sources. On the Ubuntu Client builder:

```bash
cd "$PLANK_SOURCE_ROOT"
c++ -std=c++17 -O2 -Wall -Wextra -Werror -DPLANK_TRANSPORT=1 \
  -Iprotocol/plank-transport/include -Iapps/client/app/streaming/camera \
  -Iapps/client/app/streaming/audio $(pkg-config --cflags Qt6Core sdl3 opus) \
  probes/network/plank-transport/native-camera-live.cpp \
  apps/client/app/streaming/camera/linuxnativecamera.cpp \
  apps/client/app/streaming/audio/microphone.cpp "$PLANK_TRANSPORT_ARCHIVE" \
  $(pkg-config --libs Qt6Core sdl3 opus) -lcrypto -ldl -lpthread -lm -lrt \
  -o "$PLANK_PROBE_BUILD/native-camera-live"
```

On the authorized macOS 27/SDK27 development Mac:

```bash
cd "$PLANK_SOURCE_ROOT"
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=27.0 \
  -Iapps/host/macos/media probes/network/plank-transport/native-audio-stats.c \
  -c -o "$PLANK_PROBE_BUILD/native-audio-stats.o"
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror -mmacosx-version-min=27.0 \
  -Iprotocol/plank-transport/include \
  probes/network/plank-transport/native-camera-live.cpp \
  "$PLANK_PROBE_BUILD/native-audio-stats.o" "$PLANK_TRANSPORT_ARCHIVE" \
  -framework AudioToolbox -framework Security -framework SystemConfiguration \
  -framework CoreFoundation -lpthread -lm -o "$PLANK_PROBE_BUILD/native-camera-live"
```

Transfer and hash-verify the Linux executable on the authorized hardware Client;
do not compile there. Run as its existing graphical user, preserving the user's
audio-server environment. Check that no other process owns the camera first.
Provision an ephemeral certificate using `probes/macos/loopback-cert.cnf`, and
supply the same unpredictable 64-character `PLANK_CAMERA_PROBE_TOKEN` through
each process environment without logging its value. The receiver takes
`server BIND CERT KEY PRIVATE_RECORDS`; the Client takes
`client REMOTE CERT_SHA256 DEVICE h264|mjpeg`. Addresses and device paths are
operator-selected arguments, never product defaults. The output record file
must not already exist and is created mode 0600 outside Git. Remove temporary
credentials/listeners afterward and verify the original camera mode is restored.

Compare received hashes by frame sequence with the source hashes, then run the
Mac decode probe on the private receiver records. A successful pair proves
native payload preservation and simultaneous stereo Opus transport, including
mute/reopen. It does not test the installed HAL, CMIO extension, product login,
color fidelity or lip sync. If a diagnostic tunnel is needed, record that fact:
its throughput and packet-gap results do not qualify direct UDP behavior.
