#!/bin/bash
# Temporary native Installer UI; never install on a builder or deployment target.
set -euo pipefail
[[ $# = 2 && $1 = /* && $2 = /* && $(uname -s) = Darwin ]]
source_root=$1; output=$2
source "$source_root/scripts/build/macos-host-target.sh"
plank_macos_host_target
source "$source_root/scripts/build/build-paths.sh"
plank_build_path_flags "$source_root" "$output"
umask 022
mkdir "$output"
flags=(-mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -O2 -Wall -Wextra -Werror
       -Werror=deprecated-declarations -Werror=unguarded-availability -Werror=unguarded-availability-new
       "${PLANK_FILE_FLAGS[@]}" -framework AppKit -framework InstallerPlugins)
xcrun clang "${flags[@]}" -I"$source_root/packaging/host/macos" \
  "$source_root/tests/packaging/macos-installer-preflight.m" -o "$output/preflight-test"
"$output/preflight-test"
xcrun clang "${flags[@]}" "$source_root/tests/packaging/macos-installer-bundle.m" -o "$output/bundle-checker"
bundle="$output/plugins/PLANKRequirements.bundle"
mkdir -p "$bundle/Contents/MacOS"
xcrun clang "${flags[@]}" -bundle "$source_root/packaging/host/macos/installer-preflight.m" \
  -o "$bundle/Contents/MacOS/PLANKRequirements"
sed -e "s/@VERSION@/$(cat "$source_root/packaging/VERSION")/g" -e "s/@MIN_MACOS@/$MACOSX_DEPLOYMENT_TARGET/g" \
  "$source_root/packaging/host/macos/installer-preflight-Info.plist.in" > "$bundle/Contents/Info.plist"
install -m 0644 "$source_root/packaging/host/macos/InstallerSections.plist" "$output/plugins/"
plutil -lint "$bundle/Contents/Info.plist" "$output/plugins/InstallerSections.plist"
"$output/bundle-checker" "$bundle"
python3 "$source_root/scripts/test/check-package-build-paths.py" "$output/plugins"
