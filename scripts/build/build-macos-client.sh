#!/usr/bin/env bash
# Build the real Client; dependencies are separately bootstrapped and retained.
set -euo pipefail
[[ $# == 2 && $1 == /* && $2 == /* ]] || { echo 'usage: build-macos-client.sh SOURCE BUILD' >&2; exit 2; }
source_root=$1
build=$2
: "${PLANK_MAC_CLIENT_DEPS:?}"
: "${PLANK_QT_ROOT:?}"
: "${PLANK_RUSTUP_ROOT:?}"
: "${PLANK_CARGO_ROOT:?}"
: "${PLANK_BUILD_BRANCH:?Detached builds require an explicit branch}"
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || exit 2
source "$source_root/scripts/build/macos-client-target.sh"
plank_macos_client_target
export CARGO_HOME="$PLANK_CARGO_ROOT" RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C strip=none" # SDK27 proc-macro guard.
source "$source_root/scripts/build/build-paths.sh"
plank_build_path_flags "$source_root" "$build"
plank_native_dependency_flags
export PATH="$PLANK_QT_ROOT/bin:$PLANK_MAC_CLIENT_DEPS/install/bin:$CARGO_HOME/bin:$PATH"
export PKG_CONFIG_PATH="$PLANK_MAC_CLIENT_DEPS/install/lib/pkgconfig"
# pkgconf itself lives in this prefix; its compiled-in "system" directories
# are private inputs, not compiler defaults, so they must not be filtered out.
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1 PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
source "$source_root/scripts/package/package-version.sh"
plank_load_package_version "$source_root"
version=$PLANK_PACKAGE_VERSION
client="$source_root/apps/client"
test "$(qmake -query QT_VERSION)" = 6.10.2
test "$(rustc --version | awk '{print $2}')" = 1.89.0
python3 "$source_root/tests/packaging/test-macos-client-target.py"
python3 "$source_root/tests/packaging/test-macos-app-icons.py"
python3 "$source_root/tests/packaging/test-macos-fullscreen.py" "$source_root"
mkdir -p "$build/tests"
xcrun clang++ -std=c++17 -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
    -I"$source_root/apps/client/app/streaming" \
    "$source_root/tests/display/macos-client-display-mode.cpp" \
    -framework CoreFoundation -o "$build/tests/client-display-mode-test"
"$build/tests/client-display-mode-test"
python3 "$source_root/tests/packaging/test-macos-quit-lifecycle.py" "$source_root"
python3 "$source_root/tests/packaging/test-macos-metal-overlay.py"
python3 "$source_root/tests/packaging/test-macos-keyboard-capture.py"
python3 "$source_root/tests/packaging/test-startup-permissions.py"
# Test authorization decisions without opening audio devices or requesting TCC.
xcrun clang++ -std=c++17 -fobjc-arc -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -Wall -Wextra -Werror "$source_root/tests/audio/macos-microphone-permission.mm" \
    -framework Foundation -framework AppKit -framework AVFoundation \
    -o "$build/tests/microphone-permission-test"
"$build/tests/microphone-permission-test"
patch_file="$client/app/deploy/linux/ffmpeg-patches/0001-hevc-enable-hwaccel-for-identity-gbr.patch"
printf '%s  %s\n' 059cc9c0d585d71e292cd7421a43f239b1e7ce94e8598d0a7427dfe48e55847e "$patch_file" | shasum -a 256 -c -
patch --batch --reverse --dry-run -d "$PLANK_MAC_CLIENT_DEPS/src/ffmpeg-9.0.1" -p1 < "$patch_file"
pkg-config --modversion sdl3 sdl3-ttf openssl opus libavcodec libavutil
mkdir -p "$build"
python3 "$source_root/scripts/test/check-macos-client-target.py" \
    "$PLANK_MAC_CLIENT_DEPS/install/lib" --target "$PLANK_MAC_CLIENT_MIN_MACOS" \
    > "$build/dependency-targets.json"
cd "$build"
# qmake preserves an existing bundle plist. Regenerate it from the current
# source and deployment target before restoring the visible package version.
rm -f "$build/app/plank-client.app/Contents/Info.plist"
# Recursive generation is mandatory when retaining a build: otherwise existing
# subproject Makefiles may silently retain the previous source/version/flags.
qmake -r "$client/moonlight-qt.pro" CONFIG+=release CONFIG+=disable-prebuilts \
    CONFIG+=plank-transport CONFIG+=disable-libplacebo CONFIG+=disable-wayland \
    CONFIG+=disable-x11 CONFIG+=disable-libva CONFIG+=disable-libdrm \
    PLANK_MAC_CLIENT_MIN_MACOS="$PLANK_MAC_CLIENT_MIN_MACOS" \
    QMAKE_MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" QMAKE_APPLE_DEVICE_ARCHS=arm64 \
    PLANK_VERSION="$version" \
    "QMAKE_CFLAGS+=$PLANK_C_FILE_FLAGS" "QMAKE_CXXFLAGS+=$PLANK_C_FILE_FLAGS"
make -j"${PLANK_BUILD_JOBS:-8}" release
# Run shared topology and toolbar geometry on every Mac Client candidate.
for suite in outputtopology planktoolbarlogic desktopstage macquitshortcut macapplication mackeyboardcapture plankpresentation macrawwacom macclipboardsync macmetaloverlay changelog authenticationtakeover hosttruststore hosttlsguard pacershutdown; do
mkdir -p "$build/tests/$suite"
(
    cd "$build/tests/$suite"
    qmake "$client/tests/$suite/$suite.pro" CONFIG+=release CONFIG-=app_bundle \
        QMAKE_MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" QMAKE_APPLE_DEVICE_ARCHS=arm64 \
        "QMAKE_CXXFLAGS+=-include arm_acle.h"
    make -j"${PLANK_BUILD_JOBS:-8}"
    # These are bare test executables, not deployed app bundles. Give Qt's
    # OpenSSL loader the same pinned libraries the package puts in Frameworks.
    DYLD_LIBRARY_PATH="$PLANK_MAC_CLIENT_DEPS/install/lib" \
        PLANK_REPO_ROOT="$source_root" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software "./$suite"
)
done
# Dummy input only: no microphone permission or physical recording on builders.
mkdir -p "$build/tests/client-microphone"
(
    cd "$build/tests/client-microphone"
    qmake "$source_root/tests/audio/client-microphone.pro" "PLANK_CLIENT_SOURCE=$client" \
        "QMAKE_CXXFLAGS+=-include arm_acle.h" \
        CONFIG+=release QMAKE_MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" QMAKE_APPLE_DEVICE_ARCHS=arm64
    make -j2
    ./client-microphone
)
# Exercise the actual input worker with a queued drag, without a host or UI.
cc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -DNDEBUG \
    -arch arm64 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -I"$client/moonlight-common-c/moonlight-common-c/src" \
    -I"$source_root/protocol/plank-transport/include" \
    "$source_root/tests/session/native-input-wire.c" \
    "$build/moonlight-common-c/libmoonlight-common-c.a" \
    -o "$build/tests/native-input-wire"
"$build/tests/native-input-wire"
cc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -DNDEBUG \
    -arch arm64 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -I"$client/moonlight-common-c/moonlight-common-c/src" \
    -I"$source_root/protocol/plank-transport/include" \
    "$client/moonlight-common-c/moonlight-common-c/tests/native-input-bounds.c" \
    "$build/moonlight-common-c/libmoonlight-common-c.a" \
    -o "$build/tests/native-input-bounds"
"$build/tests/native-input-bounds"
plist="$build/app/plank-client.app/Contents/Info.plist"
# Install the approved Client icon in the base bundle, before any development
# or distribution signing. All packaging paths inherit this exact artwork.
resources="$build/app/plank-client.app/Contents/Resources"
mkdir -p "$resources" "$build/plank.iconset"
xcrun clang -fobjc-arc -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -Wall -Wextra -Werror \
    "$source_root/scripts/package/macos-app-icon.m" -framework Foundation \
    -framework CoreGraphics -framework ImageIO -o "$build/macos-app-icon"
"$build/macos-app-icon" "$source_root/branding/assets/plank-client-macos.png" "$build/plank.iconset"
iconutil -c icns "$build/plank.iconset" -o "$resources/plank.icns"
test -s "$resources/plank.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile plank' "$plist"
# Remove only qmake's inherited icon from this newly rebuilt app bundle.
if [[ -f "$resources/moonlight.icns" ]]; then
    rm "$resources/moonlight.icns"
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :NSPrefersDisplaySafeAreaCompatibilityMode' "$plist")" = false
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PLANK_BASE_VERSION" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PLANK_BASE_VERSION" "$plist"
if /usr/libexec/PlistBuddy -c 'Print :PLANKVersion' "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :PLANKVersion $version" "$plist"
else
    /usr/libexec/PlistBuddy -c "Add :PLANKVersion string $version" "$plist"
fi
python3 "$source_root/scripts/test/check-macos-client-target.py" \
    "$build/app/plank-client.app" --target "$PLANK_MAC_CLIENT_MIN_MACOS" \
    > "$build/client-targets.json"
