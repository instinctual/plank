#!/usr/bin/env bash
# Private, pinned Apple Silicon inputs; never installs into /usr or /Applications.
set -euo pipefail
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || exit 2
: "${PLANK_MAC_CLIENT_DEPS:?Set the private dependency root}"
: "${PLANK_SOURCE_ROOT:?Set the source checkout}"
source "$PLANK_SOURCE_ROOT/scripts/build/macos-client-target.sh"
plank_macos_client_target
prefix="$PLANK_MAC_CLIENT_DEPS/install"
mkdir -p "$PLANK_MAC_CLIENT_DEPS/downloads" "$PLANK_MAC_CLIENT_DEPS/src" "$prefix"
export PATH="$prefix/bin:/Applications/CMake.app/Contents/bin:$PATH"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
jobs=${PLANK_BUILD_JOBS:-8}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || exit 2
source "$PLANK_SOURCE_ROOT/scripts/build/build-paths.sh"
plank_build_path_flags "$PLANK_SOURCE_ROOT" "$PLANK_MAC_CLIENT_DEPS"

fetch() {
    local url=$1 hash=$2 name=${1##*/}
    local archive="$PLANK_MAC_CLIENT_DEPS/downloads/$name"
    [[ -f $archive ]] || curl --fail --location --retry 3 --connect-timeout 30 \
        --max-time 900 --output "$archive" "$url"
    printf '%s  %s\n' "$hash" "$archive" | shasum -a 256 -c -
    tar -xf "$archive" -C "$PLANK_MAC_CLIENT_DEPS/src"
}
cmake_build() {
    local name=$1
    shift
    cmake -S "$PLANK_MAC_CLIENT_DEPS/src/$name" -B "$PLANK_MAC_CLIENT_DEPS/build-$name" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        "-DCMAKE_C_FLAGS=$PLANK_C_FILE_FLAGS" "-DCMAKE_CXX_FLAGS=$PLANK_C_FILE_FLAGS" \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DBUILD_SHARED_LIBS=ON "$@"
    cmake --build "$PLANK_MAC_CLIENT_DEPS/build-$name" --parallel "$jobs"
    cmake --install "$PLANK_MAC_CLIENT_DEPS/build-$name"
}

if [[ ${1:-all} == all ]]; then
fetch https://distfiles.ariadne.space/pkgconf/pkgconf-2.5.1.tar.xz cd05c9589b9f86ecf044c10a2269822bc9eb001eced2582cfffd658b0a50c243
(
    cd "$PLANK_MAC_CLIENT_DEPS/src/pkgconf-2.5.1"
    ./configure --prefix="$prefix" --disable-shared
    make -j"$jobs"
    make install
    ln -sf pkgconf "$prefix/bin/pkg-config"
)
fetch https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
(
    cd "$PLANK_MAC_CLIENT_DEPS/src/openssl-3.5.9"
    # Runtime defaults must never point into a builder's writable home. Stage
    # the conventional install tree, then relocate only development link/pc
    # metadata. Do not bundle config, engines or optional provider modules.
    openssl_prefix=/usr/local/lib/plank-client
    openssl_stage="$PLANK_MAC_CLIENT_DEPS/openssl-stage"
    LDFLAGS="${LDFLAGS:+$LDFLAGS }-Wl,-headerpad_max_install_names" \
    ./Configure darwin64-arm64-cc --prefix="$openssl_prefix" \
        --openssldir=/etc/plank/openssl shared no-tests
    make -j"$jobs"
    make install_sw DESTDIR="$openssl_stage"
    cp -R "$openssl_stage$openssl_prefix/." "$prefix/"
    python3 "$PLANK_SOURCE_ROOT/scripts/build/relocate-openssl-pc.py" "$prefix" "$openssl_prefix"
    for library in libcrypto.3.dylib libssl.3.dylib; do
        install_name_tool -id "$prefix/lib/$library" "$prefix/lib/$library"
    done
    install_name_tool -change "$openssl_prefix/lib/libcrypto.3.dylib" \
        "$prefix/lib/libcrypto.3.dylib" "$prefix/lib/libssl.3.dylib"
)
fetch https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
cmake_build opus-1.6.1 -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
fetch https://github.com/libsdl-org/SDL/releases/download/release-3.4.18/SDL3-3.4.18.tar.gz 9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3
cmake_build SDL3-3.4.18 -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_SHARED=ON -DSDL_STATIC=OFF
fetch https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz 93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5
cmake_build freetype-2.15.0 -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_ZLIB=ON
fetch https://github.com/libsdl-org/SDL_ttf/releases/download/release-3.2.2/SDL3_ttf-3.2.2.tar.gz 63547d58d0185c833213885b635a2c0548201cc8f301e6587c0be1a67e1e045d
cmake_build SDL3_ttf-3.2.2 -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_SAMPLES=OFF
elif [[ $1 != ffmpeg ]]; then
    echo 'usage: bootstrap-macos-client-deps.sh [all|ffmpeg]' >&2
    exit 2
fi
fetch https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
ffmpeg_source="$PLANK_MAC_CLIENT_DEPS/src/ffmpeg-9.0.2"
identity_patch="$PLANK_SOURCE_ROOT/apps/client/app/deploy/linux/ffmpeg-patches/0001-hevc-enable-hwaccel-for-identity-gbr.patch"
printf '%s  %s\n' d8514ed9db3fc2c1aba43cfad0b06f8be3670759bdb173b6fd0a6dc1cffa0bf4 "$identity_patch" | shasum -a 256 -c -
patch --batch --forward -d "$ffmpeg_source" -p1 < "$identity_patch"
patch --batch --reverse --dry-run -d "$ffmpeg_source" -p1 < "$identity_patch"
mkdir -p "$PLANK_MAC_CLIENT_DEPS/build-ffmpeg"
(
    cd "$PLANK_MAC_CLIENT_DEPS/build-ffmpeg"
    "$ffmpeg_source/configure" --prefix="$prefix" --enable-shared --disable-static \
        --disable-doc --disable-debug --disable-autodetect --enable-videotoolbox \
        --enable-audiotoolbox --enable-neon --arch=arm64 --target-os=darwin \
        --extra-cflags="$PLANK_C_FILE_FLAGS"
    python3 "$PLANK_SOURCE_ROOT/scripts/build/sanitize-ffmpeg-build-info.py" \
        config.h "$PLANK_MAC_CLIENT_DEPS" "$PLANK_SOURCE_ROOT" "$HOME"
    make -j"$jobs"
    make install
)
pkg-config --modversion sdl3 sdl3-ttf openssl opus libavcodec libavutil
python3 "$PLANK_SOURCE_ROOT/scripts/test/check-macos-client-target.py" \
    "$prefix/lib" --target "$PLANK_MAC_CLIENT_MIN_MACOS"
