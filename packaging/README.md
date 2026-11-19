# PLANK Package Layout

Use the exact machine-specific workflow in
`docs/development/build/release-build-runbook.md` for candidate builds and validation. This file
defines package contents; the runbook defines the repeatable release procedure
and known failure signatures.

Build scripts first assemble into a candidate work directory, then collect
gated packages under `artifacts/packages/{releases,candidates}/<version>/<os>/`.
See [artifact collection](../artifacts/README.md). Do not write flat package
copies or rename a feature package to look like a mainline release.

## Host RPM

The RHEL/Rocky package is named `plank-host` and installs:

- `/usr/bin/plank-host`, the public host launcher;
- `/usr/libexec/plank/plank-host`,
  `/usr/libexec/plank/plank-host-supervisor`, and
  `/usr/libexec/plank/plank-pam-broker` as private service
  implementations, plus assets under `/usr/share/plank/`;
- system units, `/etc/pam.d/plank-host`, the single root-managed
  `/etc/plank/host.conf`,
  Wacom udev and module-load rules, and the firewalld service definition;
- GPL/source-build metadata and all applicable third-party notices.

Compile Sunshine with its asset path set to `/usr/share/plank`. The
application media libraries are linked into the qualified binary; ordinary OS
libraries are RPM requirements. The NVIDIA kernel/user driver, CUDA driver
interface, Xorg, and PAM remain platform-owned prerequisites and are not
bundled. Installation must not enable the firewalld service in a default zone
or add an interactive user to an authorization group automatically.

The production host omits Sunshine's browser configuration server, frontend
assets, Node/npm build dependency, and legacy RTSP setup listener. Required
client-facing NVHTTP/HTTPS authentication and native QUIC session, media,
input, event, and control services remain present. Sunshine's native
configuration file uses INI-style section headers with one globally scoped
`key = value` setting per line, including
`mdns_discovery = false` by default. The complete accepted-option
reference is in `apps/host/linux/docs/configuration.md`.

The RPM loads Linux `uhid` after reloading its udev rules so the active local
session receives the `/dev/uhid` ACL before Sunshine advertises exact Wacom
redirection. The module-load configuration repeats this setup at boot.

Tangent forwarding adds a pinned USB/IP VHCI driver to the same RPM, including
its original embedded signature, GPLv2 license and complete corresponding source
under `/usr/share/doc/plank-host/usbip`. Installation refreshes compatibility
links through the system's normal kernel ABI checks; it does not enable ELRepo,
fetch another RPM or update the kernel. A missing/incompatible driver disables
only Tangent forwarding. No TCP3240 listener is installed. The Ubuntu Client
uses the system libusb runtime and a narrow active-seat udev rule. See the
Tangent integration plan for the currently qualified panel models.

`plank-host.service` starts at boot and runs one root-owned machine
Sender. It follows logind's active local X11 session on `seat0` and attaches
the Sender to that session's validated display, Xauthority, and audio paths.
It never assumes a UID, display number, or Xauthority path. The service uses a
small capability set and read-only user homes; PAM remains in its own broker.
The RPM creates a stable local TLS keypair; its directory and private key are
readable only by root.
The certificate helper validates self-signing, RSA strength, validity dates,
matching key material, and the required DNS-only SAN profile. An upgrade
replaces an invalid certificate atomically but leaves an already-valid keypair
unchanged.

The PLANK workstation UUID is stored separately in
`/var/lib/plank/plank-state.json`. The root-only file is forced on
the machine Sender, so GDM and the logged-in desktop cannot appear
as different computers merely because they have different home directories.
The helper preserves an existing valid machine state and atomically replaces
invalid state. Pairing remains disabled and the file is not client trust state.

Host streaming diagnostics are written to the private persistent file
`/var/log/plank/host.log`. Supervisor, PAM-broker, and display-preparation
output is written to separate files in `/var/log/plank`; routine application
output is not duplicated into the system journal. The service creates the log
directory with mode `0700`, and both the internal logger and packaged
logrotate policy cap product logs at 10 MiB with 10 retained generations. The
explicit `log_path` in `plank-host.conf` prevents the machine Sender's private
`HOME` from selecting a hidden legacy Sunshine path.

Create and audit the package-layout host binaries with:

```bash
./scripts/build/build-host-package-binaries.sh
```

This separate release build fails if Sunshine embeds the development
`/usr/local/assets` path or has an unresolved runtime dependency.

Build the unsigned development RPM without installing it on the workstation:

```bash
./scripts/package/build-host-rpm.sh
rpm -qpi "$PLANK_HOST_RPM"
rpm -qpl "$PLANK_HOST_RPM"
```

## Client DEB

The Ubuntu package is named `plank-client` and installs the user-facing
executable directly at `/usr/bin/plank-client`, plus root-owned administrator
policy, desktop metadata, and third-party notices.
FFmpeg 9.0.1
libraries live only in
`/usr/lib/plank/`; the executable's `$ORIGIN`-relative RUNPATH selects this
private directory without modifying Ubuntu's loader configuration, exporting
`LD_LIBRARY_PATH`, or replacing system FFmpeg.
Kyber's pinned commit is recorded in `BUILD-INFO`, and its AGPL and third-party
notices are installed with the package. KyProto owns native media FEC; the
retired common-c nanors implementation is not built or packaged.
Qt Quick's QML modules are distribution-owned runtime dependencies and must be
declared explicitly because ELF dependency scanners cannot discover QML
imports. A fresh Ubuntu installation requires the Qt Quick, Controls, Layouts,
and Window QML module packages. It also requires Ubuntu's
`intel-media-va-driver-non-free`, which provides the `iHD_drv_video.so`
implementation behind the generic VA-API libraries used for Intel hardware
decoding. This package conflicts with and replaces the open variant.

Build the runtime and verify its closure with:

```bash
./scripts/build/build-client-ffmpeg.sh build/client-app build/client-ffmpeg-9.0.1
./scripts/package/audit-package-runtime.sh \
  build/client-app/plank-client build/client-app/lib
```

Build from a clean tree, then assemble an unsigned development package on the
qualified Ubuntu builder with the pinned FFmpeg work directory:

```bash
./scripts/build/build-client-package-binaries.sh \
  apps/client build/client-ffmpeg-9.0.1 \
  build/package-client
./scripts/package/build-client-deb.sh \
  build/package-client/app/plank-client build/client-ffmpeg-9.0.1 \
  build/client-package-output apps/client
dpkg-deb --info "$PLANK_CLIENT_DEB"
dpkg-deb --contents "$PLANK_CLIENT_DEB"
```

The client is an interactive application and deliberately ships no systemd
user service or desktop autostart entry. Launch it from the PLANK
Client application icon or the `plank-client` command. Package
installation does not inspect or modify arbitrary user home directories.
Administrator-enforced client policy lives only in root-owned
`/etc/plank/client.conf`; the package registers it as a
Debian conffile. Its active `network.port` value defines the TCP/UDP port used
when a bookmark address omits an explicit port. A commented or omitted optional
preference key leaves the corresponding normal Qt preference user-configurable;
an explicit supported value takes precedence and disables that UI control. The
default template leaves mDNS policy commented, so client mDNS discovery defaults
off but remains editable. The client does not source
per-user shell configuration and has no network-interface allowlist; apply any
deployment boundary on the host firewall.

For a direct workstation launch, pass the host and username while supplying
the password on standard input:

```bash
plank-client stream 192.0.2.104 Desktop \
  --plank-user operator --plank-password-stdin
```

An interactive terminal disables echo while reading the password. For
automation, connect standard input to a protected credential provider. Never
put a password in the argument list, environment, URL, service file, or shell
history. An explicit CLI resolution such as `--resolution 2560x1440` overrides
native-display selection for that process only.

## Release Gates

For both packages, test clean install, upgrade, rollback, and uninstall in a
fresh target-OS image. Verify package signatures, file ownership/modes, unit
sandboxing, configuration preservation, no unresolved libraries, no files
outside the manifest, and no leftover service, PAM, udev, or virtual-input
state after removal. The host must also reject unsupported SELinux modes and
missing GPU prerequisites before starting a remote session.
