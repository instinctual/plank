#!/usr/bin/env bash
# Small production-code checks and GPU probes, without building a Host or deps.
set -euo pipefail
source /etc/os-release
[[ $ID = rocky && $VERSION_ID = 9.7 && $(uname -m) = x86_64 ]]
: "${PLANK_SOURCE_ROOT:?}" "${PLANK_WORK_ROOT:?}" "${PLANK_ARTIFACT_ROOT:?}"
root=$PLANK_SOURCE_ROOT
host="$root/apps/host/linux"
deps="$host/third-party/build-deps"
report="$PLANK_ARTIFACT_ROOT/qualification/native10"
mkdir -p "$report"
# No recursive initialization: only the Host and exact CUDA declaration headers.
git -C "$root" submodule update --init --depth 1 apps/host/linux
git -C "$host" submodule update --init --depth 1 third-party/build-deps
git -C "$deps" submodule update --init --depth 1 third-party/FFmpeg/nv-codec-headers
export CXX=/opt/rh/gcc-toolset-14/root/usr/bin/g++
python3 "$root/tests/packaging/test-host-build-version.py"
bash "$root/scripts/test/test-linux-native10.sh" "$PLANK_WORK_ROOT/native10-normal" | tee "$report/normal.log"
PLANK_NATIVE10_SANITIZERS=1 bash "$root/scripts/test/test-linux-native10.sh" \
    "$PLANK_WORK_ROOT/native10-sanitizers" | tee "$report/sanitizers.log"
bash "$root/scripts/test/build-linux-native10-probes.sh" "$report"
test -z "$(git -C "$root" status --porcelain)"
printf 'native10_component_gate=pass package_built=0 hardware_acceptance=not-performed\n'
