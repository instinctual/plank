#!/usr/bin/env bash
# Build a diagnostic only, using the same prepared libraries as the Ubuntu Client.
set -euo pipefail
: "${PLANK_SOURCE_ROOT:?}" "${PLANK_DEP_ROOT:?}" "${PLANK_WORK_ROOT:?}"
source /etc/os-release
[[ $ID = ubuntu && $VERSION_ID = 26.04 && $(uname -m) = x86_64 ]]
prefix="$PLANK_DEP_ROOT/client-ffmpeg/install"
output="$PLANK_WORK_ROOT/vaapi-decode-probe"
mkdir -p "$output"
python3 "$PLANK_SOURCE_ROOT/scripts/test/check-client-ffmpeg-identity.py" \
  "$PLANK_DEP_ROOT/client-ffmpeg/ffmpeg-9.0.2/libavcodec/hevc/hevcdec.c"
source "$PLANK_SOURCE_ROOT/scripts/build/build-paths.sh"
plank_build_path_flags "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
[[ $(pkg-config --modversion libavcodec) = 63.1.102 ]]
# These values are compiler switches produced by pkg-config/the path helper.
read -r -a file_flags <<< "$PLANK_C_FILE_FLAGS"
read -r -a dependency_flags <<< "$(pkg-config --cflags --libs libavcodec libavutil libva libdrm egl glesv2)"
g++ -std=c++17 -O2 -Wall -Wextra -Werror -pthread "${file_flags[@]}" \
  "$PLANK_SOURCE_ROOT/probes/video/plank-probe-vaapi-decode.cpp" \
  "${dependency_flags[@]}" -Wl,-rpath-link,"$prefix/lib" -o "$output/plank-probe-vaapi-decode"
read -r -a header_flags <<< "$(pkg-config --cflags libavcodec)"
cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared -pthread "${file_flags[@]}" \
  "${header_flags[@]}" "$PLANK_SOURCE_ROOT/probes/video/plank-probe-video-record.c" \
  -ldl -o "$output/libplank-video-record.so"
LD_LIBRARY_PATH="$prefix/lib" "$output/plank-probe-vaapi-decode" --self-test
LD_LIBRARY_PATH="$prefix/lib" python3 "$PLANK_SOURCE_ROOT/tests/video/test-vaapi-recording.py" \
  "$output/plank-probe-vaapi-decode" "$output/libplank-video-record.so"
LD_LIBRARY_PATH="$prefix/lib" "$output/plank-probe-vaapi-decode" --version > "$output/BUILD-INFO"
git -C "$PLANK_SOURCE_ROOT" rev-parse HEAD >> "$output/BUILD-INFO"
for name in libavcodec.so.63 libavutil.so.61 libswresample.so.7; do
  sha256sum "$prefix/lib/$name" | sed "s|$prefix/lib/||" >> "$output/LIBRARY-SHA256SUMS"
done
(cd "$output" && sha256sum plank-probe-vaapi-decode libplank-video-record.so > SHA256SUMS)
echo 'vaapi_probe_build=pass hardware_test=not-performed'
