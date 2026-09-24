#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 ]]; then
    echo "Usage: $0 ROOT_WORKTREE CLIENT_WORKTREE NEW_OUTPUT" >&2; exit 2
fi
root=$(realpath "$1"); client=$(realpath "$2"); output=$(realpath -m "$3")
mkdir "$output"
cc -std=c11 -O2 -Wall -Wextra -Werror -I"$root/protocol/plank-transport/include" \
    "$root/tests/protocol/camera-control.c" -o "$output/camera-control"
"$output/camera-control"
c++ -std=c++17 -O1 -g -Wall -Wextra -Werror -fPIC -DPLANK_TRANSPORT \
    -fsanitize=address,undefined -fno-omit-frame-pointer -pthread \
    $(pkg-config --cflags Qt6Core) -I"$client/app" -I"$root/protocol/plank-transport/include" \
    "$root/tests/camera/client-camera-session.cpp" "$client/app/streaming/camera/camera.cpp" \
    "$client/app/streaming/camera/linuxnativecamera.cpp" $(pkg-config --libs Qt6Core) \
    -o "$output/camera-session"
"$output/camera-session"
