#!/usr/bin/env bash
# Build-only qualification: no devices, network connections, or installation.
set -euo pipefail
if [[ $# != 4 ]]; then
    echo "Usage: $0 ROOT_WORKTREE CLIENT_WORKTREE COMMON_WORKTREE EMPTY_OUTPUT" >&2
    exit 2
fi
root_source=$(realpath "$1")
client_source=$(realpath "$2")
common_source=$(realpath "$3")
output=$(realpath -m "$4")
mkdir "$output"
cc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -DNDEBUG \
    -I"$common_source/src" "$root_source/tests/session/native-optional-services.c" \
    -o "$output/native-optional-services"
"$output/native-optional-services"
cd "$output"
qmake6 "$root_source/tests/protocol/macos-preview-launch.pro" \
    "PLANK_CLIENT_SOURCE=$client_source" "PLANK_COMMON_SOURCE=$common_source"
make -j2
./macos-preview-launch "$root_source/tests/protocol/fixed-capture-v13.json" \
    "$root_source/tests/protocol/macos-preview-launch-v6.json"
