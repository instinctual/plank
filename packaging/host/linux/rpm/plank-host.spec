%{!?plank_version:%{error:plank_version must be defined by the package builder}}
%{!?plank_release:%{error:plank_release must be defined by the package builder}}

Name:           plank-host
Version:        %{plank_version}
Release:        %{plank_release}%{?dist}
%global debug_package %{nil}
Summary:        Authenticated PLANK workstation host
License:        GPL-3.0-only
URL:            https://github.com/instinctual/plank
Source0:        plank-host-payload.tar.gz

Requires:       pam
Requires:       systemd
Requires:       systemd-udev
Requires:       firewalld-filesystem
Requires:       openssl-libs
Requires:       libXcomposite
Requires:       libXext
Requires:       logrotate
Requires:       xorg-x11-server-Xorg
Requires:       xorg-x11-server-utils
Requires(post): systemd systemd-udev kmod
Requires(post): openssl
Requires(post): hostname
Requires(preun): systemd
Requires(postun): systemd

%description
PLANK host services, authentication broker, media host, and
workstation integration for the qualified RHEL/Rocky deployment.

%prep
%setup -q -c -T
tar -xzf %{SOURCE0}

%build

%install
mkdir -p %{buildroot}
cp -a payload/. %{buildroot}/

%post
/usr/libexec/plank/plank-host-certificate \
  /etc/plank/tls/cert.pem /etc/plank/tls/key.pem || exit 1
/usr/bin/chown root:root \
  /etc/plank/tls/key.pem /etc/plank/tls/cert.pem || exit 1
/usr/bin/chmod 0600 /etc/plank/tls/key.pem || exit 1
/usr/bin/chmod 0644 /etc/plank/tls/cert.pem || exit 1
/usr/libexec/plank/plank-host-state \
  /var/lib/plank/plank-state.json || exit 1
/usr/bin/chown root:root \
  /var/lib/plank/plank-state.json || exit 1
/usr/bin/chmod 0600 /var/lib/plank/plank-state.json || exit 1
%systemd_post plank-pam-broker.service plank-display-prepare.service plank-host.service
/usr/bin/systemctl preset plank-display-prepare.service >/dev/null 2>&1 || :
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :
/usr/sbin/modprobe uhid >/dev/null 2>&1 || :
/usr/bin/udevadm trigger --action=change --subsystem-match=misc --sysname-match=uhid >/dev/null 2>&1 || :

%preun
if [ "$1" -eq 0 ]; then
  /usr/libexec/plank/plank-display-prepare --cleanup || exit 1
fi
%systemd_preun plank-pam-broker.service plank-display-prepare.service plank-host.service

%postun
%systemd_postun plank-display-prepare.service
%systemd_postun_with_restart plank-pam-broker.service plank-host.service

%files
%license /usr/share/licenses/plank-host/LICENSE-Sunshine
%license /usr/share/licenses/plank-host/LICENSE-Kyber-AGPLv3
%license /usr/share/licenses/plank-host/LICENSE-Kyber-Notice
%doc /usr/share/doc/plank-host/README.md
/etc/pam.d/plank-host
%config(noreplace) /etc/plank/host.conf
%config(noreplace) /etc/logrotate.d/plank-host
%dir %attr(0755,root,root) /etc/plank
%dir %attr(0700,root,root) /etc/plank/tls
%ghost %config(noreplace) %attr(0644,root,root) /etc/plank/tls/cert.pem
%ghost %config(noreplace) %attr(0600,root,root) /etc/plank/tls/key.pem
%dir %attr(0750,root,root) /var/lib/plank
%dir %attr(0700,root,root) /var/log/plank
%ghost %attr(0600,root,root) /var/lib/plank/plank-state.json
/usr/bin/plank-host
/usr/libexec/plank/plank-host
/usr/libexec/plank/plank-host-supervisor
/usr/libexec/plank/plank-pam-broker
/usr/libexec/plank/plank-host-certificate
/usr/libexec/plank/plank-host-state
/usr/libexec/plank/plank-display-prepare
/usr/lib/systemd/system/plank-pam-broker.service
/usr/lib/systemd/system/plank-display-prepare.service
/usr/lib/systemd/system/plank-host.service
/usr/lib/systemd/system-preset/90-plank.preset
/usr/lib/modules-load.d/plank.conf
/usr/lib/udev/rules.d/70-plank-host-wacom.rules
/usr/share/X11/xorg.conf.d/90-plank-virtual-wacom.conf
/usr/lib/firewalld/services/plank.xml
/usr/share/plank/

%changelog
* Sat Aug 29 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.187.datasmash
- Carry encrypted audio and audio-FEC packets over the experimental media plane

* Sat Aug 29 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.185.datasmash
- Carry encrypted video/FEC packets over the experimental QUIC data plane

* Sat Aug 29 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.184.datasmash
- Fix the experimental data-plane certificate pin byte order

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.183.datasmash
- Add the isolated experimental single-port transport handshake

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.181
- Harden and scale the Native X11 10-bit x264 identity path

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.180
- Rename the host configuration for host/client naming parity

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.174
- Expose and document LAN and WAN media-encryption policies
- Keep systemd-only host service binaries private under libexec

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.173
- Reduce display startup configuration to physical or virtual policy
- Use one complete canonical EDID per virtual output

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.172
- Name the packaged x264 encoder section precisely

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.171
- Make bookmark negotiation the sole capture-source and encoder-backend authority.

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.170
- Minimize the branded PAM stack and clarify the host Wacom udev rule name.

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.168
- Replace the inherited application catalog with one internal Desktop stream.

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.167
- Make root authentication an explicit, secure-default host setting.

* Fri Aug 28 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.166
- Delegate account authorization to the branded PAM/SSSD service.
- Restrict the PAM broker socket and TLS private key to root.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.22
- Organize PAM and media runtime files under isolated PLANK subdirectories.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.21
- Isolate the media worker runtime from the PAM broker runtime directory.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.20
- Stage the desktop PulseAudio cookie in a private writable runtime directory.
- Restore the Sunshine virtual sink and streamed audio under host hardening.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.19
- Reattach the exact raw-HID Wacom after a graphical-session handoff.
- Keep the host release synchronized with the client reconnect fix.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.18
- Avoid racing per-session encoder probing with active NvFBC capture.
- Prefer fresh Desktop launch after worker replacement with resume fallback.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.17
- Restart the media worker with fresh NvFBC state across X server replacement.
- Retain the machine supervisor, workstation identity, and authenticated handoff.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.16
- Preserve the authenticated stream across GDM-to-user desktop handoff.
- Rebind X11 video and PulseAudio capture without replacing the Sender process.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.15
- Synchronize the host release with the client Wacom permission fix.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.14
- Keep host and client release numbering synchronized for the ZeroTier packet fix.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.13
- Keep host and client release numbering synchronized for native-resolution streaming.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.12
- Keep one root-managed Sunshine UUID across GDM and desktop workers.
- Prevent per-session homes from appearing as duplicate client workstations.
- Run a capability-bounded machine Sender while keeping PAM isolated.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.11
- Generate and validate the DNS SAN required by the client TLS profile.
- Atomically repair invalid host certificates while preserving valid keys.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.10
- Start a root supervisor at boot and run the host as the active seat0 user.
- Support an authenticated GDM Stage A worker without hardcoded UIDs or displays.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.9
- Keep host and client release numbering synchronized for the VA-API dependency fix.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.8
- Keep host and client release numbering synchronized for the client packaging fix.

* Sat Aug 22 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.7
- Keep host and client revisions synchronized for audio phase convergence.

* Fri Aug 21 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.6
- Keep host and client package revisions synchronized for A/V backlog recovery.

* Fri Aug 21 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.5
- Synchronize host release with adaptive client A/V correction

* Fri Aug 21 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.4
- Load UHID and apply tablet device access during package installation

* Fri Aug 21 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.3
- Bind authenticated streams to the matching desktop owner
- Replace the legacy plome PAM helper package

* Fri Aug 21 2026 PLANK Engineering <engineering@instinctual.la> - 0.1.0-0.1
- Initial development package
