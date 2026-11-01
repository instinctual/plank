#!/usr/bin/env bash
# GPU-free upstream Loader tests, plus PLANK's OOM/retry/cleanup regression.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
deps="$root/apps/host/linux/third-party/build-deps"
work="$root/build/vulkan-qualification"
mkdir -p "$work"
loader="$work/loader"
git -C "$deps/third-party/FFmpeg/Vulkan-Loader" worktree add --detach "$loader" HEAD
git -C "$loader" apply "$deps/tests/vulkan-loader/id-filter-allocation-tests.patch"
cmake -S "$deps/third-party/FFmpeg/Vulkan-Headers" -B "$work/headers-build" \
  -DCMAKE_INSTALL_PREFIX="$work/stage"
cmake --install "$work/headers-build"
cmake -S "$loader" -B "$work/loader-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTS=ON -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="$work/stage" \
  -DGOOGLETEST_INSTALL_DIR="$root/apps/host/linux/third-party/googletest"
cmake --build "$work/loader-build" --parallel 4
ctest --test-dir "$work/loader-build" --output-on-failure --timeout 60 \
  --no-tests=error -R 'IdFilterAllocationFailure|DeviceFiltering|Allocation\.' \
  | tee "$work/positive.log"

# Prove the new cases detect the original unchecked-array defect. This changes
# only the disposable test worktree, never the pinned source or shipped loader.
python3 - "$loader/loader/loader_environment.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
source = p.read_text()
check = '''    if (NULL == filter_struct->filters) {
        res = VK_ERROR_OUT_OF_HOST_MEMORY;
        goto out;
    }
'''
assert source.count(check) == 1, 'upstream allocation check changed'
p.write_text(source.replace(check, ''))
PY
cmake --build "$work/loader-build" --parallel 4
ulimit -c 0
if ctest --test-dir "$work/loader-build" --output-on-failure --timeout 60 \
    --no-tests=error -R 'IdFilterAllocationFailure.*false, 0, false, true' > "$work/negative.log" 2>&1; then
  echo 'Negative control unexpectedly passed' >&2; exit 1
fi
grep -Eq 'SEGFAULT|SegFault|Failed' "$work/negative.log"
echo 'vulkan_loader_allocation_positive_and_negative_controls=pass'
