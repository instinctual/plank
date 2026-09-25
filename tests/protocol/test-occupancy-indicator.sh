#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build=$(mktemp -d)
trap 'rm -rf -- "$test_build"' EXIT
"${CXX:-c++}" -std=c++20 -Wall -Wextra -Werror -pthread \
  -I"$repo_dir/apps/host/linux/src" \
  "$repo_dir/tests/session/test-occupancy.cpp" \
  "$repo_dir/apps/host/linux/src/session/session_context.cpp" \
  $(pkg-config --cflags --libs libsystemd) -o "$test_build/occupancy"
"$test_build/occupancy"
