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
source "$root/scripts/package/package-version.sh"
plank_load_package_version "$root"
env BRANCH=plank-package BUILD_VERSION="$PLANK_PACKAGE_VERSION" \
  COMMIT="$(git -C "$host_source" rev-parse HEAD)" \
  cmake -S "$host_source" -B "$host_build" \
    -DFFMPEG_PREPARED_BINARIES="$ffmpeg_dir" -DBUILD_TESTS=ON
# Coverage-enabled test objects are larger than production objects.
cmake --build "$host_build" --parallel 2 --target test_sunshine
(
  cd "$host_source"
  "$host_build/tests/test_sunshine" --gtest_color=no \
    --gtest_filter='InputConfigDefaults.*:InputRetainedSessionTest.*:RawHidTablet.*:RawHidContactIo.*' \
    --gtest_repeat=25 --gtest_shuffle --gtest_random_seed=837
)
echo 'host_input_lifecycle_gate=pass hardware_acceptance=not-performed'
