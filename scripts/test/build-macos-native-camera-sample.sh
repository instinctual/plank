#!/usr/bin/env bash
# Synthetic frames only; no devices, installation, TCC or graphical login.
set -euo pipefail
if [[ $# != 2 || $1 != /* || $2 != /* || $(uname -s) != Darwin ||
      $(uname -m) != arm64 ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo 'Usage (macOS Host/SDK27 development Mac): build-macos-native-camera-sample.sh SOURCE NEW_OUTPUT' >&2
    exit 2
fi
source_root=$1; output=$2
source "$source_root/scripts/build/macos-host-target.sh"
plank_macos_host_target
mkdir "$output"
cd "$source_root"
flags=(-std=c11 -g -O1 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new
    -fsanitize=address,undefined -fno-omit-frame-pointer
    -Iapps/host/macos/media -Iprotocol/plank-transport/include -Iprobes/macos)
xcrun clang "${flags[@]}" tests/camera/native-payload.c -o "$output/native-payload-test"
"$output/native-payload-test"
xcrun clang "${flags[@]}" -fobjc-arc tests/camera/macos-native-sample.m \
    apps/host/macos/media/native-camera-{sample,output}.m probes/macos/native-camera-fixture.m \
    -framework Foundation -framework CoreMedia -framework CoreVideo \
    -framework VideoToolbox -framework CoreGraphics -framework ImageIO \
    -o "$output/native-sample-test"
"$output/native-sample-test"
