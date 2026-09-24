#!/bin/bash
# Synthetic framework probe only: no devices, installation or privacy requests.
set -euo pipefail
if [[ $# != 2 || $1 != /* || $2 != /* ]]; then
    echo "Usage: $0 /absolute/source /new/output" >&2; exit 2
fi
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ||
      $(sw_vers -productVersion | cut -d . -f 1) -lt 27 ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo "Requires the authorized Apple Silicon macOS 27/SDK 27 development Mac." >&2; exit 2
fi
source_root=$1
output=$2
mkdir "$output"
cd "$source_root"
shasum -a 256 probes/macos/native-camera-formats.m probes/macos/native-camera-fixture.{h,m} \
    probes/macos/native-camera-decode.m \
    apps/host/macos/media/native-camera-{payload.h,sample.h,sample.m} \
    apps/host/macos/media/native-camera-output.{h,m} \
    scripts/test/build-macos-native-camera-formats.sh
xcrun --sdk macosx clang -std=c11 -O2 -g -mmacosx-version-min=27.0 \
    -fobjc-arc -Wall -Wextra -Werror probes/macos/native-camera-formats.m \
    probes/macos/native-camera-fixture.m \
    -framework Foundation -framework CoreMediaIO -framework CoreMedia \
    -framework CoreVideo -framework VideoToolbox -o "$output/native-camera-formats"
"$output/native-camera-formats"
# Build the private-capture reader without embedding or opening any capture.
xcrun --sdk macosx clang -std=c11 -O2 -g -mmacosx-version-min=27.0 \
    -fobjc-arc -Wall -Wextra -Werror -Iprotocol/plank-transport/include \
    probes/macos/native-camera-decode.m apps/host/macos/media/native-camera-{sample,output}.m \
    -framework Foundation -framework CoreMedia -framework CoreVideo \
    -framework VideoToolbox -o "$output/native-camera-decode"
