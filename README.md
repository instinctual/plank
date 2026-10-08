# PLANK

PLANK (Playa Connekt) is an open-source, low-latency remote-workstation system
for Linux and macOS. It is built for color-sensitive creative work and everyday
desktop access, including physical workstations used both locally and remotely.

Install a **Host** on the workstation and a **Client** on the computer you use
to access it. This repository brings together both products, their shared
transport, packaging, documentation and qualification tests.

[Downloads](https://github.com/instinctual/plank/releases) ·
[Documentation](docs/README.md) ·
[Build from source](docs/development/build/from-source.md) ·
[Contribute](CONTRIBUTING.md)

## Platforms

| Product | Platform | Package |
| --- | --- | --- |
| Linux Host | Rocky Linux 9.7 / RHEL 9 family, x86-64, NVIDIA graphics and X11 | RPM |
| Linux Client | Ubuntu 26.04, x86-64; Wayland is the qualified desktop path | DEB |
| macOS Host | macOS 27 or newer, Apple Silicon | Signed, notarized PKG |
| macOS Client | macOS 15 or newer, Apple Silicon | Signed, notarized PKG |

Rocky Linux 9.7 is the Linux Host build and qualification baseline. The Mac
Client uses one package for macOS 15 and newer, built with SDK 27 or newer;
the Host has a separate macOS 27 minimum. Windows and other platforms are not
currently qualified PLANK products.

PLANK is in late integration and production hardening. Use the
[release notes](https://github.com/instinctual/plank/releases) for the version
you install. Supported targets do not imply that every GPU, tablet, display
arrangement or OS update has passed qualification. See the
[platform boundaries](docs/development/platforms.md) and
[acceptance criteria](docs/development/acceptance-criteria.md).

## What PLANK provides

- **Video quality:** selectable H.264 and HEVC profiles, including 8/10-bit and
  4:4:4 workflows. Linux RGB-identity profiles preserve component mapping;
  available profiles and capture precision depend on the Host.
- **Workstation access:** operating-system account authentication, existing
  desktop access, session takeover and recovery across login/logout.
- **Display choices:** physical and virtual/headless layouts, Client display
  matching, and native-pixel or scaled presentation within each Host's limits.
- **Input and audio:** keyboard, mouse, Wacom/pen input, desktop audio and text
  clipboard synchronization. Tablet behavior is platform-specific; Linux
  raw-HID forwarding and macOS pen-pressure injection are different paths.
- **Connection controls:** per-bookmark capture, encoding and bitrate settings,
  plus an in-session toolbar with live statistics and session controls.
- **Native transport:** encrypted QUIC using Kyber/Kymux and Quinn, with RaptorQ
  forward error correction for media.

[Microphone forwarding](docs/user/microphone.md) is available from Linux and
macOS Clients to a compatible macOS Host, not to Linux Hosts. Optional media
features require their supported Client/Host combination and OS permissions.

Ten-bit encoding does not guarantee ten-bit capture: the Linux NvFBC path has
an 8-bit source even when encoded as 10-bit. Native X11/XShm capture is the
experimental Linux 10-bit source path. Decoder selection preserves the requested
format: exact-format hardware decoding is preferred, with software fallback
where necessary. A GPU's generic HEVC support is not proof of 10-bit 4:4:4 support.

PLANK is not a drop-in GameStream, Sunshine or Moonlight replacement on the wire.
Use PLANK Hosts and Clients with compatible release versions. Gamepads, generic
touchscreen forwarding, HDR and automatic UPnP port mapping are not current
product features.

## Install and connect

Download packages from [PLANK releases](https://github.com/instinctual/plank/releases).
Follow that release's upgrade notes; some transport changes require upgrading
Host and Client together. Candidate builds are not releases.

On Linux, install the downloaded package with the package manager. Replace
`VERSION` and `RELEASE` below with the actual filename:

```bash
# Rocky Linux Host
sudo dnf install ./plank-host-VERSION-RELEASE.el9.x86_64.rpm

# Ubuntu Client
sudo apt install ./plank-client_VERSION_amd64.deb
```

On macOS, open the appropriate Host or Client PKG and complete the setup window.
macOS controls privacy approvals; installation does not silently grant them.
See [permission setup](docs/user/permissions.md). The macOS Host installer
requires FileVault to be disabled; remote FileVault preboot unlock is not
supported.

Open PLANK Client, add a bookmark with the Host address and a nickname, and
choose the display layout and encoding profile. Bookmarks can be created while
a Host is offline. Reachable Hosts advertise their available options; check
manual selections when configuring an offline Host.

The default Host port is **28989 on TCP and UDP**. Provide a reachable path
through your LAN, VPN or administrator-managed forwarding/firewall rules.
PLANK does not supply a connection broker or configure your router.
Host identity uses [trust on first use](docs/security/host-identity-trust.md);
encryption does not independently verify an unknown Host on its first connection.

## Configuration and removal

Administrator policy lives in `/etc/plank/host.conf` and
`/etc/plank/client.conf` on both operating systems. Use the template for your
platform; Linux and macOS Host options are not interchangeable:

- [Linux Host configuration](packaging/host/linux/config/plank-host.conf).
- [macOS Host configuration](packaging/host/macos/config/plank-host.conf).
- [Client configuration](packaging/client/config/plank-client.conf).

Bookmarks and ordinary Client preferences are per-user. On the Linux Host,
`[display] startup_layout = physical` preserves a physical-first boot workflow;
`virtual` selects headless startup. Session display choices belong to bookmarks.

Remove Linux packages with `sudo dnf remove plank-host` or
`sudo apt remove plank-client`. On macOS, use the installed Host or Client
uninstall script described in [macOS configuration and removal](docs/user/macos-configuration.md).
Ordinary macOS uninstall retains configuration and user data; it is not a purge.

## Source and development

| Location | Role |
| --- | --- |
| [Linux Host](https://github.com/instinctual/plank-host-linux) at `apps/host/linux/` | Maintained Sunshine-derived Host submodule |
| [Client](https://github.com/instinctual/plank-client) at `apps/client/` | Shared Ubuntu/macOS Client submodule, derived from Moonlight Qt |
| [macOS Host](apps/host/macos/) | Native Host source in this repository, not a separate fork |
| [Transport](protocol/plank-transport/) and [protocols](protocol/) | Shared transport, schemas and negotiation |
| [Packaging](packaging/) and [scripts](scripts/) | Platform installers, reproducible builds and validation |
| [Tests](tests/), [probes](probes/) and [documentation](docs/README.md) | Automated checks, hardware qualification and product contracts |

Start with [Building from source](docs/development/build/from-source.md), then
the appropriate platform runbook. Build from the parent repository's pinned
submodule revisions and required dependency patches, not independent upstream
checkouts or arbitrary system libraries. Hosted CI and documented local builders
use the same platform contracts. Root CMake builds qualification tools and tests,
not all product packages.

See [contributing](CONTRIBUTING.md) for component changes and coordinated parent
pin updates. [HANDOFF.md](HANDOFF.md) records development state and outstanding
tests; it is not a release announcement. Locally retained packages follow the
[artifact catalog layout](artifacts/README.md).

## Credits and licensing

PLANK builds on [Sunshine](https://github.com/LizardByte/Sunshine),
[Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt),
[Kyber](https://gitlab.com/kyber), and other open-source projects.
Their histories, copyright notices and component licenses are retained.

PLANK contains multiple licenses; consult the license files in each component
and dependency. The PLANK transport boundary is AGPL-3.0-or-later.
