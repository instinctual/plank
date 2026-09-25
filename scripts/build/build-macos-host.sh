#!/bin/bash
# Uninstalled native Host executable; no synthetic verifier or probe main.
set -euo pipefail
if [[ $# != 3 || $1 != /* || $2 != /* || $3 != /* || $(uname -s) != Darwin ||
      $(sw_vers -productVersion | cut -d . -f 1) -lt 27 ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo 'Usage (development Mac): build-macos-host.sh SOURCE EMPTY_OUTPUT TRANSPORT_ARCHIVE' >&2; exit 2
fi
: "${PLANK_MACOS_HOST_VERSION:?Explicit branch-qualified version required}"
[[ $PLANK_MACOS_HOST_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z][a-z0-9.-]*)?$ ]]
source_root=$1; output=$2; archive=$3
source "$source_root/scripts/build/build-paths.sh"
plank_build_path_flags "$source_root" "$output"
mkdir "$output"
cd "$source_root"
bash "$source_root/scripts/test/build-macos-configuration.sh" "$source_root" "$output/configuration-tests"
for component in buffer driver queue; do
    xcrun clang -std=c11 -O2 -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
        -Iapps/host/macos/audio-device "tests/audio/macos-microphone-$component.c" \
        -framework CoreAudio -framework CoreFoundation -o "$output/microphone-$component-test"
    "$output/microphone-$component-test"
done
xcrun clang -std=c11 -O1 -g -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
    -fsanitize=address,undefined -Iapps/host/macos/media -Iapps/host/macos/audio-device \
    tests/audio/reverse-media-clock.c -o "$output/reverse-media-clock-test"
"$output/reverse-media-clock-test"
xcrun clang -std=c11 -O2 -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
    -Iapps/host/macos/media tests/audio/macos-microphone-decoder.c \
    -framework AudioToolbox -o "$output/microphone-decoder-test"
"$output/microphone-decoder-test"
xcrun clang -O2 -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    tests/audio/macos-microphone-selection.m -framework Foundation -framework CoreAudio \
    -o "$output/microphone-selection-test"
"$output/microphone-selection-test"
bash "$source_root/scripts/test/build-macos-output-device.sh" "$source_root" "$output/output-device-tests"
bash "$source_root/scripts/test/build-macos-camera-device.sh" "$source_root" "$output/camera-device-tests"
bash "$source_root/scripts/test/build-macos-native-camera-sample.sh" "$source_root" "$output/camera-sample-tests"
bash "$source_root/scripts/test/build-macos-agent-registry.sh" "$source_root" "$output/agent-registry-tests"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/session tests/auth/macos-machine-identity.m \
    -framework Foundation -framework Security -o "$output/machine-identity-test"
"$output/machine-identity-test"
bash "$source_root/scripts/test/build-macos-display-recovery.sh" "$source_root" "$output/display-recovery-tests"
bash "$source_root/scripts/test/build-macos-input.sh" "$source_root" "$output/input-tests" "$archive"
bash "$source_root/scripts/test/build-macos-preview.sh" "$source_root" "$output/preview-tests" "$archive" --synthetic-only
bash "$source_root/scripts/test/build-macos-native-video.sh" "$source_root" "$output/session-tests" "$archive" --session-only
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/auth apps/host/macos/auth/graphical-authority.m \
    apps/host/macos/auth/authentication-session.m tests/auth/macos-graphical-authority-lifecycle.m \
    -framework Foundation -framework AppKit -framework CoreGraphics -framework Security \
    -framework SystemConfiguration -o "$output/graphical-lifecycle-test"
"$output/graphical-lifecycle-test"
xcrun clang -std=c11 -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
    -Iapps/host/macos/media tests/auth/macos-stream-diagnostics.c -o "$output/stream-diagnostics-test"
"$output/stream-diagnostics-test"
python3 "$source_root/tests/packaging/test-macos-host-permissions.py"
python3 "$source_root/tests/packaging/test-macos-camera-profile.py"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -DPLANK_CLIPBOARD_TEST_PASTEBOARD -Iapps/host/macos/media -Iprotocol/plank-transport/include \
    apps/host/macos/media/clipboard-sync.m tests/input/macos-clipboard.m \
    -framework Foundation -framework AppKit -o "$output/clipboard-test"
"$output/clipboard-test"
xcrun clang -std=c11 -Wall -Wextra -Werror -Iprotocol/plank-transport/include \
    tests/protocol/clipboard-wire.c -o "$output/clipboard-wire-test"
"$output/clipboard-wire-test"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/input -Iprotocol/plank-transport/include \
    apps/host/macos/input/input-events.m tests/input/macos-pen-events.m \
    -framework Foundation -framework CoreGraphics -framework Carbon -framework AppKit -o "$output/pen-events-test"
# CGEventSourceCreate needs access to WindowServer even though this fixture
# never posts events. SSH from a different account cannot obtain that source.
# Only this non-posting fixture uses the console bootstrap; the build/signing
# remain under the build account. Never skip the test or change TCC to run it.
console_uid=$(/usr/bin/stat -f %u /dev/console)
if [[ $console_uid = 0 ]]; then
    echo 'The non-posting graphics fixture needs a logged-in desktop on the development Mac. Log in, then rebuild.' >&2
    exit 1
fi
if [[ $console_uid = "$(id -u)" ]]; then
    "$output/pen-events-test"
else
    echo "Checking non-posting pen fixture in console bootstrap UID $console_uid"
    sudo -n /bin/launchctl asuser "$console_uid" "$output/pen-events-test"
fi
xcrun clang -std=c11 -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
    -Iapps/host/macos/session tests/auth/macos-permission-status.c -o "$output/permission-status-test"
"$output/permission-status-test"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/session tests/auth/macos-desktop-provisioning.m apps/host/macos/session/{desktop-provisioning,host-configuration}.m \
    -framework Foundation -framework Security -o "$output/desktop-provisioning-test"
"$output/desktop-provisioning-test"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/session tests/auth/macos-desktop-start.m apps/host/macos/session/desktop-start.m \
    -framework Foundation -framework SystemConfiguration -o "$output/desktop-start-test"
"$output/desktop-start-test"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/session tests/auth/macos-desktop-start-scheduling.m \
    -framework Foundation -framework SystemConfiguration -o "$output/desktop-start-scheduling-test"
"$output/desktop-start-scheduling-test"
xcrun clang -std=c11 -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
    -Iapps/host/macos/media tests/audio/macos-audio-tap-buffer.c -o "$output/audio-tap-buffer-test"
"$output/audio-tap-buffer-test"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/media tests/audio/macos-audio-tap-lifecycle.m apps/host/macos/media/audio-tap.m \
    -framework Foundation -framework CoreMedia -framework CoreAudio -framework Security -o "$output/audio-tap-lifecycle-test"
"$output/audio-tap-lifecycle-test"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/media tests/audio/macos-output-volume.m \
    -framework Foundation -framework CoreAudio -o "$output/output-volume-test"
"$output/output-volume-test"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/media -Iapps/host/macos/auth -Iapps/host/macos/control -Iapps/host/macos/input -Iprotocol/plank-transport/include \
    tests/audio/macos-audio-recovery.m apps/host/macos/media/screen-capture.m apps/host/macos/audio-device/output-route.m \
    apps/host/macos/media/audio-tap.m apps/host/macos/media/opus-encoder.m apps/host/macos/control/fixed-capture.m \
    -framework Foundation -framework CoreMedia -framework CoreAudio -framework Security \
    -framework CoreGraphics -framework CoreVideo -framework ScreenCaptureKit -framework VideoToolbox -framework AudioToolbox \
    -o "$output/audio-recovery-test"
"$output/audio-recovery-test"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/media tests/audio/macos-opus-encoder.m apps/host/macos/media/opus-encoder.m \
    -framework Foundation -framework CoreMedia -framework AudioToolbox -o "$output/opus-encoder-test"
"$output/opus-encoder-test" "$output/opus-fixture.pao"
xcrun clang -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
    -Iapps/host/macos/media tests/video/macos-frame-timing.c -o "$output/frame-timing-test"
"$output/frame-timing-test"
xcrun clang -mmacosx-version-min=27.0 -Wall -Wextra -Werror \
    -Iapps/host/macos/media tests/video/macos-video-recovery.c -o "$output/video-recovery-test"
"$output/video-recovery-test"
common=("${PLANK_FILE_FLAGS[@]}" -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror
    -Iapps/host/macos/auth -Iapps/host/macos/control -Iapps/host/macos/media -Iapps/host/macos/input
    -Iapps/host/macos/session -Iprotocol/plank-transport/include
    -framework Foundation -framework Security -framework SystemConfiguration -framework CoreFoundation
    -framework CoreGraphics -framework AppKit -framework Network -framework CoreMedia
    -framework CoreVideo -framework ScreenCaptureKit -framework VideoToolbox -framework AudioToolbox -framework CoreAudio
    -framework Carbon -framework ApplicationServices -framework OpenDirectory -framework IOKit -framework SystemExtensions
    -Wl,-sectcreate,__CGPreLoginApp,__cgpreloginapp,/dev/null)
sources=(apps/host/macos/auth/authentication-session.m apps/host/macos/auth/graphical-authority.m
    apps/host/macos/auth/account-verifier.m apps/host/macos/auth/account-channel.m
    apps/host/macos/control/http-request.m apps/host/macos/control/server-information.m
    apps/host/macos/control/fixed-capture.m apps/host/macos/control/desktop-display.m apps/host/macos/control/https-auth-server.m
    apps/host/macos/media/native-video.m apps/host/macos/media/preview-session.m apps/host/macos/media/clipboard-sync.m apps/host/macos/media/screen-capture.m apps/host/macos/audio-device/output-route.m
    apps/host/macos/media/native-audio.m apps/host/macos/media/opus-encoder.m apps/host/macos/media/audio-tap.m
    apps/host/macos/media/camera-session.m apps/host/macos/camera-device/camera-producer.m apps/host/macos/camera-device/camera-signing.m
    apps/host/macos/camera-device/camera-broker.m apps/host/macos/camera-device/camera-activation.m
    apps/host/macos/media/reverse-media-clock.m apps/host/macos/media/microphone-session.m
    apps/host/macos/media/native-camera-sample.m
    apps/host/macos/media/native-camera-output.m
    apps/host/macos/audio-device/microphone-broker.m apps/host/macos/audio-device/microphone-producer.m
    apps/host/macos/audio-device/microphone-selection.m
    apps/host/macos/audio-device/output-broker.m apps/host/macos/audio-device/output-selection.m
    apps/host/macos/input/input-events.m apps/host/macos/input/native-input.m apps/host/macos/input/quartz-input.m
    apps/host/macos/session/agent-registry.m apps/host/macos/session/agent-connection.m
    apps/host/macos/session/desktop-provisioning.m apps/host/macos/session/host-configuration.m apps/host/macos/session/machine-identity.m apps/host/macos/session/desktop-start.m
    apps/host/macos/session/host-runtime.m apps/host/macos/session/host-main.m)
xcrun clang "${common[@]}" "-DPLANK_MACOS_HOST_VERSION=\"$PLANK_MACOS_HOST_VERSION\"" \
    "${sources[@]}" "$archive" -lpthread -lm -o "$output/plank-host"
strip -S "$output/plank-host"
# Ad-hoc is only for uninstalled assembly checks. TCC/live capture needs the
# protected Apple-signed application and is NOT qualified by this build.
codesign --force --sign - --identifier la.instinctual.PLANK.Host "$output/plank-host"
codesign --verify --strict "$output/plank-host"
shasum -a 256 "$archive" "$output/plank-host"
(
    # Distributable resources (including codesign's seal) must be readable by
    # every desktop account, even when the caller protects its workspace at 077.
    # This scope never creates installed configuration, keys or logs.
    umask 022
    # Credential-free CI also assembles a complete ad-hoc test bundle. It is
    # never published as an installer or used for TCC/live capture acceptance.
    signing_identity=${PLANK_MACOS_SIGNING_IDENTITY:--}
    if [[ $signing_identity != - ]]; then
        [[ $signing_identity =~ ^[[:xdigit:]]{40}$ ]]
    else
        [[ ${PLANK_MACOS_DISTRIBUTION:-0} = 0 ]]
    fi
    app="$output/PLANK Host.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$output/plank.iconset"
    xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
        scripts/package/macos-app-icon.m -framework Foundation -framework CoreGraphics \
        -framework ImageIO -o "$output/macos-app-icon"
    "$output/macos-app-icon" "$source_root/branding/assets/plank-logo.png" "$output/plank.iconset"
    iconutil -c icns "$output/plank.iconset" -o "$app/Contents/Resources/plank.icns"
    test -s "$app/Contents/Resources/plank.icns"
    install -m 0755 "$output/plank-host" "$app/Contents/MacOS/plank-host"
    install -m 0644 packaging/host/macos/host-info.plist "$app/Contents/Info.plist"
    xcrun clang "${PLANK_FILE_FLAGS[@]}" -O2 -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
        -Iapps/host/macos/session scripts/package/macos-configure.m apps/host/macos/session/host-configuration.m \
        -framework Foundation -o "$app/Contents/Resources/plank-configure"
    install -m 0644 packaging/host/macos/config/plank-host.conf "$app/Contents/Resources/host.conf.example"
    signing_flags=(--timestamp=none)
    case ${PLANK_MACOS_DISTRIBUTION:-0} in
      0) install -m 0644 scripts/maintenance/install-macos-host-development.py scripts/maintenance/uninstall-macos-host-development.py "$app/Contents/Resources/" ;;
      1)
        signing_flags=(--options runtime --timestamp)
        : "${PLANK_MACOS_TEAM_ID:?Developer Team ID required}"
        [[ $PLANK_MACOS_TEAM_ID =~ ^[A-Z0-9]{10}$ ]]
        sed -e "s/@TEAM@/$PLANK_MACOS_TEAM_ID/g" -e "s/@VERSION@/$PLANK_MACOS_HOST_VERSION/g" \
            packaging/host/macos/pkg-common.sh > "$app/Contents/Resources/uninstall.sh"
        cat packaging/host/macos/uninstall.sh >> "$app/Contents/Resources/uninstall.sh"
        chmod 0755 "$app/Contents/Resources/uninstall.sh"
        bash -n "$app/Contents/Resources/uninstall.sh"
        ;;
      *) echo 'PLANK_MACOS_DISTRIBUTION must be 0 or 1' >&2; exit 2 ;;
    esac
    codesign --force --sign "$signing_identity" "${signing_flags[@]}" "$app/Contents/Resources/plank-configure"
    /usr/libexec/PlistBuddy -c "Add :PLANKVersion string $PLANK_MACOS_HOST_VERSION" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${PLANK_MACOS_HOST_VERSION%%-*}" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${PLANK_MACOS_HOST_VERSION%%-*}" "$app/Contents/Info.plist"
    camera_metadata=(--app "$app" --output "$output" --version "${PLANK_MACOS_HOST_VERSION%%-*}"
        --team "${PLANK_MACOS_TEAM_ID:-PLANKTEST0}" --identity "$signing_identity")
    if [[ $signing_identity != - ]]; then
        : "${PLANK_MACOS_APP_PROVISION_PROFILE:?Production Host system-extension installation profile required}"
        camera_metadata+=(--profile "$PLANK_MACOS_APP_PROVISION_PROFILE")
    fi
    python3 scripts/package/prepare-macos-camera.py "${camera_metadata[@]}"
    extension="$app/Contents/Library/SystemExtensions/la.instinctual.PLANK.Host.Camera.systemextension"
    xcrun clang "${PLANK_FILE_FLAGS[@]}" -O2 -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
        -Iapps/host/macos/media -Iprotocol/plank-transport/include \
        apps/host/macos/camera-device/camera-{extension,consumer,signing}.m \
        apps/host/macos/media/native-camera-{sample,output}.m \
        -framework Foundation -framework Security -framework CoreMediaIO -framework CoreMedia \
        -framework CoreVideo -framework VideoToolbox -framework CoreGraphics \
        -o "$extension/Contents/MacOS/plank-camera"
    strip -S "$extension/Contents/MacOS/plank-camera"
    codesign --force --sign "$signing_identity" "${signing_flags[@]}" \
        --entitlements "$output/camera-extension-entitlements.plist" "$extension"
    codesign --verify --strict "$extension"
    codesign --force --sign "$signing_identity" "${signing_flags[@]}" \
        --entitlements "$output/camera-host-entitlements.plist" --identifier la.instinctual.PLANK.Host "$app"
    codesign --verify --strict "$app"
    driver="$output/PLANK Microphone.driver"
    mkdir -p "$driver/Contents/MacOS"
    install -m 0644 packaging/host/macos/microphone-info.plist "$driver/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${PLANK_MACOS_HOST_VERSION%%-*}" "$driver/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${PLANK_MACOS_HOST_VERSION%%-*}" "$driver/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :AudioServerPlugIn_MachServices array' "$driver/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :AudioServerPlugIn_MachServices:0 string la.instinctual.PLANK.Host.microphone-driver' "$driver/Contents/Info.plist"
    xcrun clang "${PLANK_FILE_FLAGS[@]}" -std=c11 -O2 -mmacosx-version-min=27.0 \
        -Wall -Wextra -Werror -fblocks -fvisibility=hidden -DPLANK_MICROPHONE_IPC -bundle \
        apps/host/macos/audio-device/microphone-driver.c -framework CoreAudio -framework CoreFoundation \
        -o "$driver/Contents/MacOS/plank-microphone"
    strip -S "$driver/Contents/MacOS/plank-microphone"
    codesign --force --sign "$signing_identity" "${signing_flags[@]}" "$driver"
    codesign --verify --strict "$driver"
    driver="$output/PLANK Output.driver"
    mkdir -p "$driver/Contents/MacOS"
    install -m 0644 packaging/host/macos/output-info.plist "$driver/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${PLANK_MACOS_HOST_VERSION%%-*}" "$driver/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${PLANK_MACOS_HOST_VERSION%%-*}" "$driver/Contents/Info.plist"
    xcrun clang "${PLANK_FILE_FLAGS[@]}" -std=c11 -O2 -mmacosx-version-min=27.0 \
        -Wall -Wextra -Werror -fvisibility=hidden -bundle \
        apps/host/macos/audio-device/output-driver.c -framework CoreAudio -framework CoreFoundation \
        -o "$driver/Contents/MacOS/plank-output"
    strip -S "$driver/Contents/MacOS/plank-output"
    codesign --force --sign "$signing_identity" "${signing_flags[@]}" "$driver"
    codesign --verify --strict "$driver"
    python3 "$source_root/scripts/test/check-macos-host-permissions.py" --app "$app"
    shasum -a 256 "$app/Contents/MacOS/plank-host"
)
