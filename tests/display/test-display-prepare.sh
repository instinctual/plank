#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d --tmpdir plank-display-test.XXXXXX)
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

config_file="${work_dir}/plank-host.conf"
output_file="${work_dir}/xorg.conf.d/99-plank-headless.conf"
edid_dir="${work_dir}/display"
fake_bin="${work_dir}/bin"
mkdir -p "$fake_bin"
python3 "$repo_dir/packaging/host/linux/display/generate-virtual-edids.py" "$edid_dir" >/dev/null

[[ $(find "$edid_dir" -maxdepth 1 -type f -name '*.edid' | wc -l) -eq 2 ]]
for index in 1 2; do
  [[ $(wc -c <"${edid_dir}/virtual-${index}.edid") -eq 384 ]]
done
[[ ! -e ${edid_dir}/virtual-1-1920x1080.edid ]]
displayid_headers=$(for block_offset in 128 256; do
  od -An -j "$block_offset" -N 8 -tx1 "${edid_dir}/virtual-1.edid" | tr -d '[:space:]'
done)
[[ $displayid_headers == '70136703010300647013530000030050' ]]
for block_offset in 0 128 256; do
  checksum=$(od -An -j "$block_offset" -N 128 -tu1 "${edid_dir}/virtual-1.edid" |
    awk '{ for (field = 1; field <= NF; ++field) sum += $field } END { print sum % 256 }')
  [[ $checksum -eq 0 ]]
done
[[ $(od -An -j 8 -N 2 -tx1 "${edid_dir}/virtual-1.edid" | tr -d '[:space:]') == '418b' ]]
[[ $(od -An -j 113 -N 13 -tx1 "${edid_dir}/virtual-1.edid" | tr -d '[:space:]') == '446973706c617920310a202020' ]]

run_prepare() {
  PATH="${fake_bin}:${PATH}" \
    "$repo_dir/packaging/host/linux/bin/plank-display-prepare" \
      --config "$config_file" --output "$output_file" --edid-dir "$edid_dir"
}

run_requested_prepare() {
  PATH="${fake_bin}:${PATH}" \
    "$repo_dir/packaging/host/linux/bin/plank-display-prepare" \
      --config "$config_file" --output "$output_file" --edid-dir "$edid_dir" \
      "$@"
}

cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 0755 "${fake_bin}/systemctl"

printf '[display]\nstartup_layout = physical\n' >"$config_file"
run_prepare >/dev/null
[[ ! -e $output_file ]]
if run_requested_prepare --layout single --mode-1 3840x2160 >/dev/null 2>&1; then
  echo "a virtual transition bypassed the physical-display policy" >&2
  exit 1
fi

printf '[display]\nstartup_layout = virtual\n' >"$config_file"
run_prepare >/dev/null
grep -Fq 'Option "ConnectedMonitor" "DFP-0, DFP-2"' "$output_file"
grep -Fq 'DFP-0: 1920x1080 +0+0, DFP-2: NULL' "$output_file"
grep -Fq 'virtual-1.edid' "$output_file"
grep -Fq 'virtual-2.edid' "$output_file"
grep -Fq 'Virtual 8192 2160' "$output_file"
if grep -Fq 'AllowNonEdidModes' "$output_file"; then
  echo "generated Xorg overlay permits a non-EDID mode" >&2
  exit 1
fi

run_requested_prepare --layout single --mode-1 2560x1600 >/dev/null
grep -Fq 'DFP-0: 2560x1600 +0+0, DFP-2: NULL' "$output_file"
grep -Fq 'virtual-1.edid' "$output_file"
grep -Fq 'startup_layout = virtual' "$config_file"

run_requested_prepare --layout single --mode-1 5120x2160 >/dev/null
grep -Fq 'DFP-0: 5120x2160 +0+0, DFP-2: NULL' "$output_file"

if run_requested_prepare --layout dual-horizontal --mode-1 4096x2160 >/dev/null 2>&1; then
  echo "a dual transition without mode 2 was accepted" >&2
  exit 1
fi
run_requested_prepare \
  --layout dual-horizontal --mode-1 4096x2160 --mode-2 1024x2160 >/dev/null
grep -Fq 'DFP-0: 4096x2160 +0+0, DFP-2: 1024x2160 +4096+0' "$output_file"
grep -Fq 'virtual-2.edid' "$output_file"

run_requested_prepare \
  --layout dual-horizontal --mode-1 1920x1200 --mode-2 2560x1440 \
  --primary-output 1 >/dev/null
grep -Fq 'DFP-0: 2560x1440 +1920+0, DFP-2: 1920x1200 +0+0' "$output_file"
for invalid_primary in -1 -2 2 text; do
  if run_requested_prepare --layout dual-horizontal --mode-1 1920x1200 \
      --mode-2 2560x1440 --primary-output "$invalid_primary" >/dev/null 2>&1; then
    echo "an invalid virtual primary output was accepted" >&2
    exit 1
  fi
done
if run_requested_prepare --layout single --mode-1 1920x1200 \
    --primary-output 1 >/dev/null 2>&1; then
  echo "a second primary output was accepted for one display" >&2
  exit 1
fi
if run_requested_prepare --primary-output 0 >/dev/null 2>&1; then
  echo "a virtual primary without a requested layout was accepted" >&2
  exit 1
fi

previous_hash=$(sha256sum "$output_file")
printf '[display]\nstartup_layout = three\n' >"$config_file"
if run_prepare >/dev/null 2>&1; then
  echo "an invalid startup display policy was accepted" >&2
  exit 1
fi
[[ $(sha256sum "$output_file") == "$previous_hash" ]]

printf '[display]\nstartup_layout = virtual\nvirtual_mode_1 = 3840x2160\n' >"$config_file"
if run_prepare >/dev/null 2>&1; then
  echo "a removed administrator virtual-mode option was accepted" >&2
  exit 1
fi
[[ $(sha256sum "$output_file") == "$previous_hash" ]]

printf '[display]\nstartup_layout = virtual\n' >"$config_file"
if run_requested_prepare --layout single --mode-1 1280x720 >/dev/null 2>&1; then
  echo "a removed virtual mode was accepted" >&2
  exit 1
fi

cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${fake_bin}/systemctl"
if run_prepare >/dev/null 2>&1; then
  echo "an active display manager did not block a topology change" >&2
  exit 1
fi
[[ $(sha256sum "$output_file") == "$previous_hash" ]]

cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 0755 "${fake_bin}/systemctl"
printf '[display]\nstartup_layout = physical\n' >"$config_file"
run_prepare >/dev/null
[[ ! -e $output_file ]]

mkdir -p "${output_file%/*}"
printf '# owned by somebody else\n' >"$output_file"
if run_prepare >/dev/null 2>&1; then
  echo "a foreign Xorg configuration was removed" >&2
  exit 1
fi
grep -Fxq '# owned by somebody else' "$output_file"

if "$repo_dir/packaging/host/linux/bin/plank-display-prepare" --cleanup \
    --config "$config_file" --output "$output_file" >/dev/null 2>&1; then
  echo "uninstall cleanup removed a foreign Xorg configuration" >&2
  exit 1
fi
printf '%s\n' '# Generated by PLANK; do not edit.' >"$output_file"
"$repo_dir/packaging/host/linux/bin/plank-display-prepare" --cleanup \
  --config "$config_file" --output "$output_file" >/dev/null
[[ ! -e $output_file ]]

echo "display_prepare_tests=pass"
