#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
output=${1:?Usage: test-native-camera-capture.sh BUILD_DIRECTORY}
mkdir -p "$output"
capture="${PLANK_CLIENT_SOURCE:-$root/apps/client}/app/streaming/camera"
wrappers=()
for name in open fstat close mmap munmap poll ioctl; do wrappers+=("-Wl,--wrap=$name"); done
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -g -fsanitize=address,undefined \
    -fno-omit-frame-pointer -I"$capture" "$root/tests/camera/native-capture.cpp" \
    "$capture/linuxnativecamera.cpp" "${wrappers[@]}" -o "$output/native-camera-capture-test"
"$output/native-camera-capture-test"
