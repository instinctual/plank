#!/usr/bin/env bash
set -euo pipefail
boost="$PLANK_DEP_ROOT/boost-1.92.0"
if [[ ! -f "$boost/CMakeLists.txt" ]]; then
  archive="$PLANK_DEP_ROOT/boost-1.92.0-cmake.tar.xz"
  curl --fail --location https://github.com/boostorg/boost/releases/download/boost-1.92.0/boost-1.92.0-cmake.tar.xz -o "$archive"
  echo "9bed76128d4e46755dbe818487788c6fceb6f72b378f4daa49b7e1e600d9088d  $archive" | sha256sum -c -
  mkdir "$boost"
  tar -xJf "$archive" --strip-components=1 -C "$boost"
fi
