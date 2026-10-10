#!/usr/bin/env bash
set -euo pipefail
work="$PLANK_DEP_ROOT/client-sdl"
source "$PLANK_SOURCE_ROOT/scripts/build/client-sdl.sh"
if [[ ! -f $work/prepared.sha256 ]]; then
  bash "$PLANK_SOURCE_ROOT/scripts/build/build-client-sdl.sh" "$work"
fi
plank_verify_client_sdl "$PLANK_SOURCE_ROOT" "$work"
