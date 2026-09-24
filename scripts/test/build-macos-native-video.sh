#!/bin/bash
# Standalone synthetic hardware-encode/native-QUIC qualification, not a Host.
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 || $1 != /* || $2 != /* || $3 != /* ||
      ( $# == 4 && $4 != --low-latency && $4 != --session-only ) ]]; then
    echo "Usage: $0 /absolute/source /absolute/empty-output /absolute/libplank_transport.a [--low-latency|--session-only]" >&2
    exit 2
fi
source_root=$1
video_build=$2
transport_library=$3
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ||
      $(sw_vers -productVersion | cut -d . -f 1) -lt 27 ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo "Requires the authorized Apple Silicon development Mac, macOS/SDK 27+." >&2
    exit 2
fi
mkdir -p "$video_build"
if [[ -n $(ls -A "$video_build") ]]; then
    echo "Output directory must be empty." >&2
    exit 2
fi
test -f "$transport_library"
if lsof -nP -iUDP:47491 -iUDP:47492 >/dev/null 2>&1; then
    echo "Loopback qualification port 47491 or 47492 is already in use." >&2
    exit 2
fi
export MACOSX_DEPLOYMENT_TARGET=27.0
cd "$source_root"
shasum -a 256 "$transport_library" apps/host/macos/media/native-video.{h,m} \
    apps/host/macos/media/preview-session.{h,m} apps/host/macos/media/screen-capture.{h,m} \
    apps/host/macos/media/native-audio.{h,m} apps/host/macos/media/opus-encoder.{h,m} \
    apps/host/macos/auth/authentication-session.{h,m} tests/auth/macos-native-video.m \
    tests/auth/macos-preview-session.m tests/protocol/macos-preview-launch-v5.json
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/auth -Iapps/host/macos/media -Iprotocol/plank-transport/include \
    apps/host/macos/auth/authentication-session.m apps/host/macos/media/native-video.m \
    tests/auth/macos-native-video.m "$transport_library" \
    -framework Foundation -framework Security -framework SystemConfiguration \
    -framework CoreFoundation -framework CoreMedia -framework CoreVideo \
    -framework VideoToolbox -lpthread -lm -o "$video_build/native-video"
xcrun clang -mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror \
    -Iapps/host/macos/auth -Iapps/host/macos/control -Iapps/host/macos/media -Iapps/host/macos/input -Iapps/host/macos/session -Itests/input -Iprotocol/plank-transport/include \
    apps/host/macos/session/agent-registry.m apps/host/macos/session/agent-connection.m \
    apps/host/macos/auth/authentication-session.m apps/host/macos/control/fixed-capture.m \
    apps/host/macos/media/native-video.m apps/host/macos/media/preview-session.m apps/host/macos/media/clipboard-sync.m \
    apps/host/macos/media/microphone-session.m apps/host/macos/audio-device/microphone-producer.m \
    apps/host/macos/media/screen-capture.m apps/host/macos/media/native-audio.m apps/host/macos/media/opus-encoder.m apps/host/macos/media/audio-tap.m \
    apps/host/macos/input/input-events.m apps/host/macos/input/native-input.m apps/host/macos/input/quartz-input.m \
    tests/auth/macos-preview-session.m tests/input/macos-fake-input.m "$transport_library" \
    -framework Foundation -framework Security -framework SystemConfiguration \
    -framework CoreFoundation -framework CoreMedia -framework CoreGraphics \
    -framework CoreVideo -framework VideoToolbox -framework ScreenCaptureKit -framework AudioToolbox -framework CoreAudio \
    -framework AppKit -framework Carbon -framework ApplicationServices -framework IOKit \
    -Wl,-sectcreate,__CGPreLoginApp,__cgpreloginapp,/dev/null -lpthread -lm -o "$video_build/preview-session"
umask 077
certificate_dir=$(mktemp -d "$video_build/tls.XXXXXX")
trap 'rm -f "$certificate_dir/key.pem" "$certificate_dir/cert.pem" "$certificate_dir/cert.der"; rmdir "$certificate_dir"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config probes/macos/loopback-cert.cnf \
    -keyout "$certificate_dir/key.pem" -out "$certificate_dir/cert.pem" >/dev/null 2>&1
openssl x509 -in "$certificate_dir/cert.pem" -outform DER -out "$certificate_dir/cert.der"
certificate_hash=$(shasum -a 256 "$certificate_dir/cert.der")
certificate_hash=${certificate_hash%% *}
"$video_build/preview-session" "$certificate_dir/cert.pem" "$certificate_dir/key.pem" \
    "$certificate_hash" "$source_root/tests/protocol/macos-preview-launch-v5.json"
if [[ ${4:-} = --session-only ]]; then
    # Fake capture/input and local QUIC only. Do not claim live encoder,
    # screen-recording permission or physical input qualification on a builder.
    exit 0
fi
"$video_build/native-video" "$certificate_dir/cert.pem" "$certificate_dir/key.pem" \
    "$certificate_hash" "$video_build/synthetic-first-frame.hevc"
"$video_build/native-video" "$certificate_dir/cert.pem" "$certificate_dir/key.pem" \
    "$certificate_hash" "$video_build/synthetic-first-frame-4k.hevc" --4k
"$video_build/native-video" "$certificate_dir/cert.pem" "$certificate_dir/key.pem" \
    "$certificate_hash" "$video_build/synthetic-first-frame-full-range.hevc" --full-range
"$video_build/native-video" "$certificate_dir/cert.pem" "$certificate_dir/key.pem" \
    "$certificate_hash" "$video_build/synthetic-first-frame-full-range-4k.hevc" --full-range --4k
if [[ ${4:-} == --low-latency ]]; then
"$video_build/native-video" "$certificate_dir/cert.pem" "$certificate_dir/key.pem" \
    "$certificate_hash" "$video_build/synthetic-low-latency-full-range-4k.hevc" --full-range --4k --low-latency
"$video_build/native-video" "$certificate_dir/cert.pem" "$certificate_dir/key.pem" \
    "$certificate_hash" "$video_build/synthetic-low-latency-full-range-wide.hevc" --full-range --wide --low-latency
fi
shasum -a 256 "$video_build/native-video" "$video_build/preview-session" "$video_build/synthetic-first-frame.hevc" \
    "$video_build/synthetic-first-frame-4k.hevc"
