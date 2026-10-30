#!/bin/bash
# Synthetic Opus/native-QUIC qualification; no capture, playback or installation.
set -euo pipefail
if [[ $# != 4 || $1 != /* || $2 != /* || $3 != /* || $4 != /* ]]; then
    echo "Usage: $0 /source /empty-output /libplank_transport.a /synthetic-opus.pao" >&2; exit 2
fi
if [[ $(uname -s) != Darwin ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo "Requires an authorized Apple Silicon Mac with SDK27+." >&2; exit 2
fi
source_root=$1
source "$source_root/scripts/build/macos-host-target.sh"
plank_macos_host_target
output=$2
archive=$3
fixture=$4
test -f "$archive"; test -f "$fixture"
if lsof -nP -iUDP:47493 >/dev/null 2>&1; then
    echo "Loopback qualification UDP 47493 is already in use." >&2; exit 2
fi
mkdir "$output"
cd "$source_root"
shasum -a 256 apps/host/macos/media/opus-encoder.{h,m} tests/audio/macos-opus-encoder.m
xcrun --sdk macosx clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new \
    -Iapps/host/macos/media apps/host/macos/media/opus-encoder.m tests/audio/macos-opus-encoder.m \
    -framework Foundation -framework CoreMedia -framework AudioToolbox -o "$output/opus-encoder"
"$output/opus-encoder" "$output/streaming.pao"
shasum -a 256 apps/host/macos/media/native-audio.{h,m} tests/audio/macos-native-audio.m "$archive" "$fixture"
xcrun --sdk macosx clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new \
    -Iapps/host/macos/auth -Iapps/host/macos/media -Iprotocol/plank-transport/include \
    apps/host/macos/auth/authentication-session.m apps/host/macos/media/native-audio.m \
    tests/audio/macos-native-audio.m "$archive" \
    -framework Foundation -framework CoreMedia -framework Security \
    -framework SystemConfiguration -lpthread -lm -o "$output/native-audio"
umask 077
certificate_dir=$(mktemp -d "$output/tls.XXXXXX")
trap 'rm -f "$certificate_dir/key.pem" "$certificate_dir/cert.pem" "$certificate_dir/cert.der"; rmdir "$certificate_dir"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config probes/macos/loopback-cert.cnf \
    -keyout "$certificate_dir/key.pem" -out "$certificate_dir/cert.pem" >/dev/null 2>&1
openssl x509 -in "$certificate_dir/cert.pem" -outform DER -out "$certificate_dir/cert.der"
certificate_hash=$(shasum -a 256 "$certificate_dir/cert.der")
certificate_hash=${certificate_hash%% *}
"$output/native-audio" "$certificate_dir/cert.pem" "$certificate_dir/key.pem" "$certificate_hash" "$fixture"
shasum -a 256 "$output/native-audio" "$output/opus-encoder" "$output/streaming.pao"
