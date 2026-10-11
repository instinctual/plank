#!/usr/bin/env bash
set -euo pipefail
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
build_root=${PLANK_QT_SESSION_TEST_BUILD:?Set a dedicated Qt-session test build directory}
qmake=${QMAKE:-qmake6}
mkdir -p "$build_root/tests" "$build_root/probe"
(
    cd "$build_root/tests"
    "$qmake" "$source_root/apps/client/tests/qtsession/qtsession.pro"
    make -j"${PLANK_BUILD_JOBS:-4}"
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./qtsession
)
(
    cd "$build_root/probe"
    "$qmake" "$source_root/probes/qt-session/qt-session.pro"
    make -j"${PLANK_BUILD_JOBS:-4}"
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./plank-qt-session-probe --quit-after 1
)
