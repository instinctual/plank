#!/bin/bash
# Non-installing component qualification. Does not record a microphone, select
# an input device, load into coreaudiod, change permissions or restart services.
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
shasum -a 256 apps/host/macos/audio-device/microphone-{buffer.h,driver.c} \
    tests/audio/macos-microphone-{buffer,driver}.c packaging/host/macos/microphone-info.plist \
    probes/macos/microphone-{tone-driver.c,read.m,reader-info.plist} \
    scripts/test/build-macos-microphone-probe.sh
flags=(-std=c11 -O2 -g -mmacosx-version-min=27.0 -Wall -Wextra -Werror
       -Iapps/host/macos/audio-device)
xcrun --sdk macosx clang "${flags[@]}" tests/audio/macos-microphone-buffer.c -o "$output/buffer-test"
"$output/buffer-test"
xcrun --sdk macosx clang "${flags[@]}" tests/audio/macos-microphone-driver.c \
    -framework CoreAudio -framework CoreFoundation -o "$output/driver-test"
"$output/driver-test"
driver="$output/PLANK Microphone.driver"
mkdir -p "$driver/Contents/MacOS"
cp packaging/host/macos/microphone-info.plist "$driver/Contents/Info.plist"
xcrun --sdk macosx clang "${flags[@]}" -fvisibility=hidden -bundle \
    apps/host/macos/audio-device/microphone-driver.c -framework CoreAudio \
    -framework CoreFoundation -o "$driver/Contents/MacOS/plank-microphone"
plutil -lint "$driver/Contents/Info.plist"
# Ad-hoc signature validates component assembly only, not distribution trust.
codesign --force --sign - "$driver"
codesign --verify --strict "$driver"
shasum -a 256 "$driver/Contents/MacOS/plank-microphone"
probe="$output/PLANK Microphone Probe.driver"
mkdir -p "$probe/Contents/MacOS"
cp packaging/host/macos/microphone-info.plist "$probe/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier la.instinctual.PLANK.Microphone.Probe' "$probe/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName PLANK Microphone Probe' "$probe/Contents/Info.plist"
xcrun --sdk macosx clang "${flags[@]}" -fvisibility=hidden -bundle \
    probes/macos/microphone-tone-driver.c -framework CoreAudio -framework CoreFoundation \
    -o "$probe/Contents/MacOS/plank-microphone"
codesign --force --sign - "$probe"
codesign --verify --strict "$probe"
xcrun --sdk macosx clang -O2 -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    probes/macos/microphone-read.m -framework CoreAudio -framework Foundation -framework AppKit -framework AVFoundation \
    -o "$output/microphone-read"
app="$output/PLANK Microphone Probe.app"
mkdir -p "$app/Contents/MacOS"
cp "$output/microphone-read" "$app/Contents/MacOS/"
cp probes/macos/microphone-reader-info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "microphone_component_gate=pass installed=no production_injection=not-implemented"
