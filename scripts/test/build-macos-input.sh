#!/bin/bash
# Event construction/validation only; never injects input or installs a package.
set -euo pipefail
if [[ $# != 3 || $1 != /* || $2 != /* || $3 != /* ]]; then
    echo "Usage: $0 /absolute/source /absolute/empty-output /libplank_transport.a" >&2; exit 2
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
test -f "$archive"
test -f "$source_root/protocol/plank-transport/include/plank_transport_input.h"
if lsof -nP -iUDP:47494 >/dev/null 2>&1; then
    echo "Loopback qualification UDP 47494 is already in use." >&2; exit 2
fi
mkdir "$output"
cd "$source_root"
xcrun --sdk macosx clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new \
    -Iapps/host/macos/input -Iprotocol/plank-transport/include \
    apps/host/macos/input/input-events.m apps/host/macos/input/quartz-input.m tests/input/macos-user-activity.m \
    -framework Foundation -framework CoreGraphics -framework Carbon -framework AppKit -framework ApplicationServices -framework IOKit \
    -o "$output/user-activity"
"$output/user-activity"
shasum -a 256 apps/host/macos/input/input-events.{h,m} tests/input/macos-input-events.m
xcrun --sdk macosx clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new \
    -Iapps/host/macos/input -Iprotocol/plank-transport/include \
    apps/host/macos/input/input-events.m apps/host/macos/input/quartz-input.m tests/input/macos-input-events.m \
    -framework Foundation -framework CoreGraphics -framework Carbon -framework AppKit -framework ApplicationServices -framework IOKit \
    -Wl,-sectcreate,__CGPreLoginApp,__cgpreloginapp,/dev/null -o "$output/input-events"
"$output/input-events"
xcrun --sdk macosx clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new \
    -Iapps/host/macos/input -Iprotocol/plank-transport/include \
    apps/host/macos/input/input-events.m tests/input/macos-pen-events.m \
    -framework Foundation -framework CoreGraphics -framework Carbon -framework AppKit \
    -o "$output/pen-events"
"$output/pen-events"
shasum -a 256 "$output/input-events"
xcrun --sdk macosx clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new \
    -Iapps/host/macos/input -Iapps/host/macos/auth -Iprotocol/plank-transport/include \
    apps/host/macos/input/input-events.m apps/host/macos/input/native-input.m \
    apps/host/macos/auth/authentication-session.m tests/input/macos-native-input.m "$archive" \
    -framework Foundation -framework CoreGraphics -framework Carbon -framework Security \
    -framework SystemConfiguration -lpthread -lm \
    -Wl,-sectcreate,__CGPreLoginApp,__cgpreloginapp,/dev/null -o "$output/native-input"
umask 077
certificate_dir=$(mktemp -d "$output/tls.XXXXXX")
trap 'rm -f "$certificate_dir/key.pem" "$certificate_dir/cert.pem" "$certificate_dir/cert.der"; rmdir "$certificate_dir"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config probes/macos/loopback-cert.cnf \
    -keyout "$certificate_dir/key.pem" -out "$certificate_dir/cert.pem" >/dev/null 2>&1
openssl x509 -in "$certificate_dir/cert.pem" -outform DER -out "$certificate_dir/cert.der"
certificate_hash=$(shasum -a 256 "$certificate_dir/cert.der")
certificate_hash=${certificate_hash%% *}
"$output/native-input" "$certificate_dir/cert.pem" "$certificate_dir/key.pem" "$certificate_hash"
shasum -a 256 apps/host/macos/input/native-input.{h,m} tests/input/macos-native-input.m "$archive" "$output/native-input"
