#!/usr/bin/env bash
# Portable production-code fixtures; no installed session or hardware claims.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
output=${1:?Usage: test-code-simplification.sh EMPTY_OUTPUT}
mkdir "$output"
output=$(cd "$output" && pwd)
flags=()
if [[ ${PLANK_QT_SESSION_SANITIZERS:-0} == 1 ]]; then
    flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
cc -std=c11 -Wall -Wextra -Werror "${flags[@]}" -I"$root/protocol/plank-transport/include" \
    "$root/tests/protocol/encoding-catalog.c" -o "$output/encoding-catalog-c"
"$output/encoding-catalog-c"
c++ -std=c++17 -Wall -Wextra -Werror "${flags[@]}" -I"$root/protocol/plank-transport/include" -x c++ \
    "$root/tests/protocol/encoding-catalog.c" -o "$output/encoding-catalog-cpp"
"$output/encoding-catalog-cpp"
c++ -std=c++17 -Wall -Wextra -Werror "${flags[@]}" -I"$root/apps/client/app/streaming" \
    "$root/tests/session/session-lifecycle.cpp" -pthread -o "$output/session-lifecycle"
"$output/session-lifecycle"
cc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter "${flags[@]}" \
    -ffunction-sections -fdata-sections -I"$root/apps/client/moonlight-common-c/moonlight-common-c/src" \
    "$root/tests/session/native-video-recovery.c" \
    "$root/apps/client/moonlight-common-c/moonlight-common-c/src/Platform.c" \
    "$root/apps/client/moonlight-common-c/moonlight-common-c/src/LinkedBlockingQueue.c" \
    -Wl,--gc-sections -pthread -o "$output/native-video-recovery"
"$output/native-video-recovery"

c++ -std=c++17 -Wall -Wextra -Werror "${flags[@]}" -I"$root/apps/client/app/streaming" \
    "$root/tests/session/decode-pump.cpp" -o "$output/decode-pump"
"$output/decode-pump"
