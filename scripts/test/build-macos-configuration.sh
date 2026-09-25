#!/bin/bash
# Synthetic filesystem only; no installed application, launchd, TCC or session.
set -euo pipefail
source_root=${1:?source}; output=${2:?new output}
mkdir "$output"
flags=(-mmacosx-version-min=15.0 -fobjc-arc -Wall -Wextra -Werror -I"$source_root/apps/host/macos/session")
xcrun clang "${flags[@]}" "$source_root/scripts/package/macos-configure.m" \
    "$source_root/apps/host/macos/session/host-configuration.m" -framework Foundation -o "$output/plank-configure"
xcrun clang "${flags[@]}" "$source_root/tests/packaging/macos-host-configuration.m" \
    "$source_root/apps/host/macos/session/host-configuration.m" -framework Foundation -o "$output/parser"
"$output/parser"
PLANK_CONFIGURE_TEST_BINARY="$output/plank-configure" python3 "$source_root/tests/packaging/test-macos-configuration.py"
