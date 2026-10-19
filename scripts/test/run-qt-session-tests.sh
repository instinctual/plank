#!/usr/bin/env bash
set -euo pipefail
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
build_root=${PLANK_QT_SESSION_TEST_BUILD:?Set a dedicated Qt-session test build directory}
: "${PLANK_CLIENT_FFMPEG_WORK:?Set the retained private Client FFmpeg work directory}"
ffmpeg_source="$PLANK_CLIENT_FFMPEG_WORK/ffmpeg-9.0.1"
patch="$source_root/apps/client/app/deploy/linux/ffmpeg-patches/0001-hevc-enable-hwaccel-for-identity-gbr.patch"
patch --batch --reverse --no-backup-if-mismatch --dry-run -d "$ffmpeg_source" -p1 < "$patch"
# The release preflight pins the resulting source too: patch-context offsets
# alone are not proof that this is the qualified prepared dependency.
test "$(sha256sum "$ffmpeg_source/libavcodec/hevc/hevcdec.c" | cut -d' ' -f1)" = \
    f3e5ce5ab334c0bc39661dccd68dcc91f90c47fcaae72d3c20511088f71387e8
export PKG_CONFIG_PATH="$PLANK_CLIENT_FFMPEG_WORK/install/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
test "$(pkg-config --variable=prefix libavutil)" = "$PLANK_CLIENT_FFMPEG_WORK/install"
qmake=${QMAKE:-qmake6}
mkdir -p "$build_root/tests" "$build_root/video-tests" "$build_root/probe"
(
    cd "$build_root/tests"
    "$qmake" "$source_root/apps/client/tests/qtsession/qtsession.pro"
    make -j"${PLANK_BUILD_JOBS:-4}"
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./qtsession
)
(
    cd "$build_root/video-tests"
    "$qmake" "$source_root/apps/client/tests/qtvideo/qtvideo.pro"
    make -j"${PLANK_BUILD_JOBS:-4}"
    ./qtvideo
)
(
    cd "$build_root/probe"
    "$qmake" "$source_root/probes/qt-session/qt-session.pro"
    make -j"${PLANK_BUILD_JOBS:-4}"
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./plank-qt-session-probe --quit-after 1
)
