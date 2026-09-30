# PLANK Service Deployment

## PAM Broker

Install the systemd-only broker as
`/usr/libexec/plank/plank-pam-broker`, install its service in
the system unit directory, and install
`packaging/host/linux/pam/plank-host` as `/etc/pam.d/plank-host`.
PLANK denies root remote login by default and delegates account
authorization to the host's PAM/SSSD policy, including FreeIPA HBAC. The
administrator may set `security.allow_root_login = true` in
`plank-host.conf`; this does not bypass PAM or active-desktop ownership.
PLANK has no application-specific user allowlist.
Restart `plank-pam-broker.service` after changing this setting; the
broker loads and validates it once at startup.

FreeIPA deployments use the exact PAM service identifier
`plank-host` in their HBAC service and rules. Directory-policy changes
then require no PLANK host or client update. Local service accounts
must retain locked passwords because IPA HBAC does not govern local identities.

The root supervisor is the broker's only local connector. It delegates a
connected socket to the media worker through a private inherited channel;
passwords and PAM responses flow directly to the broker, never through the
supervisor. The broker runtime
directory and socket are therefore `root:root` mode `0700` and `0600` instead
of being exposed through a supplementary group. After package installation,
run:

```bash
systemctl enable --now plank-pam-broker.service
systemctl status plank-pam-broker.service
```

The media worker activates PLANK authentication only after a successful
delegated broker-connection probe. Missing, malformed or untrusted channels
fail closed; there is no direct filesystem-socket fallback. The broker forks one bounded worker for
each PAM conversation so the worker, rather than the persistent listener, owns
the logind session. The worker exits when its stream releases the authentication
socket; the service limits itself to 40 total tasks.

## Host Supervisor and Client Service

Install the public Host launcher from `packaging/host/linux/bin/` as
`/usr/bin/plank-host`. Install the user-facing Client executable directly as
`/usr/bin/plank-client`. The Host media worker, systemd-only supervisor, PAM
broker, and other private helpers remain under `/usr/libexec/plank/`. A Host
development environment can override the media-worker binary path while
invoking its public launcher.

Build and bundle the pinned FFmpeg 9 client runtime next to Moonlight before
packaging it:

```bash
./scripts/build/build-client-ffmpeg.sh /usr/lib/plank
PKG_CONFIG_PATH=build/client-ffmpeg-9.0.1/install/lib/pkgconfig qmake6 ...
```

The script verifies the FFmpeg 9.0.1 source checksum and installs the required
shared libraries and LGPL license files under the private runtime directory.
The Client executable uses an `$ORIGIN`-relative RUNPATH to select that
directory, preventing an older distribution FFmpeg from being selected at
runtime without relying on a shell launcher or `LD_LIBRARY_PATH`.

Install `plank-host.service` in the system unit directory. It starts
at boot, queries logind for the active local X11 session on `seat0`, validates
the discovered Xauthority file against the session UID, and currently executes
the media worker as root with only `CAP_DAC_READ_SEARCH` effective/permitted.
Removing that remaining privilege is staged in
`docs/architecture/host-privilege-separation.md`; PAM descriptor delegation alone is not a
completed unprivileged worker. The supervisor does not hardcode `gdm`, a numeric
session UID, `DISPLAY`, or an Xauthority path. On a
GDM-to-user transition it stops the old worker before starting the new one.

This is Stage A session handling: an authenticated client can see GDM, and the
client automatically reconnects while the supervisor replaces the greeter
worker with the authenticated desktop worker. The supervisor does not inject
input into GDM or create a new graphical session.

`plank-display-prepare.service` runs before the display manager. It
keeps the workstation's Autodesk-derived `/etc/X11/xorg.conf` as the baseline
and atomically adds or removes only
`/etc/X11/xorg.conf.d/99-plank-headless.conf`. Configure `[display]`
in `plank-host.conf` with `startup_layout = physical` or `virtual`. The
virtual policy initializes one internal 1920x1080 login output. A single-head Xorg overlay
keeps the second virtual connector present but inactive so the same
PAM-authenticated desktop owner can later switch resolutions or enable the
second head from bookmark-selected 60 Hz modes through the supervisor's
allowlisted live-XRandR path. Other users
are refused. The default is `physical`. A changed static topology is applied on
reboot; the helper refuses to replace its overlay while the display manager is active.
Package removal deletes only an overlay carrying PLANK's generated
file marker; it does not alter the currently running X server.

The Host package tags only Wacom input devices mirrored through PLANK's UHID
path. Its Xorg input class disables pressure recalibration for that tag. This
keeps a nonzero initial pressure report from suppressing pen tip clicks while
leaving a physical tablet attached to the Host under its normal driver policy.
The rule sets `ID_INPUT.tags` for Xorg's `MatchTag`; a udev `TAG` alone does
not populate Xorg's input-class tags.
Xorg reads the input class when the graphical session starts; installing the
package does not change the setting in an already running session.

The administrator setting describes the boot policy. A host with
`startup_layout = physical` removes the headless overlay but may lease a
bookmark-selected logical layout over connected native scanouts for one remote
session. The supervisor restores the exact pre-session NVIDIA MetaMode at
disconnect. A host with `startup_layout = virtual` uses the packaged-EDID
headless workflow and does not advertise a physical bookmark layout. The RPM explicitly
applies the packaged preset on upgrade so the pre-GDM cleanup cannot remain
disabled while a stale owned overlay survives a reboot.

The client is interactive and ships no systemd user service or desktop
autostart entry. Launch it explicitly from the desktop application icon or the
`plank-client` command. Enable only the host services:

```bash
sudo systemctl enable --now plank-pam-broker.service \
  plank-display-prepare.service \
  plank-host.service
```

Configure every host runtime option in the single root-managed
`/etc/plank/host.conf`. Ordinary client preferences remain
in the user's Qt settings. Root-managed client policy lives separately in
`/etc/plank/client.conf`; a present policy key overrides
the saved preference and locks its UI control. The client does not source
per-user shell configuration. Capture selection follows the authenticated
bookmark topology for each session; there is no fixed administrator
capture-output selector.
The active `network.port` value supplies the TCP/UDP endpoint when a bookmark
address does not include an explicit port. An explicit `hostname:port` bookmark
continues to take precedence.
The software profile expands x264 worker affinity to the qualified CPU set and
uses 16 slices on hardware-test-host; neither the CPU count nor slice count is a universal
default. The host configuration uses INI-style section headers and one globally
scoped `key = value` setting per line. The package no longer loads a host
environment file, and shell environment syntax is not accepted in the host
configuration.

mDNS is disabled by default on both sides. Set
`mdns_discovery = true` in the host `plank-host.conf` to publish
the host with Avahi. The client preference defaults off but remains editable
while `network.mdns_discovery` is omitted or commented in
`plank-client.conf`. Set `mdns_discovery = true` or `false` under its
`[network]` section only to impose an administrator-managed value. Saved and
manually entered workstations continue to connect when mDNS is disabled.

The Linux client writes its already-redacted runtime output to private,
persistent per-user files under `$XDG_STATE_HOME/plank/logs/`, or
`~/.local/state/plank/logs/` when `XDG_STATE_HOME` is unset or not an
absolute path. The directory is mode `0700`; each timestamped
`plank-client-*.log` is mode `0600`, capped at 10 MiB, and only the
newest 10 files are retained. Use these files as the primary client diagnostic
record. Only startup failures that prevent creation of the private log fall
back to stderr and may appear in the desktop session's user journal.

The host writes its streaming runtime diagnostics only to
`/var/log/plank/host.log`. Supervisor, PAM-broker, and display-preparation
output is retained separately as `host-supervisor.log`, `pam-broker.log`, and
`display-prepare.log` in the same directory. The RPM creates and owns
the root-only log directory with mode `0700` before services start. On systemd
252, `append:` output is opened before `LogsDirectory=` is processed, so the
directory must already exist on a fresh installation. The main runtime, supervisor, and
PAM-broker logs are mode `0600`, while the display helper log remains private
through that directory. The active file rotates at 10 MiB and retains
`plank-host.log.1` through `.10`; logrotate applies the same size and retention
limits to the three helper logs. The system journal retains service lifecycle
state without duplicating routine PLANK application output.

The PLANK host is built without Sunshine's browser configuration
server, frontend assets, or legacy RTSP listener. There is no listener on the
former Web UI port and no second writable configuration path. The remaining
HTTPS authentication and native QUIC session/media/input services run inside
the packaged Host process.

PLANK uses a dual-stack wildcard HTTPS listener and an IPv4 wildcard
QUIC listener. When explicitly enabled, mDNS discovery also uses the available
interfaces. The client does not restrict which local network interface carries
control, credentials, or media. Enforce the intended deployment boundary in
the host firewall because the process listens on wildcard addresses.

Install `packaging/host/linux/firewalld/plank.xml` in firewalld's service
directory, reload firewalld, and enable it only in the zone assigned to the
approved PLANK/VPN interface. Do not add the service to the default
zone. The development hardware-test-host host currently has firewalld disabled, so its
wildcard listeners are suitable only for the isolated qualification network.
