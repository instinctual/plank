#!/usr/bin/env bash
# Qualified Ubuntu Client dependency; never install over the OS SDL library.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(realpath -m -- "${1:?SDL dependency work directory required}")
source "$repo_dir/scripts/build/client-sdl.sh"
# SDL's ON switches can still silently disable a driver when headers are
# missing. Refuse that partial build before downloading or configuring.
pkg-config --exists 'libpipewire-0.3 >= 0.3.44' wayland-client wayland-cursor \
  wayland-egl wayland-protocols xkbcommon libdecor-0 egl x11
archive="$work_dir/SDL3-$plank_sdl_version.tar.gz"
source_dir="$work_dir/SDL3-$plank_sdl_version"
mkdir -p "$work_dir"
if [[ ! -f $archive ]]; then
  curl --fail --location --output "$archive" \
    "https://github.com/libsdl-org/SDL/releases/download/release-$plank_sdl_version/SDL3-$plank_sdl_version.tar.gz"
fi
printf '%s  %s\n' "$plank_sdl_sha256" "$archive" | sha256sum --check --status
if [[ ! -d $source_dir ]]; then tar -xzf "$archive" -C "$work_dir"; fi
patch_file="$repo_dir/$plank_sdl_patch_relative"
if patch --batch --fuzz=0 --forward --dry-run -d "$source_dir" -p1 < "$patch_file" >/dev/null 2>&1; then
  patch --batch --fuzz=0 --forward --no-backup-if-mismatch -d "$source_dir" -p1 < "$patch_file"
else
  patch --batch --fuzz=0 --reverse --dry-run -d "$source_dir" -p1 < "$patch_file" >/dev/null
fi
python3 "$repo_dir/tests/input/test-sdl-cursor-retirement.py" "$source_dir"
source "$repo_dir/scripts/build/build-paths.sh"
plank_build_path_flags "$source_dir" "$work_dir"
cmake -S "$source_dir" -B "$work_dir/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$work_dir/install" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_C_FLAGS="$PLANK_C_FILE_FLAGS" \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF \
  -DSDL_RPATH=OFF \
  -DSDL_WAYLAND=ON -DSDL_WAYLAND_LIBDECOR=ON -DSDL_X11=ON \
  -DSDL_OPENGL=ON -DSDL_OPENGLES=ON -DSDL_PIPEWIRE=ON \
  -DSDL_ALSA=ON -DSDL_PULSEAUDIO=ON -DSDL_UNIX_CONSOLE_BUILD=OFF
cmake --build "$work_dir/build" --parallel "${PLANK_BUILD_JOBS:-8}"
cmake --install "$work_dir/build"
python3 "$repo_dir/scripts/test/check-client-sdl.py" "$work_dir/install/lib/libSDL3.so.0"
(sha256sum "$patch_file" | cut -d' ' -f1) > "$work_dir/patch.sha256"
(cd "$work_dir" && find install -type f -print0 | sort -z | xargs -0 sha256sum > prepared.sha256)
plank_verify_client_sdl "$repo_dir" "$work_dir"
echo 'client_sdl_source_patch_and_runtime_gate=pass'
