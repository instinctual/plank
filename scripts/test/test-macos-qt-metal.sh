#!/usr/bin/env bash
# Public Qt rendering integration and real Metal precision, with no visible UI.
set -euo pipefail
[[ $# == 2 && $1 == /* && $2 == /* ]] || exit 2
source_root=$1
build=$2
source "$source_root/scripts/build/macos-client-target.sh"
plank_macos_client_target
mkdir -p "$build"
cd "$build"
qmake "$source_root/apps/client/tests/macqtmetal/macqtmetal.pro" \
    CONFIG+=release QMAKE_MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    QMAKE_APPLE_DEVICE_ARCHS=arm64 "QMAKE_CXXFLAGS+=-include arm_acle.h"
make -j"${PLANK_BUILD_JOBS:-3}"
status=0
# The offscreen platform advertises no native RHI windows. Explicitly retain
# the normal scene graph: this fixture supplies its own Metal device/target.
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=metal ./macqtmetal \
    "$source_root/apps/client/app/shaders/vt_renderer.metal" >result.log 2>&1 || status=$?
cat result.log
if [[ $status == 77 ]]; then
    echo 'Qt Metal precision remains unqualified: no GPU on builder.'
    exit 0
fi
exit "$status"
