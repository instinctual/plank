#!/usr/bin/env bash

set -euo pipefail

if (($# < 1 || $# > 2)); then
  echo "usage: $0 RUNTIME_STAGE_DIR [WORK_DIR]" >&2
  exit 2
fi

ffmpeg_version=9.0.2
ffmpeg_sha256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
ffmpeg_url="https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz"
runtime_stage_dir=$(realpath -m -- "$1")
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(realpath -m -- "${2:-${repo_dir}/build/client-ffmpeg-${ffmpeg_version}}")
identity_gbr_patch="${repo_dir}/apps/client/app/deploy/linux/ffmpeg-patches/0001-hevc-enable-hwaccel-for-identity-gbr.patch"
identity_gbr_patch_sha256=d8514ed9db3fc2c1aba43cfad0b06f8be3670759bdb173b6fd0a6dc1cffa0bf4
archive="${work_dir}/ffmpeg-${ffmpeg_version}.tar.xz"
source_dir="${work_dir}/ffmpeg-${ffmpeg_version}"
build_dir="${work_dir}/build"
install_dir="${work_dir}/install"
bundle_dir="${runtime_stage_dir}/lib"

for command in curl make nasm patch pkg-config sha256sum tar; do
  if ! command -v "${command}" >/dev/null; then
    echo "Required command is unavailable: ${command}" >&2
    exit 1
  fi
done

mkdir -p "${work_dir}"
if [[ ! -f ${archive} ]]; then
  curl --fail --location --output "${archive}" "${ffmpeg_url}"
fi
printf '%s  %s\n' "${ffmpeg_sha256}" "${archive}" | sha256sum --check --status

if [[ ! -x ${source_dir}/configure ]]; then
  tar -xJf "${archive}" -C "${work_dir}"
fi

[[ -f ${identity_gbr_patch} ]] || {
  echo "Required identity-GBR FFmpeg patch is unavailable: ${identity_gbr_patch}" >&2
  exit 1
}
printf '%s  %s\n' "${identity_gbr_patch_sha256}" "${identity_gbr_patch}" |
  sha256sum --check --status

# FFmpeg maps matrix_coeffs=0 HEVC 4:4:4 streams to GBRP/GBRP10 software
# formats. Their coded layouts are still the ordinary Main 4:4:4 hardware
# profiles, so the private PLANK FFmpeg build must offer VA-API for them. The
# old prepared builder tree carried this patch, but the clean bootstrap did
# not reproduce it until it became an explicit build input here.
if patch --batch --forward --no-backup-if-mismatch --dry-run -d "${source_dir}" -p1 \
    < "${identity_gbr_patch}" >/dev/null 2>&1; then
  patch --batch --forward --no-backup-if-mismatch -d "${source_dir}" -p1 \
    < "${identity_gbr_patch}"
elif patch --batch --reverse --no-backup-if-mismatch --dry-run -d "${source_dir}" -p1 \
    < "${identity_gbr_patch}" >/dev/null 2>&1; then
  echo "Identity-GBR FFmpeg patch is already applied"
else
  echo "Identity-GBR FFmpeg patch does not apply cleanly" >&2
  exit 1
fi
if find "${source_dir}" -type f \( -name '*.orig' -o -name '*.rej' \) \
    -print -quit | grep -q .; then
  echo "Client FFmpeg source contains patch backup or reject files" >&2
  exit 1
fi
echo "client_ffmpeg_identity_gbr_patch_gate=pass"

mkdir -p "${build_dir}" "${install_dir}"
source "$repo_dir/scripts/build/build-paths.sh"
plank_build_path_flags "$source_dir" "$work_dir"

(
  cd -- "${build_dir}"
  "${source_dir}/configure" \
    --prefix="${install_dir}" \
    --disable-doc \
    --disable-debug \
    --disable-static \
    --enable-shared \
    --enable-vaapi \
    --enable-libdrm \
    --extra-cflags="$PLANK_C_FILE_FLAGS"
  python3 "$repo_dir/scripts/build/sanitize-ffmpeg-build-info.py" \
    config.h "$work_dir" "$repo_dir" "$HOME"
  make -j"$(nproc)"
  make install
)

mkdir -p "${bundle_dir}/licenses/ffmpeg"
for library in libavcodec libavutil libswscale libswresample; do
  cp -a "${install_dir}/lib/${library}.so"* "${bundle_dir}/"
done
cp -a "${source_dir}/COPYING.LGPLv2.1" "${source_dir}/COPYING.LGPLv3" \
  "${bundle_dir}/licenses/ffmpeg/"

echo "FFmpeg ${ffmpeg_version} installed in ${install_dir}"
echo "Runtime libraries bundled in ${bundle_dir}"
echo "Build PLANK Client with PKG_CONFIG_PATH=${install_dir}/lib/pkgconfig"
