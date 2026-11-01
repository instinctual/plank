#!/usr/bin/env bash
# Fetch locked public sources on hits too; never cache compiled product objects.
set -euo pipefail
role=${1:?Product role}
target=${2:?Rust target triple}
cargo fetch --locked --target "$target" --manifest-path "$PLANK_SOURCE_ROOT/protocol/plank-transport/Cargo.toml"
if [[ $role == linux-host ]]; then
  # Standalone vendor unit tests have their own pinned test-only dependencies.
  cargo fetch --locked --target "$target" --manifest-path "$PLANK_SOURCE_ROOT/third_party/quinn-proto-0.11.19/Cargo.toml"
fi
