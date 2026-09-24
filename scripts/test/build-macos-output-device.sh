#!/bin/bash
# Non-installing output-driver, recovery-journal and local-XPC qualification.
set -euo pipefail
if [[ $# != 2 || $1 != /* || $2 != /* || $(uname -s) != Darwin ||
      $(uname -m) != arm64 || $(sw_vers -productVersion | cut -d . -f 1) -lt 27 ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo 'Usage (authorized macOS27/SDK27 Mac): build-macos-output-device.sh SOURCE NEW_OUTPUT' >&2; exit 2
fi
source_root=$1; output=$2
mkdir "$output"
cd "$source_root"
flags=(-O1 -g -mmacosx-version-min=27.0 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer)
xcrun clang "${flags[@]}" -std=c11 tests/audio/macos-output-driver.c \
    -framework CoreAudio -framework CoreFoundation -o "$output/driver-test"
"$output/driver-test"
xcrun clang "${flags[@]}" -fobjc-arc tests/audio/macos-output-selection.m \
    -framework Foundation -framework CoreAudio -o "$output/selection-test"
"$output/selection-test"
xcrun clang "${flags[@]}" -fobjc-arc tests/audio/macos-output-broker.m \
    apps/host/macos/audio-device/output-selection.m -framework Foundation -framework CoreAudio -o "$output/broker-test"
"$output/broker-test"
for source in output-broker output-route output-selection; do
    xcrun clang -O2 -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
        -c "apps/host/macos/audio-device/$source.m" -o "$output/$source.o"
done
echo 'macos_output_device=pass installed=0'
