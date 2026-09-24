#!/usr/bin/env bash
# Compile production camera IPC/extension; exercise its shared data boundary.
# No installation, device access or extension activation.
set -euo pipefail
if [[ $# != 2 || $1 != /* || $2 != /* || $(uname -s) != Darwin ||
      $(uname -m) != arm64 || $(sw_vers -productVersion | cut -d . -f 1) -lt 27 ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo 'Usage (macOS27/SDK27): build-macos-camera-device.sh SOURCE NEW_OUTPUT' >&2
    exit 2
fi
source_root=$1; output=$2
mkdir "$output"
cd "$source_root"
flags=(-std=c11 -g -O1 -mmacosx-version-min=27.0 -Wall -Wextra -Werror
    -fsanitize=address,undefined -fno-omit-frame-pointer
    -Iapps/host/macos/media -Iapps/host/macos/camera-device -Iprotocol/plank-transport/include)
xcrun clang "${flags[@]}" tests/camera/macos-camera-link.c -o "$output/camera-link-test"
"$output/camera-link-test"
for source in camera-broker camera-producer; do
    xcrun clang "${flags[@]}" -fobjc-arc -c "apps/host/macos/camera-device/$source.m" -o "$output/$source.o"
done
xcrun clang "${flags[@]}" -fobjc-arc apps/host/macos/camera-device/camera-{extension,consumer,signing}.m \
    apps/host/macos/media/native-camera-{sample,output}.m \
    -framework Foundation -framework Security -framework CoreMediaIO -framework CoreMedia \
    -framework CoreVideo -framework VideoToolbox -framework CoreGraphics \
    -o "$output/PLANKCamera"
printf '%s\n' 'Camera shared-memory sanitizers and IPC/extension compilation passed'
