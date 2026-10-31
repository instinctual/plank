#!/usr/bin/env bash
# Production display lease with link-time Quartz substitutes; no display mutation.
set -euo pipefail
source_root=${1:?source}; output=${2:?new output}
source "$source_root/scripts/build/macos-host-target.sh"
plank_macos_host_target
mkdir "$output"
xcrun clang -fobjc-arc -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -Wall -Wextra -Werror \
  -Werror=unguarded-availability -Werror=unguarded-availability-new \
  -I"$source_root/apps/host/macos/control" \
  "$source_root/apps/host/macos/control/display-layout.m" "$source_root/tests/auth/macos-display-layout.m" \
  -framework Foundation -framework CoreGraphics -framework ColorSync -o "$output/layout-test"
"$output/layout-test"
