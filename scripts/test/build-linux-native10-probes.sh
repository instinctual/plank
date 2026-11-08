#!/usr/bin/env bash
# Compile GPU qualification tools on the Host builder; never run them there.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
output=${1:?Usage: build-linux-native10-probes.sh OUTPUT}
mkdir -p "$output"
header_root="$root/apps/host/linux/third-party/build-deps/third-party/FFmpeg/nv-codec-headers/include"
test -f "$header_root/ffnvcodec/dynlink_cuda.h"
for fixture in upload pool-upload; do
    "${CXX:-/opt/rh/gcc-toolset-14/root/usr/bin/g++}" -std=c++17 -O2 -pthread \
        -Wall -Wextra -Werror -I"$root/apps/host/linux" -I"$header_root" \
        "$root/tests/video/native10/$fixture.cpp" -ldl -o "$output/$fixture"
done
(
    cd "$output"
    sha256sum upload pool-upload > SHA256SUMS
)
git -C "$root" rev-parse HEAD > "$output/source-root.txt"
git -C "$root/apps/host/linux" rev-parse HEAD > "$output/source-host.txt"
echo 'native10_hardware_probes=compiled hardware_acceptance=not-performed'
