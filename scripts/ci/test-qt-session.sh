#!/usr/bin/env bash
# No product installation, credentials, remote desktop, or physical GPU required.
set -euo pipefail
: "${PLANK_SOURCE_ROOT:?}" "${PLANK_DEP_ROOT:?}" "${PLANK_WORK_ROOT:?}"
test "${GITHUB_ACTIONS:-}" = true
source /etc/os-release
test "$ID:$VERSION_ID" = ubuntu:26.04
test "$(qmake6 -query QT_VERSION)" = 6.10.2
export PLANK_CLIENT_FFMPEG_WORK="$PLANK_DEP_ROOT/client-ffmpeg"
export PLANK_QT_SESSION_TEST_BUILD="$PLANK_WORK_ROOT/qt-session-tests"
reports="$PLANK_WORK_ROOT/qt-session-reports"
mkdir -p "$reports"
cd "$PLANK_SOURCE_ROOT"
{
    git rev-parse HEAD
    git submodule status --recursive
    qmake6 -query QT_VERSION
    echo 'software_gpu_only=true hardware_acceptance=not-performed live_session=not-implemented'
} > "$reports/source.txt"
python3 tests/packaging/test-client-qt-package.py 2>&1 | tee "$reports/coinstall.log"
bash scripts/test/run-qt-session-tests.sh 2>&1 | tee "$reports/components.log"
PLANK_QT_COMPOSITOR_REPORT="$reports/gnome.log" PLANK_QT_CHECK_PRECISION=1 \
    bash scripts/test/run-qt-session-compositor.sh 2>&1 | tee "$reports/compositor.log"
QT_SCALE_FACTOR=1.25 PLANK_QT_CHECK_PRECISION=1 \
    PLANK_QT_COMPOSITOR_REPORT="$reports/gnome-125.log" \
    bash scripts/test/run-qt-session-compositor.sh 2>&1 | tee "$reports/compositor-125.log"
PLANK_QT_SESSION_TEST_BUILD="$PLANK_WORK_ROOT/qt-session-tests-asan" \
    PLANK_QT_SESSION_SANITIZERS=1 ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
    bash scripts/test/run-qt-session-tests.sh 2>&1 | tee "$reports/sanitizers.log"
# The extracted allocator is also used by the existing SDL renderer. Compile
# and link that complete Client, with all its ordinary preflight tests, to
# guard against regressions outside the isolated experiment. Do not package or
# upload it as a Qt Client: that runtime still has its separate integration gate.
export CARGO_HOME="$PLANK_CARGO_ROOT" RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export PATH="$CARGO_HOME/bin:$PATH" CARGO_NET_OFFLINE=true
export PLANK_CLIENT_SDL_WORK="$PLANK_DEP_ROOT/client-sdl"
PLANK_CLIENT_VARIANT=production \
    bash scripts/build/build-client-package-binaries.sh "$PLANK_SOURCE_ROOT/apps/client" \
    "$PLANK_CLIENT_FFMPEG_WORK" "$PLANK_WORK_ROOT/baseline-client-build" \
    2>&1 | tee "$reports/baseline-client-build.log"
test -z "$(git status --porcelain)"
echo 'Qt isolated component gates passed; no live Client package or hardware acceptance.' >> "$GITHUB_STEP_SUMMARY"
