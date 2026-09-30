#!/usr/bin/env bash

set -euo pipefail

if (($# > 2)); then
  echo "usage: $0 [BUILD_DIR] [OUTPUT_DIR]" >&2
  exit 2
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=$(realpath -m -- "${1:-${repo_dir}/build/package-host}")
output_dir=$(realpath -m -- "${2:-${build_dir}/packages}")
source "${repo_dir}/scripts/package/package-version.sh"
plank_load_package_version "$repo_dir"
package_version=$PLANK_PACKAGE_VERSION
rpm_version=$PLANK_RPM_VERSION
rpm_release=$PLANK_RPM_RELEASE

if [[ -n $(git -C "$repo_dir" status --porcelain --untracked-files=normal) ]]; then
  echo "refusing to package a dirty PLANK source tree" >&2
  exit 1
fi

for command_name in cmake cpio install python3 readelf rg rpm rpm2cpio rpmbuild tar; do
  command -v "$command_name" >/dev/null || {
    echo "required command is unavailable: ${command_name}" >&2
    exit 1
  }
done

"${repo_dir}/scripts/build/build-host-package-binaries.sh" "$build_dir"

work_dir=$(mktemp -d --tmpdir plank-host-rpm.XXXXXX)
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
payload_dir="${work_dir}/payload"
rpm_topdir="${work_dir}/rpmbuild"
mkdir -p "$payload_dir" "$rpm_topdir/SOURCES" "$rpm_topdir/SPECS" \
  "$rpm_topdir/BUILD" "$rpm_topdir/BUILDROOT" "$rpm_topdir/RPMS" "$rpm_topdir/SRPMS"

install -D -m 0755 "$build_dir/plank-host" \
  "$payload_dir/usr/libexec/plank/plank-host"
install -D -m 0755 "$build_dir/plank-pam-broker" \
  "$payload_dir/usr/libexec/plank/plank-pam-broker"
install -D -m 0755 "$build_dir/plank-host-supervisor" \
  "$payload_dir/usr/libexec/plank/plank-host-supervisor"
install -D -m 0755 "$repo_dir/packaging/host/linux/bin/plank-host" \
  "$payload_dir/usr/bin/plank-host"
install -D -m 0755 "$repo_dir/packaging/host/linux/bin/plank-host-certificate" \
  "$payload_dir/usr/libexec/plank/plank-host-certificate"
install -D -m 0755 "$repo_dir/packaging/host/linux/bin/plank-host-state" \
  "$payload_dir/usr/libexec/plank/plank-host-state"
install -D -m 0755 "$repo_dir/packaging/host/linux/bin/plank-display-prepare" \
  "$payload_dir/usr/libexec/plank/plank-display-prepare"
install -D -m 0644 "$repo_dir/packaging/host/linux/systemd/plank-host.service" \
  "$payload_dir/usr/lib/systemd/system/plank-host.service"
install -D -m 0644 "$repo_dir/packaging/host/linux/systemd/plank-pam-broker.service" \
  "$payload_dir/usr/lib/systemd/system/plank-pam-broker.service"
install -D -m 0644 "$repo_dir/packaging/host/linux/systemd/plank-display-prepare.service" \
  "$payload_dir/usr/lib/systemd/system/plank-display-prepare.service"
install -D -m 0644 "$repo_dir/packaging/host/linux/systemd/90-plank.preset" \
  "$payload_dir/usr/lib/systemd/system-preset/90-plank.preset"
install -D -m 0644 "$repo_dir/packaging/host/linux/pam/plank-host" \
  "$payload_dir/etc/pam.d/plank-host"
install -D -m 0644 "$repo_dir/packaging/host/linux/config/plank-host.conf" \
  "$payload_dir/etc/plank/host.conf"
install -D -m 0644 "$repo_dir/packaging/host/linux/logrotate/plank-host" \
  "$payload_dir/etc/logrotate.d/plank-host"
if rg -n '^\[video\]$|^[[:space:]]*(capture|encoder)[[:space:]]*=' \
  "$payload_dir/etc/plank/host.conf"; then
  echo "host RPM payload still contains global capture or encoder selectors" >&2
  exit 1
fi
echo "host_rpm_global_video_selector_absence_gate=pass"
for required_network_token in \
  'ping_timeout = 10000'; do
  rg -Fq "$required_network_token" \
    "$payload_dir/etc/plank/host.conf" || {
    echo "host RPM payload is missing network configuration: ${required_network_token}" >&2
    exit 1
  }
done
if rg -n 'fec_percentage|fecPercentage' \
  "$payload_dir/etc/plank/host.conf"; then
  echo "host RPM payload contains dormant FEC configuration" >&2
  exit 1
fi
echo "host_rpm_network_config_gate=pass"
rg -Fxq '[x264-encoder]' \
  "$payload_dir/etc/plank/host.conf" || {
  echo "host RPM payload is missing the x264-specific encoder section" >&2
  exit 1
}
if rg -Fxq '[software-encoder]' \
  "$payload_dir/etc/plank/host.conf"; then
  echo "host RPM payload retains the obsolete generic software-encoder section" >&2
  exit 1
fi
echo "host_rpm_x264_config_section_gate=pass"
install -d -m 0700 "$payload_dir/etc/plank/tls"
install -d -m 0750 "$payload_dir/var/lib/plank"
# systemd 252 opens append: output before creating LogsDirectory=. The RPM
# must provide this parent directory before the first service invocation.
install -d -m 0700 "$payload_dir/var/log/plank"
install -D -m 0644 "$repo_dir/packaging/host/linux/udev/70-plank-host-wacom.rules" \
  "$payload_dir/usr/lib/udev/rules.d/70-plank-host-wacom.rules"
install -D -m 0644 "$repo_dir/packaging/host/linux/xorg/90-plank-virtual-wacom.conf" \
  "$payload_dir/usr/share/X11/xorg.conf.d/90-plank-virtual-wacom.conf"
install -D -m 0644 "$repo_dir/packaging/host/linux/modules-load.d/plank.conf" \
  "$payload_dir/usr/lib/modules-load.d/plank.conf"
install -D -m 0644 "$repo_dir/packaging/host/linux/firewalld/plank.xml" \
  "$payload_dir/usr/lib/firewalld/services/plank.xml"
python3 "$repo_dir/packaging/host/linux/display/generate-virtual-edids.py" \
  "$payload_dir/usr/share/plank/display"
install -D -m 0644 "$repo_dir/apps/host/linux/LICENSE" \
  "$payload_dir/usr/share/licenses/plank-host/LICENSE-Sunshine"
install -D -m 0644 "$repo_dir/third_party/kyber-kymux/COPYING.AGPLv3" \
  "$payload_dir/usr/share/licenses/plank-host/LICENSE-Kyber-AGPLv3"
install -D -m 0644 "$repo_dir/third_party/kyber-kymux/COPYING.md" \
  "$payload_dir/usr/share/licenses/plank-host/LICENSE-Kyber-Notice"
install -D -m 0644 "$repo_dir/packaging/README.md" \
  "$payload_dir/usr/share/doc/plank-host/README.md"
mkdir -p "$payload_dir/usr/share/plank"
cp -aL "$build_dir/assets/." "$payload_dir/usr/share/plank/"

source_epoch=$(git -C "$repo_dir" log -1 --format=%ct)
tar --sort=name --mtime="@${source_epoch}" --owner=0 --group=0 \
  --numeric-owner -C "$work_dir" -czf \
  "$rpm_topdir/SOURCES/plank-host-payload.tar.gz" payload
install -m 0644 "$repo_dir/packaging/host/linux/rpm/plank-host.spec" \
  "$rpm_topdir/SPECS/plank-host.spec"
rpmbuild -bb --define "_topdir ${rpm_topdir}" \
  --define "plank_version ${rpm_version}" \
  --define "plank_release ${rpm_release}" \
  "$rpm_topdir/SPECS/plank-host.spec"

mkdir -p "$output_dir"
find "$rpm_topdir/RPMS" -type f -name '*.rpm' -exec install -m 0644 -t "$output_dir" {} +
rpm_file=$(find "$output_dir" -maxdepth 1 -type f \
  -name "plank-host-${rpm_version}-${rpm_release}*.rpm" | sort | tail -1)
[[ -n $rpm_file ]] || {
  echo "host RPM was not produced for shared version ${package_version}" >&2
  exit 1
}
rpm -qpl "$rpm_file" >/dev/null
rpm -qpR "$rpm_file" | rg -q 'libX11\.so\.6'
rpm -qpl "$rpm_file" | rg -q '/usr/lib/modules-load\.d/plank\.conf$'
rpm -qpl "$rpm_file" | rg -q '/usr/libexec/plank/plank-host-supervisor$'
rpm -qpl "$rpm_file" | rg -q '/usr/libexec/plank/plank-pam-broker$'
if rpm -qpl "$rpm_file" | rg -q \
  '/usr/bin/plank-(host-supervisor|pam-broker)$'; then
  echo "host RPM exposes internal service binaries in /usr/bin" >&2
  exit 1
fi
echo "host_rpm_private_service_binary_gate=pass"
rpm -qpl "$rpm_file" | rg -q '/usr/libexec/plank/plank-host-certificate$'
rpm -qpl "$rpm_file" | rg -q '/usr/libexec/plank/plank-host-state$'
rpm -qpl "$rpm_file" | rg -q \
  '/usr/share/licenses/plank-host/LICENSE-Kyber-AGPLv3$'
rpm -qpl "$rpm_file" | rg -q \
  '/usr/share/licenses/plank-host/LICENSE-Kyber-Notice$'
rpm -qpl "$rpm_file" | rg -q '/usr/libexec/plank/plank-display-prepare$'
rpm -qpl "$rpm_file" | rg -q '/usr/lib/systemd/system/plank-host\.service$'
rpm -qpl "$rpm_file" | rg -q '/usr/lib/systemd/system/plank-display-prepare\.service$'
rpm -qpl "$rpm_file" | rg -q '/etc/plank/host\.conf$'
rpm -qpl "$rpm_file" | rg -q '/etc/logrotate\.d/plank-host$'
rpm -qp --qf '[%{FILENAMES} %{FILEMODES:perms} %{FILEUSERNAME} %{FILEGROUPNAME}\n]' \
  "$rpm_file" | rg -Fxq '/var/log/plank drwx------ root root' || {
  echo "host RPM must own /var/log/plank as a root:root mode 0700 directory" >&2
  exit 1
}
echo "host_rpm_log_directory_gate=pass"
rpm -qpR "$rpm_file" | rg -qx 'logrotate'
if rpm -qpl "$rpm_file" | rg -q '/etc/plank/plank\.conf$'; then
  echo "host RPM still contains the ambiguous generic configuration path" >&2
  exit 1
fi
echo "host_rpm_config_identity_gate=pass"
rpm -qpl "$rpm_file" | rg -q '/etc/pam\.d/plank-host$'
rpm -qpl "$rpm_file" | rg -q \
  '/usr/lib/udev/rules\.d/70-plank-host-wacom\.rules$'
rpm -qpl "$rpm_file" | rg -q \
  '/usr/share/X11/xorg\.conf\.d/90-plank-virtual-wacom\.conf$'
if rpm -qpl "$rpm_file" | rg -q \
  '/usr/lib/udev/rules\.d/70-plank-wacom\.rules$'; then
  echo "host RPM still contains the ambiguously named Wacom udev rule" >&2
  exit 1
fi
echo "host_rpm_wacom_udev_identity_gate=pass"
if rpm -qpl "$rpm_file" | rg -q '/etc/pam\.d/remote-desktop$|/usr/lib/sysusers\.d/plank\.conf$'; then
  echo "host RPM still contains obsolete authentication-group packaging" >&2
  exit 1
fi
if rpm -qpl "$rpm_file" | rg -q \
  '/usr/share/plank/(apps\.json|box\.png|desktop-alt\.png|steam\.png)$'; then
  echo "host RPM still contains the removed application catalog or legacy artwork" >&2
  exit 1
fi
rpm -qpl "$rpm_file" | rg -q '/usr/share/plank/desktop\.png$'
echo "host_rpm_fixed_desktop_gate=pass"
rpm -qpl "$rpm_file" | rg -q '/usr/share/plank/display/virtual-1\.edid$'
rpm -qpl "$rpm_file" | rg -q '/usr/share/plank/display/virtual-2\.edid$'
if [[ $(rpm -qpl "$rpm_file" | rg -c '/usr/share/plank/display/.*\.edid$') -ne 2 ]]; then
  echo "host RPM does not contain exactly two canonical virtual-display EDIDs" >&2
  exit 1
fi
if rpm -qpR "$rpm_file" | rg -qi 'miniupnp|upnp'; then
  echo "host RPM still requires UPnP or miniupnpc" >&2
  exit 1
fi
if rpm -qpl "$rpm_file" | rg -qi 'miniupnp|upnp'; then
  echo "host RPM still contains an UPnP or miniupnpc payload path" >&2
  exit 1
fi
if readelf -d "$build_dir/plank-host" | rg -qi 'miniupnp|upnp'; then
  echo "PLANK host still has an UPnP or miniupnpc ELF dependency" >&2
  exit 1
fi
echo "host_rpm_upnp_absence_gate=pass"
if rpm -qpl "$rpm_file" | rg -q '/virtual-[12]-.+\.edid$'; then
  echo "host RPM still contains preferred-mode-specific virtual EDIDs" >&2
  exit 1
fi
if rpm -qpl "$rpm_file" | rg -q '/etc/plank/host\.env$|/usr/share/plank/web/'; then
  echo "host RPM still contains legacy environment configuration or Web UI assets" >&2
  exit 1
fi
if rpm -qpl "$rpm_file" | rg -q '/usr/lib/systemd/user/plank-host\.service$'; then
  echo "host RPM still contains the obsolete graphical-login user service" >&2
  exit 1
fi
echo "host_rpm=${rpm_file}"
echo "plank_package_version=${package_version}"
echo "host_rpm_manifest_gate=pass"
# RPM's normal debug stripping is part of assembly. Audit the actual finished
# payload, not the unstripped intermediate linked from static dependencies.
mkdir "$work_dir/final-payload"
(
  cd "$work_dir/final-payload"
  rpm2cpio "$rpm_file" | cpio -idm --quiet
)
python3 "$repo_dir/scripts/test/check-package-build-paths.py" "$work_dir/final-payload"
plank_collect_package "$repo_dir" host linux x86_64 rocky-9.7 "$rpm_file"
