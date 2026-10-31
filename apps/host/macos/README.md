# PLANK macOS Host

This is the native **macOS Host** implementation in the main PLANK repository.
It provides remote workstation access from PLANK Clients on Ubuntu and macOS.
It is not the macOS backend of the Sunshine-derived
[Linux Host](https://github.com/instinctual/plank-host-linux).

The Host uses one signed, notarized PKG for **macOS 26.7 or newer on Apple
Silicon**, built with SDK27 or newer. Newer APIs remain guarded at runtime.
The separate Mac
Client supports macOS 15 and newer, which does not lower the Host requirement.

Chris (cnoellert) owns macOS 26.7 hardware and session validation. Compiler and
component checks are recorded separately from installed streaming and
login-screen results; see the [26.7 build and validation plan](../../../docs/development/plans/macos26-host-backport.md).

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
Host builds require SDK 27 or newer and a macOS 26.7 deployment target.
The optional 27.0 target is for candidate regression comparisons only.
Developer compilation and signed/notarized distribution have different
requirements; maintainer signing credentials are never source dependencies.

Contributions follow the parent [contributor guide](../../../CONTRIBUTING.md).
Preserve the license notices in this source and all linked dependencies;
see [project licensing](../../../README.md#credits-and-licensing).

## Host display mirroring candidate

The administrator can opt into `[general] mirror_host_displays=true` in
`/etc/plank/host.conf` (default false). Other online Host displays mirror PLANK's
virtual workspace during a desktop session; physical screens remain visible.
This does not create independent virtual monitors or follow the Client monitor
count. The macOS sign-in screen is unchanged. The graphical
agent snapshots display identities, modes, origins and mirror relationships
before preparing its owned virtual output. Public Quartz configuration makes
PLANK the mirror master for the remote session, with `kCGConfigureForAppOnly`;
no permanent/session display preferences or private display-disable API are used.
The requested geometry and mirror ownership must read back correctly before
launch. A failed transaction, revoked preparation, failed launch, normal
or lost stream, or a successful preparation abandoned for 60 seconds retires
the lease. Media and input drain before normal restoration. A late teardown
cannot restore over a newer preparation. Restoration checks mode/mirror/origin
readback and never writes to an absent or identity-replaced display. Failure
retires the graphical worker; Quartz app-lifetime settings and the virtual
output then end with that process. A hot-added display is not absorbed silently.

SDK27 retains CGVirtualDisplay until process exit. While the worker remains
idle, PLANK mirrors the restored local main display instead of leaving an
extra extended workspace. On reconnect only that owned mirror is detached
before mode preparation. Native WindowServer owns application-window reflow;
exact per-window positions, fullscreen Spaces, unusual rotation/mirror sets,
physical hotplug and crash recovery still require the signed candidate trial.
No logout, AX window enumeration, new permission, screen blanking or permanent
preference change is part of this implementation.

Synthetic coverage: `scripts/test/build-macos-display-layout.sh` executes the
actual lease with link-time Quartz substitutes. `tests/auth/macos-display-lease.py`
uses the actual authenticated runtime with the synthetic display provider to
check normal QUIC disconnect, failed preparation and the production 60-second
abandoned-prepare deadline.
Existing native session tests check the post-drain notification and all retained
teardown cases. These fixtures never qualify physical mirroring or restoration.
