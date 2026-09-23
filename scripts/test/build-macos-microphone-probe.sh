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
    apps/host/macos/audio-device/microphone-{link.h,driver-ipc.h,broker.h,broker.m,producer.h,producer.m,selection.h,selection.m} \
    tests/audio/macos-microphone-{buffer,driver}.c packaging/host/macos/microphone-info.plist \
    probes/macos/microphone-{tone-driver.c,read.m,reader-info.plist} \
    probes/macos/microphone-xpc-{driver.c,source.c,shared.h} \
    probes/macos/microphone-managed{.m,-config.h} \
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
xpc_probe="$output/PLANK Microphone XPC Probe.driver"
mkdir -p "$xpc_probe/Contents/MacOS"
cp "$probe/Contents/Info.plist" "$xpc_probe/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :AudioServerPlugIn_MachServices array' "$xpc_probe/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :AudioServerPlugIn_MachServices:0 string la.instinctual.PLANK.Microphone.probe' "$xpc_probe/Contents/Info.plist"
xcrun --sdk macosx clang "${flags[@]}" -fblocks -fvisibility=hidden -bundle \
    probes/macos/microphone-xpc-driver.c -framework CoreAudio -framework CoreFoundation \
    -o "$xpc_probe/Contents/MacOS/plank-microphone"
codesign --force --sign - "$xpc_probe"
codesign --verify --strict "$xpc_probe"
xcrun --sdk macosx clang "${flags[@]}" -fblocks probes/macos/microphone-xpc-source.c \
    -framework CoreFoundation -o "$output/microphone-xpc-source"
managed="$output/PLANK Microphone Managed Probe.driver"
mkdir -p "$managed/Contents/MacOS"
cp "$probe/Contents/Info.plist" "$managed/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :AudioServerPlugIn_MachServices array' "$managed/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :AudioServerPlugIn_MachServices:0 string la.instinctual.PLANK.Microphone.probe-driver' "$managed/Contents/Info.plist"
xcrun --sdk macosx clang "${flags[@]}" -fblocks -fvisibility=hidden -bundle \
    -include probes/macos/microphone-managed-config.h apps/host/macos/audio-device/microphone-driver.c \
    -framework CoreAudio -framework CoreFoundation -o "$managed/Contents/MacOS/plank-microphone"
codesign --force --sign - "$managed"
codesign --verify --strict "$managed"
xcrun --sdk macosx clang -O2 -g -fobjc-arc -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
    -include probes/macos/microphone-managed-config.h probes/macos/microphone-managed.m \
    apps/host/macos/audio-device/microphone-{broker,producer,selection}.m \
    -framework Foundation -framework Security -framework CoreAudio -o "$output/microphone-managed"
codesign --force --sign - --identifier la.instinctual.PLANK.Microphone.Probe.Managed "$output/microphone-managed"
echo "microphone_component_gate=pass installed=no production_injection=not-implemented"
