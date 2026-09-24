#!/bin/bash
# Signed, loopback-only authenticated capture qualification, not a release.
set -euo pipefail
if [[ ($# != 3 && $# != 4) || $1 != /* || $2 != /* || $3 != /* || (${4:-} != '' && ${4:-} != --synthetic-only) ]]; then
    echo "Usage: $0 /absolute/source /absolute/empty-output /absolute/libplank_transport.a [--synthetic-only]" >&2
    exit 2
fi
source_root=$1
preview_build=$2
archive=$3
if [[ $(uname -s) != Darwin || $(sw_vers -productVersion | cut -d . -f 1) -lt 27 ||
    $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo "Requires dedicated macOS 27/SDK 27 development Mac." >&2; exit 2
fi
if [[ ${4:-} != --synthetic-only ]]; then
    : "${PLANK_MACOS_SIGNING_IDENTITY:?Set the existing Apple Development identity SHA-1}"
    [[ $PLANK_MACOS_SIGNING_IDENTITY =~ ^[[:xdigit:]]{40}$ ]]
fi
mkdir -p "$preview_build"
[[ -z $(ls -A "$preview_build") ]]
cd "$source_root"
common=(-mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror
    -Iapps/host/macos/auth -Iapps/host/macos/control -Iapps/host/macos/media -Iapps/host/macos/input -Iapps/host/macos/session -Itests/input -Iprotocol/plank-transport/include
    -framework Foundation -framework Security -framework SystemConfiguration -framework CoreFoundation
    -framework CoreGraphics -framework AppKit -framework Network -framework CoreMedia
    -framework CoreVideo -framework ScreenCaptureKit -framework VideoToolbox -framework AudioToolbox -framework CoreAudio
    -framework Carbon -framework ApplicationServices -framework IOKit -Wl,-sectcreate,__CGPreLoginApp,__cgpreloginapp,/dev/null)
sources=(apps/host/macos/auth/authentication-session.m apps/host/macos/auth/graphical-authority.m
    apps/host/macos/session/agent-registry.m apps/host/macos/session/agent-connection.m
    apps/host/macos/session/host-runtime.m
    apps/host/macos/control/http-request.m apps/host/macos/control/server-information.m
    apps/host/macos/control/fixed-capture.m apps/host/macos/control/https-auth-server.m
    apps/host/macos/media/native-video.m apps/host/macos/media/preview-session.m apps/host/macos/media/clipboard-sync.m apps/host/macos/media/screen-capture.m
    apps/host/macos/media/camera-session.m apps/host/macos/camera-device/camera-producer.m apps/host/macos/camera-device/camera-signing.m \
    apps/host/macos/media/microphone-session.m apps/host/macos/audio-device/microphone-producer.m
    apps/host/macos/media/native-audio.m apps/host/macos/media/opus-encoder.m apps/host/macos/media/audio-tap.m
    apps/host/macos/input/input-events.m apps/host/macos/input/native-input.m apps/host/macos/input/quartz-input.m
    probes/macos/https-auth.m)
xcrun clang "${common[@]}" -DPLANK_MAC_PREVIEW_TEST -DPLANK_SYNTHETIC_AUTH_TEST \
    "${sources[@]}" tests/input/macos-fake-input.m "$archive" -lpthread -lm -o "$preview_build/preview-synthetic"
xcrun clang "${common[@]}" probes/macos/preview-receive.m "$archive" -lpthread -lm \
    -o "$preview_build/preview-receive"
if [[ ${4:-} = --synthetic-only ]]; then
    # Root is confined to synthetic loopback children and ephemeral identities;
    # no installation, real authentication, display or input is exercised.
    sudo -n "$(command -v python3)" tests/auth/macos-https-handoff.py \
        --server "$preview_build/preview-synthetic" --config probes/macos/https-cert.cnf \
        --uid "$(id -u)" --gid "$(id -g)"
    # Fault injection: the same real server with graceful TCP cancellation
    # restored MUST fail cross-UID rebind specifically with EADDRINUSE.
    # This test-only binary and synthetic TLS identity are never packaged.
    graceful_sources=()
    for source_file in "${sources[@]}"; do
        if [[ $source_file = apps/host/macos/control/https-auth-server.m ]]; then
            graceful_sources+=(tests/auth/macos-https-graceful-close.m)
        else
            graceful_sources+=("$source_file")
        fi
    done
    xcrun clang "${common[@]}" -DPLANK_MAC_PREVIEW_TEST -DPLANK_SYNTHETIC_AUTH_TEST \
        "${graceful_sources[@]}" tests/input/macos-fake-input.m "$archive" -lpthread -lm \
        -o "$preview_build/preview-graceful-close"
    sudo -n "$(command -v python3)" tests/auth/macos-https-handoff.py \
        --server "$preview_build/preview-graceful-close" --config probes/macos/https-cert.cnf \
        --uid "$(id -u)" --gid "$(id -g)" --expect-lingering-close
    python3 tests/auth/macos-https-auth.py --server "$preview_build/preview-synthetic" \
        --config probes/macos/https-cert.cnf --preview-receiver "$preview_build/preview-receive"
    python3 tests/auth/macos-permission-admission.py --server "$preview_build/preview-synthetic"
    exit 0
fi
preview_app="$preview_build/PLANK Host Probe.app"
mkdir -p "$preview_app/Contents/MacOS"
install -m 0644 probes/macos/Info.plist "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 54' "$preview_app/Contents/Info.plist"
xcrun clang "${common[@]}" -DPLANK_MAC_PREVIEW_TEST "${sources[@]}" \
    apps/host/macos/auth/account-verifier.m apps/host/macos/auth/account-channel.m -framework OpenDirectory \
    "$archive" -lpthread -lm -o "$preview_app/Contents/MacOS/plank-host-probe"
codesign --force --sign "$PLANK_MACOS_SIGNING_IDENTITY" --timestamp=none \
    --identifier la.instinctual.PLANK.Host.Probe "$preview_app"
codesign --verify --strict "$preview_app"
shasum -a 256 "$archive" "$preview_app/Contents/MacOS/plank-host-probe" \
    "$preview_build/preview-synthetic" "$preview_build/preview-receive"
