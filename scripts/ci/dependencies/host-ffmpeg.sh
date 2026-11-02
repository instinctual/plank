#!/usr/bin/env bash
set -euo pipefail
deps="$PLANK_SOURCE_ROOT/apps/host/linux/third-party/build-deps"
ffmpeg="$PLANK_DEP_ROOT/host-ffmpeg"
if [[ ! -f "$ffmpeg/lib/libavcodec.a" ]]; then
  cmake -S "$deps" -B "$deps/build" -DBUILD_ALL=OFF -DBUILD_FFMPEG=ON \
    -DBUILD_FFMPEG_SVT_AV1=OFF -DBUILD_FFMPEG_AMF=OFF \
    -DBUILD_FFMPEG_LIBVA=OFF -DBUILD_FFMPEG_VULKAN=OFF \
    -DCMAKE_C_COMPILER=/opt/rh/gcc-toolset-14/root/usr/bin/gcc \
    -DCMAKE_CXX_COMPILER=/opt/rh/gcc-toolset-14/root/usr/bin/g++ \
    -DCMAKE_INSTALL_LIBDIR=lib -DFFMPEG_INSTALL_PREFIX="$ffmpeg" \
    -DPARALLEL_BUILDS="${PLANK_BUILD_JOBS:-4}"
  cmake --build "$deps/build" --parallel "${PLANK_BUILD_JOBS:-4}"
  cmake --install "$deps/build"
fi
bash "$PLANK_SOURCE_ROOT/scripts/build/verify-host-dependency-patches.sh" "$deps/build"
