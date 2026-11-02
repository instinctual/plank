#!/usr/bin/env bash
# Pure production-header fixtures; no X server, CUDA device or capture claims.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
output=${1:?Usage: test-linux-native10.sh OUTPUT}
mkdir -p "$output"
header_root="$root/apps/host/linux/third-party/build-deps/third-party/FFmpeg/nv-codec-headers/include"
test -f "$header_root/ffnvcodec/dynlink_cuda.h"
flags=(-std=c++17 -O2 -pthread -Wall -Wextra -Werror -I"$root/apps/host/linux" -I"$header_root")
if [[ ${PLANK_NATIVE10_SANITIZERS:-0} == 1 ]]; then
    flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
for fixture in capture registration; do
    "${CXX:-c++}" "${flags[@]}" "$root/tests/video/native10/$fixture.cpp" -o "$output/$fixture"
    "$output/$fixture"
done
