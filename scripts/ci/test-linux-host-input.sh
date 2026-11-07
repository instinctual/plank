#!/usr/bin/env bash
# Exercise production input, audio and crypto before the full media/RPM build.
# No GPU or installed product is required; use the same pinned build inputs.
set -euo pipefail
host_build=${1:?Host build output directory required}
root=${PLANK_SOURCE_ROOT:?source worktree required}
host_source="$root/apps/host/linux"
ffmpeg_dir=${PLANK_HOST_FFMPEG_ROOT:?qualified prepared FFmpeg required}
test -f "$ffmpeg_dir/include/libavutil/pixfmt.h"
test -f "$ffmpeg_dir/lib/libavcodec.a"
# Both fixtures compile production implementations directly. Avoid rebuilding
# the entire CUDA/media Host merely to execute input and crypto test filters.
fixture_build="$host_build/cmake-build-input-lifecycle"
cxx_compiler=/opt/rh/gcc-toolset-14/root/usr/bin/g++
test -x "$cxx_compiler"
cmake -S "$root/tests/input/linux-recovery" -B "$fixture_build" \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_COMPILER="$cxx_compiler" \
  -DPLANK_BOOST_SOURCE_DIR="${PLANK_BOOST_SOURCE_DIR:?qualified Boost source required}" \
  -DPLANK_FFMPEG_INCLUDE="$ffmpeg_dir/include"
cmake --build "$fixture_build" --parallel 2
if rg -l --glob '*.o.d' '/usr/(local/)?include/boost/' \
    "$fixture_build/CMakeFiles/input-recovery.dir"; then
  echo 'Host input fixture used system Boost headers instead of the pinned source' >&2
  exit 1
fi
"$fixture_build/input-recovery" --gtest_color=no \
  --gtest_repeat=25 --gtest_shuffle --gtest_random_seed=837
"$fixture_build/host-core-tests" --gtest_color=no \
  --gtest_repeat=25 --gtest_shuffle --gtest_random_seed=837
timeout 20 "$fixture_build/audio-recovery" --gtest_color=no
echo 'host_input_lifecycle_gate=pass hardware_acceptance=not-performed'
