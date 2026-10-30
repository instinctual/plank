#!/bin/bash
# Qualification of the native account backend; no installation/listener.
set -euo pipefail
if [[ $# != 2 || $1 != /* || $2 != /* ]]; then
    echo "Usage: $0 /absolute/source-root /absolute/empty-output-directory" >&2
    exit 2
fi
source_root=$1
source "$source_root/scripts/build/macos-host-target.sh"
plank_macos_host_target
auth_output=$2
if [[ $(uname -s) != Darwin ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo "Requires the dedicated development Mac with macOS/SDK 27+." >&2
    exit 2
fi
mkdir -p "$auth_output"
[[ -z $(ls -A "$auth_output") ]] || { echo "Output directory must be empty." >&2; exit 2; }
xcrun clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -std=c11 -Wall -Wextra -Wpedantic -Werror \
    -I"$source_root/apps/host/macos/auth" "$source_root/tests/auth/macos-account-policy.c" \
    -o "$auth_output/account-policy-test"
xcrun clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new \
    -framework Foundation -framework OpenDirectory -framework Security \
    -I"$source_root/apps/host/macos/auth" \
    "$source_root/apps/host/macos/auth/account-verifier.m" \
    "$source_root/apps/host/macos/auth/account-channel.m" \
    "$source_root/apps/host/macos/auth/authentication-session.m" \
    "$source_root/probes/macos/account-verification.m" \
    -o "$auth_output/account-verification"
xcrun clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new \
    -framework Foundation -framework Security \
    -I"$source_root/apps/host/macos/auth" \
    "$source_root/tests/auth/macos-account-channel.m" \
    -o "$auth_output/account-channel-test"
xcrun clang -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wall -Wextra -Werror -Werror=unguarded-availability -Werror=unguarded-availability-new \
    -framework Foundation -framework Security \
    -I"$source_root/apps/host/macos/auth" \
    "$source_root/apps/host/macos/auth/authentication-session.m" \
    "$source_root/tests/auth/macos-authentication-session.m" \
    -o "$auth_output/authentication-session-test"
"$auth_output/account-policy-test"
"$auth_output/account-verification" --self-test
"$auth_output/account-channel-test"
"$auth_output/authentication-session-test"
shasum -a 256 "$auth_output/account-verification" "$auth_output/account-channel-test"
