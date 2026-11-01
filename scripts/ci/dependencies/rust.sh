#!/usr/bin/env bash
# Toolchain only: crate downloads have their own cache and bootstrap.
set -euo pipefail
target=${1:?Rust target triple}
export CARGO_HOME="$PLANK_CARGO_ROOT" RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export PATH="$CARGO_HOME/bin:$PATH"
if [[ ! -x "$CARGO_HOME/bin/rustup" ]]; then
  installer="$PLANK_DEP_ROOT/rustup-bootstrap"
  mkdir -p "$installer"
  curl --fail --location "https://static.rust-lang.org/rustup/archive/1.29.2/$target/rustup-init" -o "$installer/rustup-init"
  curl --fail --location "https://static.rust-lang.org/rustup/archive/1.29.2/$target/rustup-init.sha256" -o "$installer/rustup-init.sha256"
  if [[ $target == *linux* ]]; then
    (cd "$installer"; sha256sum -c rustup-init.sha256)
  else
    (cd "$installer"; shasum -a 256 -c rustup-init.sha256)
  fi
  chmod 0755 "$installer/rustup-init"
  RUSTUP_INIT_SKIP_PATH_CHECK=yes "$installer/rustup-init" -y --no-modify-path --profile minimal --default-toolchain 1.99.1
fi
test "$(rustc --version)" = 'rustc 1.99.1 (58cf8f9c3 2026-10-13)'
test "$(cargo --version)" = 'cargo 1.99.1 (5f94df478 2026-08-27)'
