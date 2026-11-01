#!/usr/bin/env bash
# Headless source-timestamp tests. No audio devices, network or user session.
set -euo pipefail
client=${1:?Client source root}
build=${2:?Test output directory}
common_library=${3:?Exact candidate common-C static library}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$build"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pthread \
    -I"$client/app/streaming" \
    "$client/tests/avsynccontroller/test_audio_timestamps.cpp" \
    "$client/app/streaming/avsynccontroller.cpp" -o "$build/audio-timestamp-observer"
"$build/audio-timestamp-observer"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -pthread \
    -I"$client/app/streaming" \
    "$client/tests/avsynccontroller/test_audio_phase.cpp" \
    "$client/app/streaming/avsynccontroller.cpp" -o "$build/audio-phase-controller"
"$build/audio-phase-controller"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -pthread \
    -I"$client/app/streaming" $(pkg-config --cflags libswresample libavutil) \
    "$client/tests/avsynccontroller/test_audio_phase_resampler.cpp" \
    "$client/app/streaming/avsynccontroller.cpp" \
    $(pkg-config --libs libswresample libavutil) -o "$build/audio-phase-resampler"
if [[ $(uname -s) == Darwin ]]; then
    DYLD_LIBRARY_PATH="$(pkg-config --variable=libdir libswresample)" "$build/audio-phase-resampler"
else
    "$build/audio-phase-resampler"
fi
# Exercise production PCM output demand and a finite queue with independently timed
# arrivals/device pulls; constant-depth phase tests cannot detect starvation.
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -pthread \
    -I"$client/app/streaming" $(pkg-config --cflags libswresample libavutil) \
    "$client/tests/avsynccontroller/test_audio_playback.cpp" \
    "$client/app/streaming/avsynccontroller.cpp" \
    $(pkg-config --libs libswresample libavutil) -o "$build/audio-playback"
if [[ $(uname -s) == Darwin ]]; then
    DYLD_LIBRARY_PATH="$(pkg-config --variable=libdir libswresample)" "$build/audio-playback"
else
    "$build/audio-playback"
fi
# Keep the independent-epoch (Linux Host) rate policy covered too.
mkdir -p "$build/relative-rate"
(
    cd "$build/relative-rate"
    if [[ $(uname -s) == Darwin ]]; then
        # Match the other SDK27/Qt tests, including Qt's ARM intrinsic include.
        qmake "$client/tests/avsynccontroller/avsynccontroller.pro" CONFIG+=release CONFIG-=app_bundle \
            "QMAKE_CXXFLAGS+=-include arm_acle.h" \
            "QMAKE_MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:?}" \
            QMAKE_APPLE_DEVICE_ARCHS=arm64
    else
        qmake6 "$client/tests/avsynccontroller/avsynccontroller.pro" CONFIG+=release
    fi
    make -j2
    ./avsynccontroller
)
libraries=()
if [[ $(uname -s) == Linux ]]; then libraries=(-lcrypto -lpthread -lm); fi
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I"$client/moonlight-common-c/moonlight-common-c/src" \
    -I"$root/protocol/plank-transport/include" \
    "$client/moonlight-common-c/moonlight-common-c/tests/audio-timestamps.c" \
    "$common_library" ${libraries[@]+"${libraries[@]}"} -o "$build/audio-timestamp-callback"
"$build/audio-timestamp-callback"
python3 "$root/tests/audio/test-source-audio-timing.py"
echo 'audio_timestamp_gate=pass live_sync_acceptance=not-performed'
