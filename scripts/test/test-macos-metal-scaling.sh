#!/usr/bin/env bash
# Production GPU shaders + independent area/color oracles; no GUI or TCC.
set -euo pipefail
[[ $# == 2 && $1 == /* && $2 == /* ]] || {
    echo 'usage: test-macos-metal-scaling.sh SOURCE BUILD' >&2; exit 2;
}
source_root=$1
build=$2
source "$source_root/scripts/build/macos-client-target.sh"
plank_macos_client_target
mkdir -p "$build"
for suite in macos-metal-scaling macos-metal-color; do
    xcrun clang++ -std=c++17 -O2 -fobjc-arc \
        -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -Wall -Wextra -Werror \
        -I"$source_root/apps/client/app/streaming/video/ffmpeg-renderers" \
        "$source_root/tests/video/$suite.mm" -framework Foundation -framework Metal \
        -o "$build/$suite"
done
shader="$source_root/apps/client/app/shaders/vt_renderer.metal"
status=0
"$build/macos-metal-scaling" "$shader" || status=$?
if [[ $status == 77 ]]; then
    echo 'SKIP: no Metal device on builder; native GPU qualification remains required.'
    exit 0
fi
[[ $status == 0 ]] || exit "$status"
"$build/macos-metal-color" "$shader"
