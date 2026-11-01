#!/bin/bash
# Native control-plane qualification only; no package or listener installation.
set -euo pipefail
if [[ $# != 2 || $1 != /* || $2 != /* ]]; then
    echo "Usage: $0 /absolute/source-root /absolute/empty-output-directory" >&2
    exit 2
fi
source_root=$1
control_output=$2
bash "$source_root/scripts/test/build-macos-auth.sh" "$source_root" "$control_output"
common=(-mmacosx-version-min=27.0 -O2 -fobjc-arc -Wall -Wextra -Werror
    -I"$source_root/apps/host/macos/auth" -I"$source_root/apps/host/macos/control"
    -framework Foundation -framework Security -framework AppKit -framework CoreGraphics
    -framework SystemConfiguration -framework Network)
xcrun clang "${common[@]}" "$source_root/apps/host/macos/auth/graphical-authority.m" \
    "$source_root/tests/auth/macos-graphical-authority.m" -o "$control_output/graphical-authority-test"
"$control_output/graphical-authority-test" --background
control_sources=("$source_root/apps/host/macos/control/http-request.m"
    "$source_root/apps/host/macos/control/server-information.m"
    "$source_root/apps/host/macos/control/fixed-capture.m"
    "$source_root/apps/host/macos/control/https-auth-server.m"
    "$source_root/apps/host/macos/auth/authentication-session.m"
    "$source_root/apps/host/macos/auth/graphical-authority.m"
    "$source_root/probes/macos/https-auth.m")
xcrun clang "${common[@]}" "$source_root/apps/host/macos/control/http-request.m" \
    "$source_root/tests/auth/macos-http-request.m" -o "$control_output/http-request-test"
xcrun clang "${common[@]}" "$source_root/apps/host/macos/control/server-information.m" \
    "$source_root/tests/auth/macos-server-information.m" -o "$control_output/server-information-test"
xcrun clang "${common[@]}" "$source_root/apps/host/macos/control/fixed-capture.m" \
    "$source_root/tests/auth/macos-fixed-capture.m" -o "$control_output/fixed-capture-test"
xcrun clang "${common[@]}" "$source_root/apps/host/macos/control/fixed-capture.m" \
    "$source_root/tests/auth/macos-fixed-capture-lifecycle.m" -o "$control_output/fixed-capture-lifecycle-test"
xcrun clang "${common[@]}" -DPLANK_SYNTHETIC_AUTH_TEST "${control_sources[@]}" \
    -o "$control_output/https-auth-synthetic"
xcrun clang "${common[@]}" "${control_sources[@]}" -framework OpenDirectory \
    "$source_root/apps/host/macos/auth/account-verifier.m" "$source_root/apps/host/macos/auth/account-channel.m" \
    -o "$control_output/https-auth"
"$control_output/http-request-test"
"$control_output/server-information-test" "$source_root/tests/protocol/macos-server-information.xml"
"$control_output/fixed-capture-test" "$source_root/tests/protocol/fixed-capture-v13.json"
"$control_output/fixed-capture-lifecycle-test"
"$control_output/fixed-capture-lifecycle-test" --registration-failure
"$control_output/https-auth"
shasum -a 256 "$control_output/https-auth" "$control_output/https-auth-synthetic"
