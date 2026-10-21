#!/usr/bin/env bash
# No product installation, credentials, remote desktop, or physical GPU required.
set -euo pipefail
: "${PLANK_SOURCE_ROOT:?}" "${PLANK_DEP_ROOT:?}" "${PLANK_WORK_ROOT:?}"
test "${GITHUB_ACTIONS:-}" = true
source /etc/os-release
test "$ID:$VERSION_ID" = ubuntu:26.04
test "$(qmake6 -query QT_VERSION)" = 6.10.2
# Keep software-only qualification explicit even if a future runner exposes
# a render device. Physical Intel acceptance belongs to a separate live test.
mapfile -t vulkan_test_drivers < <(dpkg -L mesa-vulkan-drivers | grep -E '/lvp_icd(\.x86_64)?\.json$')
test "${#vulkan_test_drivers[@]}" -eq 1
export VK_DRIVER_FILES="${vulkan_test_drivers[0]}" LIBGL_ALWAYS_SOFTWARE=1
export PLANK_CLIENT_FFMPEG_WORK="$PLANK_DEP_ROOT/client-ffmpeg"
export PLANK_CLIENT_SDL_WORK="$PLANK_DEP_ROOT/client-sdl"
export PKG_CONFIG_PATH="$PLANK_CLIENT_FFMPEG_WORK/install/lib/pkgconfig:$PLANK_CLIENT_SDL_WORK/install/lib/pkgconfig"
export LD_LIBRARY_PATH="$PLANK_CLIENT_FFMPEG_WORK/install/lib:$PLANK_CLIENT_SDL_WORK/install/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PLANK_QT_SESSION_TEST_BUILD="$PLANK_WORK_ROOT/qt-session-tests"
reports="$PLANK_WORK_ROOT/qt-session-reports"
mkdir -p "$reports"
cd "$PLANK_SOURCE_ROOT"
{
    git rev-parse HEAD
    git submodule status --recursive
    qmake6 -query QT_VERSION
    echo 'software_gpu_only=true hardware_acceptance=not-performed live_session=not-qualified'
} > "$reports/source.txt"
# Run production-adapter USB recovery before the longer compositor/full-build
# gates. Fake udev/I/O exercises the actual worker without physical devices.
bash scripts/test/test-linux-wacom.sh "$PLANK_SOURCE_ROOT/apps/client" \
    "$PLANK_WORK_ROOT/wacom-tests" 2>&1 | tee "$reports/wacom.log"
PLANK_WACOM_SANITIZERS=1 ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
    bash scripts/test/test-linux-wacom.sh "$PLANK_SOURCE_ROOT/apps/client" \
    "$PLANK_WORK_ROOT/wacom-tests-asan" 2>&1 | tee "$reports/wacom-asan.log"
python3 tests/packaging/test-client-qt-package.py 2>&1 | tee "$reports/package-upgrade.log"
mkdir -p "$reports/offscreen"
PLANK_QT_UI_REPORT_DIR="$reports/offscreen" \
    bash scripts/test/run-qt-session-tests.sh 2>&1 | tee "$reports/components.log"
# Retain the standalone, non-product diagnostic for authorized hardware checks.
# It contains no credentials and does not connect to a Host.
cp "$PLANK_QT_SESSION_TEST_BUILD/probe/plank-qt-session-probe" "$reports/"
PLANK_QT_COMPOSITOR_REPORT="$reports/gnome.log" PLANK_QT_CHECK_PRECISION=1 PLANK_QT_UI_REPORT_DIR="$reports" \
    bash scripts/test/run-qt-session-compositor.sh 2>&1 | tee "$reports/compositor.log"
QT_SCALE_FACTOR=1.25 PLANK_QT_CHECK_PRECISION=1 PLANK_QT_UI_REPORT_DIR="$reports" \
    PLANK_QT_COMPOSITOR_REPORT="$reports/gnome-125.log" \
    bash scripts/test/run-qt-session-compositor.sh 2>&1 | tee "$reports/compositor-125.log"
PLANK_QT_CHECK_SCREEN_SELECTION=1 PLANK_QT_COMPOSITOR_REPORT="$reports/gnome-two-screens.log" \
    bash scripts/test/run-qt-session-compositor.sh 2>&1 | tee "$reports/screen-selection.log"
PLANK_QT_SESSION_TEST_BUILD="$PLANK_WORK_ROOT/qt-session-tests-asan" \
    PLANK_QT_SESSION_SANITIZERS=1 ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
    bash scripts/test/run-qt-session-tests.sh 2>&1 | tee "$reports/sanitizers.log"
# Build the ordinary Ubuntu Client once, with all product preflight checks.
# macOS retains its existing frontend and is compiled in its own hosted job.
export CARGO_HOME="$PLANK_CARGO_ROOT" RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export PATH="$CARGO_HOME/bin:$PATH" CARGO_NET_OFFLINE=true
export PLANK_CLIENT_SDL_WORK="$PLANK_DEP_ROOT/client-sdl"
bash scripts/build/build-client-package-binaries.sh "$PLANK_SOURCE_ROOT/apps/client" \
    "$PLANK_CLIENT_FFMPEG_WORK" "$PLANK_WORK_ROOT/client-build" \
    2>&1 | tee "$reports/client-build.log"
(
    cd "$PLANK_WORK_ROOT/client-build"
    # Qt playback must not quietly fall back to the legacy SDL renderer.
    test -f app/release/pipewire.o || {
        echo 'Missing native playback object: app/release/pipewire.o' >&2
        exit 1
    }
    test ! -f app/release/sdlaud.o || {
        echo 'Unexpected legacy playback object: app/release/sdlaud.o' >&2
        exit 1
    }
    QT_QPA_PLATFORM=offscreen timeout 20 app/plank-client --version
) 2>&1 | tee "$reports/client-runtime.log"
PLANK_QT_CLIENT_BINARY="$PLANK_WORK_ROOT/client-build/app/plank-client" \
    PLANK_QT_LAUNCHER_REPORTS="$reports" \
    PLANK_QT_COMPOSITOR_REPORT="$reports/gnome-launcher.log" \
    bash scripts/test/run-qt-session-compositor.sh 2>&1 | tee "$reports/launcher-smoke.log"
test -z "$(git status --porcelain)"
echo 'Qt/PipeWire, Wacom, package-upgrade and launcher gates passed for the ordinary Ubuntu Client; hardware acceptance remains separate.' >> "$GITHUB_STEP_SUMMARY"
