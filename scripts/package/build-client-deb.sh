#!/usr/bin/env bash

set -euo pipefail

if (($# < 2 || $# > 4)); then
  echo "usage: $0 MOONLIGHT_BINARY FFMPEG_WORK_DIR [OUTPUT_DIR] [MOONLIGHT_SOURCE_DIR]" >&2
  exit 2
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$repo_dir/scripts/package/client-package-identity.sh"
plank_client_package_identity
moonlight_binary=$(realpath -- "$1")
ffmpeg_work_dir=$(realpath -- "$2")
output_dir=$(realpath -m -- "${3:-${PLANK_WORK_ROOT:-${repo_dir}/build}/package-client-output}")
moonlight_source_dir=$(realpath -- "${4:-${repo_dir}/apps/client}")
plank_client_require_session_runtime "$moonlight_source_dir" --binary "$moonlight_binary"
common_source_dir="${moonlight_source_dir}/moonlight-common-c/moonlight-common-c"
kyber_source_dir="${repo_dir}/third_party/kyber-kymux"
approved_client_logo="${repo_dir}/branding/assets/plank-logo.png"
runtime_client_logo="${moonlight_source_dir}/app/res/plank-logo.png"
ffmpeg_version=9.0.2
ffmpeg_sha256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
ffmpeg_lib_dir="${ffmpeg_work_dir}/install/lib"
if [[ -f ${ffmpeg_work_dir}/COPYING.LGPLv2.1 ]]; then
  ffmpeg_source_dir="$ffmpeg_work_dir"
else
  ffmpeg_source_dir="${ffmpeg_work_dir}/ffmpeg-${ffmpeg_version}"
fi
ffmpeg_archive=""
for archive_candidate in \
  "${ffmpeg_work_dir}/ffmpeg-${ffmpeg_version}.tar.xz" \
  "$(dirname -- "$ffmpeg_work_dir")/ffmpeg-${ffmpeg_version}.tar.xz"; do
  if [[ -f $archive_candidate ]]; then
    ffmpeg_archive=$archive_candidate
    break
  fi
done
source "${repo_dir}/scripts/package/package-version.sh"
plank_load_package_version "$repo_dir"
package_version=$PLANK_PACKAGE_VERSION
desktop_source="$repo_dir/packaging/client/linux/desktop/la.instinctual.Plank.Client.desktop"
appstream_source="$moonlight_source_dir/app/deploy/linux/la.instinctual.Plank.Client.appdata.xml"

for command_name in cmp dpkg-deb dpkg-shlibdeps du git install md5sum realpath rg sha256sum strip tar; do
  command -v "$command_name" >/dev/null || {
    echo "required command is unavailable: ${command_name}" >&2
    exit 1
  }
done

[[ -x ${moonlight_binary} ]] || {
  echo "Moonlight binary is not executable: ${moonlight_binary}" >&2
  exit 1
}
[[ -f ${moonlight_source_dir}/LICENSE ]] || {
  echo "Moonlight source tree is unavailable: ${moonlight_source_dir}" >&2
  exit 1
}
for kyber_license in COPYING.AGPLv3 COPYING.md; do
  [[ -f ${kyber_source_dir}/${kyber_license} ]] || {
    echo "Kyber license file is unavailable: ${kyber_license}" >&2
    exit 1
  }
done
[[ -f ${approved_client_logo} ]] || {
  echo "approved PLANK client logo is unavailable: ${approved_client_logo}" >&2
  exit 1
}
cmp --silent "${approved_client_logo}" "${runtime_client_logo}" || {
  echo "runtime client logo differs from the approved PLANK artwork" >&2
  exit 1
}
echo "client_approved_logo_gate=pass"
if [[ -n $(git -C "$moonlight_source_dir" status --porcelain) ]]; then
  echo "Moonlight source tree is dirty; refusing to create a release package" >&2
  exit 1
fi

for library in \
  libavcodec.so.63 libavutil.so.61 libswresample.so.7; do
  [[ -e ${ffmpeg_lib_dir}/${library} ]] || {
    echo "required FFmpeg ${ffmpeg_version} library is unavailable: ${library}" >&2
    exit 1
  }
done
for license_file in COPYING.LGPLv2.1 COPYING.LGPLv3; do
  [[ -f ${ffmpeg_source_dir}/${license_file} ]] || {
    echo "FFmpeg license file is unavailable: ${ffmpeg_source_dir}/${license_file}" >&2
    exit 1
  }
done
if [[ -n $ffmpeg_archive ]]; then
  printf '%s  %s\n' "$ffmpeg_sha256" "$ffmpeg_archive" | \
    sha256sum --check --status
  echo "ffmpeg_source_archive_gate=pass"
else
  # The prepared Development NUC tree is a retained, Git-ignored build input.
  # Cleanup intentionally does not retain a duplicate release archive. Verify
  # the extracted release identity instead of downloading the same archive for
  # every package build.
  [[ -f ${ffmpeg_source_dir}/VERSION ]] &&
    [[ $(<"${ffmpeg_source_dir}/VERSION") == "$ffmpeg_version" ]] &&
    [[ -f ${ffmpeg_source_dir}/RELEASE ]] &&
    [[ $(<"${ffmpeg_source_dir}/RELEASE") == "$ffmpeg_version" ]] || {
      echo "prepared FFmpeg source identity is not ${ffmpeg_version}" >&2
      exit 1
    }
  echo "ffmpeg_prepared_source_identity_gate=pass"
fi

moonlight_commit=$(git -C "$moonlight_source_dir" rev-parse HEAD)
common_commit=$(git -C "$common_source_dir" rev-parse HEAD)
kyber_commit=$(git -C "$kyber_source_dir" rev-parse HEAD)
source_epoch=$(git -C "$moonlight_source_dir" log -1 --format=%ct)
work_dir=$(mktemp -d --tmpdir plank-client-deb.XXXXXX)
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
stage_dir="${work_dir}/debian/${client_package}"
private_lib_dir="${stage_dir}/usr/lib/${client_lib_name}"
mkdir -p "$stage_dir/DEBIAN" "$private_lib_dir" "$work_dir/debian"

install -D -m 0755 "$moonlight_binary" \
  "$stage_dir/usr/bin/$client_package"
# Static Cargo dependencies may carry assembly DWARF even in a release build.
# Drop debug sections during package assembly; retain symbols and executable code.
strip --strip-debug "$stage_dir/usr/bin/$client_package"
install -D -m 0644 "$repo_dir/packaging/client/config/plank-client.conf" \
  "$stage_dir/etc/plank/$client_config"
install -D -m 0644 "$repo_dir/packaging/client/config/plank-client.conf" \
  "$stage_dir/usr/share/doc/$client_package/client.conf.example"
install -D -m 0755 "$repo_dir/packaging/client/linux/update-policy.py" \
  "$stage_dir/usr/libexec/plank-client-update-policy"
printf '%s\n' "/etc/plank/$client_config" \
  >"$stage_dir/DEBIAN/conffiles"
install -D -m 0644 \
  "$desktop_source" \
  "$stage_dir/usr/share/applications/$client_desktop_id.desktop"
install -D -m 0644 \
  "$appstream_source" \
  "$stage_dir/usr/share/metainfo/$client_desktop_id.appdata.xml"
install -D -m 0644 \
  "$repo_dir/packaging/client/linux/udev/70-plank-client-wacom.rules" \
  "$stage_dir/usr/lib/udev/rules.d/70-$client_package-wacom.rules"
install -m 0755 "$repo_dir/packaging/client/linux/deb/postinst" \
  "$stage_dir/DEBIAN/postinst"
install -m 0755 "$repo_dir/packaging/client/linux/deb/postrm" \
  "$stage_dir/DEBIAN/postrm"
install -D -m 0644 "$moonlight_source_dir/app/res/plank-logo.png" \
  "$stage_dir/usr/share/icons/hicolor/512x512/apps/$client_package.png"
install -D -m 0644 "$moonlight_source_dir/LICENSE" \
  "$stage_dir/usr/share/doc/$client_package/copyright"
install -D -m 0644 "$kyber_source_dir/COPYING.AGPLv3" \
  "$stage_dir/usr/share/doc/$client_package/COPYING.Kyber.AGPLv3"
install -D -m 0644 "$kyber_source_dir/COPYING.md" \
  "$stage_dir/usr/share/doc/$client_package/COPYING.Kyber.md"
install -D -m 0644 "$ffmpeg_source_dir/COPYING.LGPLv2.1" \
  "$stage_dir/usr/share/doc/$client_package/COPYING.FFmpeg.LGPLv2.1"
install -D -m 0644 "$ffmpeg_source_dir/COPYING.LGPLv3" \
  "$stage_dir/usr/share/doc/$client_package/COPYING.FFmpeg.LGPLv3"

for library in libavcodec libavutil libswresample; do
  cp -a "${ffmpeg_lib_dir}/${library}.so."* "$private_lib_dir/"
done
cmp --silent "$moonlight_source_dir/app/res/plank-logo.png" \
  "$stage_dir/usr/share/icons/hicolor/512x512/apps/$client_package.png" || {
  echo "packaged client logo differs from the approved runtime source" >&2
  exit 1
}
version_output=$(
  QT_QPA_PLATFORM=offscreen \
    env -u LD_LIBRARY_PATH \
    "$stage_dir/usr/bin/$client_package" --version 2>&1
)
grep -Fxq "${client_app_name} ${package_version}" <<<"$version_output" || {
  echo "packaged client did not report the expected PLANK version" >&2
  printf '%s\n' "$version_output" >&2
  exit 1
}
echo "client_headless_version_gate=pass"
echo "client_logo_identity_gate=pass"
cat >"$work_dir/debian/control" <<EOF
Source: ${client_package}
Section: net
Priority: optional
Maintainer: PLANK Engineering <engineering@instinctual.la>
Standards-Version: 4.7.0

Package: ${client_package}
Architecture: amd64
Description: PLANK remote workstation client
EOF
cat >"$work_dir/shlibs.local" <<EOF
libavcodec 63 ${client_package}
libavutil 61 ${client_package}
libswresample 7 ${client_package}
EOF

(
  cd "$work_dir"
  mapfile -d '' packaged_elfs < <(
    find "$stage_dir/usr/bin" "$private_lib_dir" \
      -type f -print0 | sort -z
  )
  dpkg-shlibdeps -O -Lshlibs.local -x"$client_package" \
    -l"$private_lib_dir" \
    "${packaged_elfs[@]}"
) >"$work_dir/shlibdeps"
depends=$(sed -n 's/^shlibs:Depends=//p' "$work_dir/shlibdeps")
[[ -n ${depends} ]] || {
  echo "dpkg-shlibdeps did not produce client dependencies" >&2
  exit 1
}

cat >"$stage_dir/usr/share/doc/$client_package/BUILD-INFO" <<EOF
Moonlight-Qt commit: ${moonlight_commit}
moonlight-common-c commit: ${common_commit}
Kyber kymux commit: ${kyber_commit}
FFmpeg version: ${ffmpeg_version}
FFmpeg source SHA-256: ${ffmpeg_sha256}
Session frontend: Qt
Playback backend: PipeWire
Unstripped build binary SHA-256: $(sha256sum "$moonlight_binary" | awk '{print $1}')
Packaged binary SHA-256: $(sha256sum "$stage_dir/usr/bin/$client_package" | awk '{print $1}')
EOF
installed_size=$(du -sk "$stage_dir/usr" | awk '{print $1}')
sed -e "s/@VERSION@/${package_version}/" \
  -e "s/@PACKAGE@/${client_package}/" \
  -e "s/@DISPLAY_NAME@/${client_display_name}/" \
  -e "s/@INSTALLED_SIZE@/${installed_size}/" \
  -e "s/@DEPENDS@/${depends}/" \
  "$repo_dir/packaging/client/linux/deb/control.in" >"$stage_dir/DEBIAN/control"

find "$stage_dir" -type d -exec chmod 0755 {} +
chmod 0644 "$stage_dir/DEBIAN/control" \
  "$stage_dir/usr/share/doc/$client_package/BUILD-INFO"

(
  cd "$stage_dir"
  find usr -type f -print0 | sort -z | xargs -0 md5sum >DEBIAN/md5sums
)
chmod 0644 "$stage_dir/DEBIAN/md5sums"
find "$stage_dir" -exec touch -h -d "@${source_epoch}" {} +
export SOURCE_DATE_EPOCH="$source_epoch"
mkdir -p "$output_dir"
deb_file="${output_dir}/${client_package}_${package_version}_amd64.deb"
python3 "$repo_dir/scripts/test/check-package-build-paths.py" "$stage_dir"
dpkg-deb --root-owner-group --uniform-compression -Zxz --build "$stage_dir" "$deb_file"

dpkg-deb --info "$deb_file" >/dev/null
dpkg-deb --contents "$deb_file" >/dev/null
for required_package in \
  iputils-ping \
  python3 \
  intel-media-va-driver-non-free \
  qml6-module-qtquick \
  qml6-module-qtquick-controls \
  qml6-module-qtquick-layouts \
  qml6-module-qtquick-window \
  qt6-svg-plugins \
  udev; do
  dpkg-deb --field "$deb_file" Depends | grep -Fq "$required_package" || {
    echo "client DEB is missing required dependency: ${required_package}" >&2
    exit 1
  }
done
package_manifest=$(dpkg-deb --contents "$deb_file")
grep -F "./etc/plank/$client_config" <<<"$package_manifest" | \
  grep -Eq '^-rw-r--r-- root/root +[0-9]+ ' || {
  echo "client administrator policy does not have root-owned mode 0644" >&2
  exit 1
}
grep -Fq "./etc/plank/$client_config" \
  <<<"$package_manifest" || {
  echo "client DEB is missing the root-owned administrator policy" >&2
  exit 1
}
client_policy=$(dpkg-deb --fsys-tarfile "$deb_file" | \
  tar -xOf - "./etc/plank/$client_config")
grep -Fxq '[network]' <<<"$client_policy" || {
  echo "client administrator policy is missing its network section" >&2
  exit 1
}
grep -Fxq 'port = 28989' <<<"$client_policy" || {
  echo "client administrator policy does not define the product network port" >&2
  exit 1
}
grep -Fxq '# mdns_discovery = false' <<<"$client_policy" || {
  echo "client administrator policy does not leave mDNS user-configurable by default" >&2
  exit 1
}
control_audit_dir=$(mktemp -d --tmpdir plank-client-control.XXXXXX)
dpkg-deb --control "$deb_file" "$control_audit_dir"
grep -Fxq "/etc/plank/$client_config" \
  "$control_audit_dir/conffiles" || {
  echo "client administrator policy is not registered as a Debian conffile" >&2
  exit 1
}
if grep -Eq \
    '\./(etc/xdg/autostart|usr/lib/systemd/user|usr/share/systemd/user)/.*plank' \
    <<<"$package_manifest"; then
  echo "client DEB contains a PLANK autostart entry or user service" >&2
  exit 1
fi
echo "client_autostart_absence_gate=pass"
grep -Fq "./usr/share/applications/$client_desktop_id.desktop" \
  <<<"$package_manifest" || {
  echo "client DEB is missing the canonical PLANK desktop entry" >&2
  exit 1
}
grep -Fq "./usr/share/metainfo/$client_desktop_id.appdata.xml" \
    <<<"$package_manifest" || {
  echo "client DEB is missing the canonical PLANK AppStream metadata" >&2
  exit 1
}
desktop_entry=$(dpkg-deb --fsys-tarfile "$deb_file" | \
  tar -xOf - "./usr/share/applications/$client_desktop_id.desktop")
grep -Fxq "Name=$client_display_name" <<<"$desktop_entry" || {
  echo "client desktop metadata does not identify PLANK Client" >&2
  exit 1
}
appstream_metadata=$(dpkg-deb --fsys-tarfile "$deb_file" | \
  tar -xOf - "./usr/share/metainfo/$client_desktop_id.appdata.xml")
grep -Fq "<name>$client_display_name</name>" <<<"$appstream_metadata" || {
  echo "client AppStream metadata does not identify PLANK Client" >&2
  exit 1
}
grep -Fq "./usr/share/icons/hicolor/512x512/apps/$client_package.png" \
    <<<"$package_manifest" || {
  echo "client DEB is missing the PLANK application icon" >&2
  exit 1
}
grep -Fq "./usr/bin/$client_package" \
    <<<"$package_manifest" || {
  echo "client DEB is missing the branded PLANK runtime" >&2
  exit 1
}
if grep -Fq './usr/libexec/plank/plank-client' <<<"$package_manifest"; then
  echo "client DEB still contains the obsolete private GUI runtime" >&2
  exit 1
fi
if grep -Fq './usr/libexec/plank/moonlight' <<<"$package_manifest"; then
  echo "client DEB still contains the superseded Moonlight runtime name" >&2
  exit 1
fi
if grep -Fq './usr/share/applications/plank-client.desktop' \
    <<<"$package_manifest"; then
  echo "client DEB still contains the superseded desktop entry" >&2
  exit 1
fi
if grep -Eq \
    '\./usr/share/(applications/la\.instinctual\.PLANK\.desktop|metainfo/la\.instinctual\.PLANK\.appdata\.xml)' \
    <<<"$package_manifest"; then
  echo "client DEB still contains the unsuffixed PLANK application ID" >&2
  exit 1
fi
grep -Fq "./usr/lib/udev/rules.d/70-$client_package-wacom.rules" \
  <<<"$package_manifest" || {
  echo "client DEB is missing the Wacom udev access rule" >&2
  exit 1
}
if grep -Fq "./usr/share/doc/$client_package/COPYING.nanors" \
    <<<"$package_manifest"; then
  echo "client DEB contains a notice for the removed nanors implementation" >&2
  exit 1
fi
for kyber_license in COPYING.Kyber.AGPLv3 COPYING.Kyber.md; do
  grep -Fq "./usr/share/doc/$client_package/${kyber_license}" \
    <<<"$package_manifest" || {
    echo "client DEB is missing the Kyber license file: ${kyber_license}" >&2
    exit 1
  }
done
for maintainer_script in postinst postrm; do
  [[ -x ${control_audit_dir}/${maintainer_script} ]] || {
    echo "client DEB is missing executable ${maintainer_script}" >&2
    exit 1
  }
  sh -n "${control_audit_dir}/${maintainer_script}"
done
if rg -n 'plank-client\.service|deb-systemd-helper|systemctl[[:space:]]+--user' \
    "$control_audit_dir/postinst" "$control_audit_dir/postrm"; then
  echo "client maintainer scripts retain user-service or autostart handling" >&2
  exit 1
fi
rm -rf -- "$control_audit_dir"
"${repo_dir}/scripts/package/audit-package-runtime.sh" \
  "$stage_dir/usr/bin/$client_package" "$private_lib_dir"
packaged_dynamic_section=$(readelf -d "$stage_dir/usr/bin/$client_package")
rg -Fq "\$ORIGIN/../lib/$client_lib_name" <<<"$packaged_dynamic_section" || {
  echo "client runtime does not carry its private relative RUNPATH" >&2
  exit 1
}
unmanaged_loader_output=$(env -u LD_LIBRARY_PATH \
  ldd "$stage_dir/usr/bin/$client_package")
for soname in libavcodec.so.63 libavutil.so.61 libswresample.so.7; do
  unmanaged_path=$(awk -v name="$soname" \
    '$1 == name && $2 == "=>" {print $3}' <<<"$unmanaged_loader_output")
  [[ -n ${unmanaged_path} ]] &&
    [[ $(realpath -- "$unmanaged_path") == \
       $(realpath -- "$private_lib_dir/$soname") ]] || {
      echo "client runtime does not resolve ${soname} through private RUNPATH" >&2
      exit 1
    }
done
echo "client_private_runpath_gate=pass"
dpkg-deb --field "$deb_file" Depends | rg -q 'libqt6core6'
if rg -i 'libSDL' <<<"$unmanaged_loader_output"; then
  echo "client must not link SDL, including indirect dependencies" >&2
  exit 1
fi
echo "client_deb=${deb_file}"
echo "client_deb_manifest_gate=pass"
python3 "$repo_dir/scripts/test/check-client-qt-package.py" "$deb_file"
plank_collect_package "$repo_dir" "$client_product" linux amd64 ubuntu-26.04 "$deb_file"
