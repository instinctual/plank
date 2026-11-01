#!/usr/bin/env bash
# Bootstrap only pinned inputs, then use the normal product build entrypoints.
# Keep dependency versions, flags and preparation in the independently hashed
# recipes. This wrapper only selects the platform and sequences their execution.
set -euo pipefail
role=${1:?linux-host, linux-client, macos-host or macos-client}
: "${PLANK_SOURCE_ROOT:?}" "${PLANK_DEP_ROOT:?}" "${PLANK_WORK_ROOT:?}"
mkdir -p "$PLANK_DEP_ROOT" "$PLANK_WORK_ROOT"
case $role in
  linux-host) product=apps/host/linux; target=x86_64-unknown-linux-gnu ;;
  linux-client) product=apps/client; target=x86_64-unknown-linux-gnu ;;
  macos-host) product=; target=aarch64-apple-darwin ;;
  macos-client) product=apps/client; target=aarch64-apple-darwin ;;
  *) exit 2 ;;
esac
git -C "$PLANK_SOURCE_ROOT" submodule update --init third_party/kyber-kymux
if [[ -n $product ]]; then
  git -C "$PLANK_SOURCE_ROOT" submodule update --init --recursive "$product"
fi
export CARGO_HOME="$PLANK_CARGO_ROOT" RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export PATH="$CARGO_HOME/bin:$PATH"
dependency_scripts="$PLANK_SOURCE_ROOT/scripts/ci/dependencies"
bash "$dependency_scripts/rust.sh" "$target"
bash "$dependency_scripts/cargo.sh" "$role" "$target"
case $role in
  linux-host)
    bash "$dependency_scripts/boost.sh"
    bash "$dependency_scripts/host-ffmpeg.sh"
    ;;
  linux-client)
    bash "$dependency_scripts/client-ffmpeg.sh"
    ;;
  macos-*)
    test "$(uname -m)" = arm64
    test "$(sw_vers -productVersion | cut -d . -f 1)" -ge 27
    test "$(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1)" -ge 27
    if [[ $role = macos-client ]]; then
      bash "$dependency_scripts/macos-libraries.sh"
      bash "$dependency_scripts/qt.sh"
    fi
    ;;
esac
test -z "$(git -C "$PLANK_SOURCE_ROOT" status --porcelain)"
echo 'hosted_bootstrap_gate=pass'
