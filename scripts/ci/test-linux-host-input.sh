#!/usr/bin/env bash
# Exercise production input handling with the fake virtual-HID backend.
# The RPM has already been built with BUILD_TESTS=OFF; it is not repackaged.
set -euo pipefail
host_build=${1:?configured Host build directory required}
root=${PLANK_SOURCE_ROOT:?source worktree required}
host_source="$root/apps/host/linux"
ffmpeg_dir=$(sed -n 's/^FFMPEG_PREPARED_BINARIES:[^=]*=//p' "$host_build/CMakeCache.txt")
test -f "$ffmpeg_dir/include/libavutil/pixfmt.h"
test -f "$ffmpeg_dir/lib/libavcodec.a"
# Both fixtures compile production implementations directly. Avoid rebuilding
# the entire CUDA/media Host merely to execute input and crypto test filters.
fixture_build="$host_build/cmake-build-input-lifecycle"
cxx_compiler=$(sed -n 's/^CMAKE_CXX_COMPILER:[^=]*=//p' "$host_build/CMakeCache.txt")
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
echo 'host_input_lifecycle_gate=pass hardware_acceptance=not-performed'
