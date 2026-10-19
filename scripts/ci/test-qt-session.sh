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
python3 tests/packaging/test-client-qt-package.py 2>&1 | tee "$reports/coinstall.log"
bash scripts/test/run-qt-session-tests.sh 2>&1 | tee "$reports/components.log"
PLANK_QT_COMPOSITOR_REPORT="$reports/gnome.log" PLANK_QT_CHECK_PRECISION=1 PLANK_QT_UI_REPORT_DIR="$reports" \
    bash scripts/test/run-qt-session-compositor.sh 2>&1 | tee "$reports/compositor.log"
QT_SCALE_FACTOR=1.25 PLANK_QT_CHECK_PRECISION=1 PLANK_QT_UI_REPORT_DIR="$reports" \
    PLANK_QT_COMPOSITOR_REPORT="$reports/gnome-125.log" \
    bash scripts/test/run-qt-session-compositor.sh 2>&1 | tee "$reports/compositor-125.log"
PLANK_QT_SESSION_TEST_BUILD="$PLANK_WORK_ROOT/qt-session-tests-asan" \
    PLANK_QT_SESSION_SANITIZERS=1 ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
    bash scripts/test/run-qt-session-tests.sh 2>&1 | tee "$reports/sanitizers.log"
# The extracted allocator is also used by the existing SDL renderer. Compile
# and link that complete Client, with all its ordinary preflight tests, to
# guard against regressions outside the isolated experiment. Do not package or
# upload it as a Qt Client: only the separately compiled runtime may be packaged.
export CARGO_HOME="$PLANK_CARGO_ROOT" RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export PATH="$CARGO_HOME/bin:$PATH" CARGO_NET_OFFLINE=true
export PLANK_CLIENT_SDL_WORK="$PLANK_DEP_ROOT/client-sdl"
PLANK_CLIENT_VARIANT=production \
    bash scripts/build/build-client-package-binaries.sh "$PLANK_SOURCE_ROOT/apps/client" \
    "$PLANK_CLIENT_FFMPEG_WORK" "$PLANK_WORK_ROOT/baseline-client-build" \
    2>&1 | tee "$reports/baseline-client-build.log"
# Compile the real opt-in runtime as well, before the optional package step.
# This must not remain a collection of unlinked
# component prototypes. Both builds use the same verified dependency inputs.
source scripts/package/package-version.sh
plank_load_package_version "$PLANK_SOURCE_ROOT"
source scripts/build/build-paths.sh
plank_build_path_flags "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/qt-runtime-build"
plank_native_dependency_flags
export PKG_CONFIG_PATH="$PLANK_CLIENT_FFMPEG_WORK/install/lib/pkgconfig:$PLANK_CLIENT_SDL_WORK/install/lib/pkgconfig"
export LD_LIBRARY_PATH="$PLANK_CLIENT_FFMPEG_WORK/install/lib:$PLANK_CLIENT_SDL_WORK/install/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p "$PLANK_WORK_ROOT/qt-runtime-build"
(
    cd "$PLANK_WORK_ROOT/qt-runtime-build"
    qmake6 "$PLANK_SOURCE_ROOT/apps/client" CONFIG+=release CONFIG+=plank-transport CONFIG+=plank-qt-session \
        "PLANK_TRANSPORT_DIR=$PLANK_SOURCE_ROOT/protocol/plank-transport" "PLANK_VERSION=$PLANK_PACKAGE_VERSION" \
        "QMAKE_CFLAGS+=$PLANK_C_FILE_FLAGS" "QMAKE_CXXFLAGS+=$PLANK_C_FILE_FLAGS"
    make -j"$(nproc)"
    QT_QPA_PLATFORM=offscreen timeout 20 app/plank-client-qt --version
) 2>&1 | tee "$reports/qt-runtime-build.log"
PLANK_QT_CLIENT_BINARY="$PLANK_WORK_ROOT/qt-runtime-build/app/plank-client-qt" \
    PLANK_QT_LAUNCHER_REPORTS="$reports" \
    PLANK_QT_COMPOSITOR_REPORT="$reports/gnome-launcher.log" \
    bash scripts/test/run-qt-session-compositor.sh 2>&1 | tee "$reports/launcher-smoke.log"
test -z "$(git status --porcelain)"
echo 'Qt component/launcher gates and both Client compiles passed; live-stream and hardware acceptance remain pending.' >> "$GITHUB_STEP_SUMMARY"
