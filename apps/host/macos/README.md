# PLANK macOS Host

This is the native **macOS Host** implementation in the main PLANK repository.
It provides remote workstation access from PLANK Clients on Ubuntu and macOS.
It is not the macOS backend of the Sunshine-derived
[Linux Host](https://github.com/instinctual/plank-host-linux).

The Host targets **macOS 27 or newer on Apple Silicon** and is distributed as a
signed, notarized PKG. The separate Mac Client supports macOS 15 and newer;
that does not change the Host requirement.

[Downloads](https://github.com/instinctual/plank/releases) ·
[Project overview](../../../README.md) ·
[macOS configuration](../../../docs/user/macos-configuration.md)

## Capabilities

- ScreenCaptureKit desktop capture and hardware VideoToolbox encoding, with
  full-range HEVC 10-bit 4:2:0 and 4:4:4 profiles where supported.
- Login-screen and desktop access, authenticated session ownership, takeover,
  and recovery across login/logout.
- Headless virtual-display management, fixed-size and Match Client requests,
  with macOS-specific logical/backing-pixel handling.
- Keyboard, mouse, scrolling, custom cursor display and pen-pressure input.
  macOS pen injection is distinct from Linux raw-HID tablet forwarding;
  Linux application features such as Flame Tablet Margins are not implied.
- Desktop audio through PLANK Output, optional Client microphone input through
  PLANK Microphone, and an optional PLANK Camera extension for supported senders.
- Bidirectional text clipboard and the shared native QUIC/RaptorQ transport.

The Host is packaged and connects through the ordinary PLANK Client. Remaining
hardware, long-session and OS-version gates are tracked in
[HANDOFF](../../../HANDOFF.md) and the
[acceptance documentation](../../../docs/development/acceptance-criteria.md);
component tests alone are not functional acceptance.

## Install, permissions and removal

Open the Host PKG and complete the installed app's setup window.
Screen/input and audio access remain subject to macOS permission policy.
PLANK does not silently edit the privacy database, and a new user or OS update
may require renewed approval. See [permission setup](../../../docs/user/permissions.md).

The Host installer requires FileVault to be disabled. Remote FileVault preboot
unlock is not supported.

Configuration lives in `/etc/plank/host.conf`; use the
[macOS template](../../../packaging/host/macos/config/plank-host.conf), not the Linux
Host template. The default port is 28989 on TCP and UDP, and firewall/routing
remain administrator-managed. Machine identity and mutable state are separate
from configuration.

The installed app contains `Contents/Resources/uninstall.sh`. Follow the
[uninstall procedure](../../../docs/user/macos-configuration.md) so services,
audio drivers and any enabled camera extension are removed safely. Normal
uninstall retains configuration, identity and logs.

## Source map

| Directory | Responsibility |
| --- | --- |
| `session/` | Machine/desktop roles, lifecycle, permissions, configuration and ownership |
| `auth/` | OS-account verification, authorization and session identity |
| `control/` | Discovery/control requests and display management |
| `media/` | Capture, encoding, audio/video submission and stream lifetime |
| `input/` | Remote keyboard, mouse and pen events |
| `audio-device/` | PLANK Output and PLANK Microphone integration |
| `camera-device/` | Optional virtual-camera extension and producer/broker boundary |

Packaging is in [`packaging/host/macos/`](../../../packaging/host/macos/).
The shared transport is in [`protocol/plank-transport/`](../../../protocol/plank-transport/).
Neither is duplicated in a separate Mac Host repository.

## Development

Use [Building from source](../../../docs/development/build/from-source.md) and
the [macOS Host build runbook](../../../docs/development/build/macos-build-runbook.md).
Host builds require SDK 27 or newer and a macOS 27 deployment target.
Developer compilation and signed/notarized distribution have different
requirements; maintainer signing credentials are never source dependencies.

Contributions follow the parent [contributor guide](../../../CONTRIBUTING.md).
Preserve the license notices in this source and all linked dependencies;
see [project licensing](../../../README.md#credits-and-licensing).
