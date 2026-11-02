#!/usr/bin/env bash
set -euo pipefail
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
build_root=${PLANK_QT_SESSION_TEST_BUILD:?Set a dedicated Qt-session test build directory}
: "${PLANK_CLIENT_FFMPEG_WORK:?Set the retained private Client FFmpeg work directory}"
ffmpeg_source="$PLANK_CLIENT_FFMPEG_WORK/ffmpeg-9.0.2"
patch="$source_root/apps/client/app/deploy/linux/ffmpeg-patches/0001-hevc-enable-hwaccel-for-identity-gbr.patch"
patch --batch --reverse --no-backup-if-mismatch --dry-run -d "$ffmpeg_source" -p1 < "$patch"
# The release preflight pins the resulting source too: patch-context offsets
# alone are not proof that this is the qualified prepared dependency.
test "$(sha256sum "$ffmpeg_source/libavcodec/hevc/hevcdec.c" | cut -d' ' -f1)" = \
    9803af49884faaf2ed92ab4a1542099db235b5a4da06047be4bfeb885360714a
export PKG_CONFIG_PATH="$PLANK_CLIENT_FFMPEG_WORK/install/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
test "$(pkg-config --variable=prefix libavutil)" = "$PLANK_CLIENT_FFMPEG_WORK/install"
qmake=${QMAKE:-qmake6}
qmake_flags=()
case ${PLANK_QT_SESSION_SANITIZERS:-0} in
    0) ;;
    1) qmake_flags+=(CONFIG+=debug
        'QMAKE_CFLAGS+=-fsanitize=address,undefined -fno-omit-frame-pointer'
        'QMAKE_CXXFLAGS+=-fsanitize=address,undefined -fno-omit-frame-pointer'
        'QMAKE_LFLAGS+=-fsanitize=address,undefined') ;;
    *) echo 'PLANK_QT_SESSION_SANITIZERS must be 0 or 1' >&2; exit 2 ;;
esac
mkdir -p "$build_root"
bash "$source_root/scripts/test/test-code-simplification.sh" "$build_root/simplification"
for variant in production qt; do
    mkdir -p "$build_root/identity-$variant"
    (
        cd "$build_root/identity-$variant"
        identity_config=()
        if [[ $variant == qt ]]; then identity_config+=(CONFIG+=plank-qt-session); fi
        "$qmake" "$source_root/apps/client/tests/clientidentity/clientidentity.pro" "${identity_config[@]}" "${qmake_flags[@]}"
        make -j"${PLANK_BUILD_JOBS:-4}"
        ./clientidentity
    )
done
mkdir -p "$build_root/audio-tests"
(
    cd "$build_root/audio-tests"
    "$qmake" "$source_root/apps/client/tests/pipewireaudio/pipewireaudio.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    timeout 120 ./pipewireaudio
)
bash "$source_root/scripts/test/run-qt-pipewire-test.sh" "$build_root/audio-tests/pipewireaudio"
mkdir -p "$build_root/system-properties-tests"
(
    cd "$build_root/system-properties-tests"
    "$qmake" "$source_root/apps/client/tests/qtsystemproperties/qtsystemproperties.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    QT_QPA_PLATFORM=offscreen ./qtsystemproperties
    QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=1.25 ./qtsystemproperties
)
mkdir -p "$build_root/input-tests"
(
    cd "$build_root/input-tests"
    "$qmake" "$source_root/apps/client/tests/qtinput/qtinput.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    ./qtinput
)
mkdir -p "$build_root/input-runtime-tests"
(
    cd "$build_root/input-runtime-tests"
    "$qmake" "$source_root/apps/client/tests/qtinputruntime/qtinputruntime.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    QT_QPA_PLATFORM=offscreen ./qtinputruntime
)
mkdir -p "$build_root/tests" "$build_root/video-tests" "$build_root/pool-tests" "$build_root/probe"
(
    cd "$build_root/tests"
    "$qmake" "$source_root/apps/client/tests/qtsession/qtsession.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./qtsession
)
(
    cd "$build_root/video-tests"
    "$qmake" "$source_root/apps/client/tests/qtvideo/qtvideo.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    ./qtvideo
)
(
    cd "$build_root/pool-tests"
    "$qmake" "$source_root/apps/client/tests/plvkframepool/plvkframepool.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    timeout 120 ./plvkframepool
)
mkdir -p "$build_root/software-video-tests"
(
    cd "$build_root/software-video-tests"
    "$qmake" "$source_root/apps/client/tests/qtsoftwarevideo/qtsoftwarevideo.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    timeout 120 ./qtsoftwarevideo
)
mkdir -p "$build_root/presenter-tests"
(
    cd "$build_root/presenter-tests"
    "$qmake" "$source_root/apps/client/tests/qtpresenter/qtpresenter.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software timeout 30 ./qtpresenter
)
(
    cd "$build_root/probe"
    "$qmake" "$source_root/probes/qt-session/qt-session.pro" "${qmake_flags[@]}"
    make -j"${PLANK_BUILD_JOBS:-4}"
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./plank-qt-session-probe --quit-after 1
)
