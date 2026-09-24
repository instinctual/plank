#!/bin/bash
# Build and synthetic validation only; never opens devices or requests consent.
set -euo pipefail
if [[ $# != 3 || $1 != /* || $2 != /* || ( $3 != --adhoc && $3 != --sign ) ]]; then
    echo 'Usage: build-macos-installed-media-consumer.sh /source /new/output --adhoc|--sign' >&2; exit 2
fi
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ||
      $(sw_vers -productVersion | cut -d . -f 1) -lt 27 ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo 'Requires the authorized Apple Silicon macOS 27/SDK 27 development Mac.' >&2; exit 2
fi
identity=-
sign_flags=()
if [[ $3 == --sign ]]; then
    if [[ ! ${PLANK_MACOS_SIGNING_IDENTITY:-} =~ ^[A-Fa-f0-9]{40}$ ]]; then
        echo 'Set PLANK_MACOS_SIGNING_IDENTITY to the authorized Developer ID identity SHA-1.' >&2; exit 2
    fi
    identity=$PLANK_MACOS_SIGNING_IDENTITY
    sign_flags=(--timestamp)
fi
source_root=$1
output=$2
mkdir "$output"
cd "$source_root"
shasum -a 256 probes/macos/installed-media-{consumer.m,validation.h} \
    tests/camera/macos-installed-media-validation.m scripts/test/build-macos-installed-media-consumer.sh
flags=(-std=c11 -O2 -g -fobjc-arc -mmacosx-version-min=27.0 -Wall -Wextra -Werror)
frameworks=(-framework Foundation -framework CoreMedia -framework CoreVideo)
xcrun --sdk macosx clang "${flags[@]}" -fsanitize=address,undefined \
    tests/camera/macos-installed-media-validation.m "${frameworks[@]}" -o "$output/validation-test"
"$output/validation-test"
app="$output/PLANK Installed Media Reader.app"
mkdir -p "$app/Contents/MacOS"
python3 - "$app" "$output" <<'PY'
import pathlib, plistlib, sys
app, output = map(pathlib.Path, sys.argv[1:])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier='la.instinctual.PLANK.InstalledMediaReader',
    CFBundleExecutable='installed-media-consumer', CFBundleName='PLANK Installed Media Reader',
    CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0',
    LSMinimumSystemVersion='27.0', LSUIElement=True,
    NSCameraUsageDescription='Check video forwarded through the installed PLANK Camera. No recording is saved.',
    NSMicrophoneUsageDescription='Measure audio levels from the installed PLANK Microphone. No recording is saved.')))
(output/'reader-entitlements.plist').write_bytes(plistlib.dumps({
    'com.apple.security.device.camera': True, 'com.apple.security.device.audio-input': True}))
PY
xcrun --sdk macosx clang "${flags[@]}" probes/macos/installed-media-consumer.m "${frameworks[@]}" \
    -framework AppKit -framework AVFoundation -framework CoreAudio -o "$app/Contents/MacOS/installed-media-consumer"
plutil -lint "$app/Contents/Info.plist" "$output/reader-entitlements.plist"
codesign --force --sign "$identity" --options runtime "${sign_flags[@]}" \
    --entitlements "$output/reader-entitlements.plist" "$app"
codesign --verify --strict "$app"
echo 'installed_media_reader_build=pass capture_tested=no notarization_tested=no'
