#!/usr/bin/env bash
# Public Qt rendering integration and real Metal precision on hosted builders.
set -euo pipefail
[[ $# == 2 && $1 == /* && $2 == /* ]] || exit 2
source_root=$1
build=$2
source "$source_root/scripts/build/macos-client-target.sh"
plank_macos_client_target
for fixture in macqtmetal macqtvideo macqtwindow; do
    fixture_build="$build/$fixture"
    mkdir -p "$fixture_build"
    cd "$fixture_build"
    qmake "$source_root/apps/client/tests/$fixture/$fixture.pro" \
        CONFIG+=release QMAKE_MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        QMAKE_APPLE_DEVICE_ARCHS=arm64 "QMAKE_CXXFLAGS+=-include arm_acle.h"
    make -j"${PLANK_BUILD_JOBS:-3}"
    status=0
    # Offscreen supplies no native RHI window. These fixtures provide their own
    # Metal device/target and exercise the normal RHI scene graph explicitly.
    platform=offscreen
    args=()
    if [[ $fixture == macqtwindow ]]; then
        platform=cocoa
    else
        args+=("$source_root/apps/client/app/shaders/vt_renderer.metal")
    fi
    QT_QPA_PLATFORM=$platform QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=metal \
        python3 - "$fixture" "${args[@]}" >result.log 2>&1 <<'PY' || status=$?
import subprocess, sys
try:
    sys.exit(subprocess.run(['./' + sys.argv[1], *sys.argv[2:]], timeout=90).returncode)
except subprocess.TimeoutExpired:
    sys.exit('Qt Metal fixture exceeded its lifecycle deadline')
PY
    cat result.log
    if [[ $status == 77 ]]; then
        echo 'Qt Metal precision remains unqualified: no GPU on builder.'
    elif [[ $status != 0 ]]; then
        exit "$status"
    fi
done
