#!/usr/bin/env bash
# Interactive Client installer; DMG contains the signed PKG, not drag-and-drop.
set -euo pipefail
[[ $# == 2 && $1 == /* && $2 == /* ]] || { echo 'usage: build-macos-client-dmg.sh CLEAN_SOURCE NEW_OUTPUT' >&2; exit 2; }
source_root=$1
output=$2
source "$source_root/scripts/build/macos-client-target.sh"
plank_macos_client_target
: "${PLANK_MACOS_SIGNING_IDENTITY:?Developer ID Application SHA1 required}"
: "${PLANK_MACOS_INSTALLER_IDENTITY:?Developer ID Installer SHA1 required}"
: "${PLANK_NOTARY_PROFILE:?Keychain profile required}"
: "${PLANK_QT_ROOT:?}"
test -z "$(git -C "$source_root" status --porcelain)"
test -z "$(git -C "$source_root/apps/client" status --porcelain)"
source "$source_root/scripts/package/package-version.sh"
plank_load_package_version "$source_root"
mkdir "$output"
build=${PLANK_MAC_CLIENT_BUILD:-"$output/build"}
[[ $build == /* ]] || exit 2
# An explicitly retained build is reconfigured/rebuilt, never trusted blindly.
bash "$source_root/scripts/build/build-macos-client.sh" "$source_root" "$build"
umask 022
mkdir -p "$output/image" "$output/payload/Applications" "$output/install-scripts"
app="$output/payload/Applications/PLANK Client.app"
ditto "$build/app/plank-client.app" "$app"
"$PLANK_QT_ROOT/bin/macdeployqt" "$app" \
    "-qmldir=$source_root/apps/client/app/gui" -always-overwrite -no-strip
# macdeployqt selects Cocoa only; retain the small offscreen plugin so the
# shipped executable can also run our headless version/diagnostic checks.
cp "$PLANK_QT_ROOT/plugins/platforms/libqoffscreen.dylib" "$app/Contents/PlugIns/platforms/"
# Qt deploys server database plugins that PLANK never loads. Keep only SQLite
# for Qt's optional local-storage implementation; no ODBC/Mimer/PostgreSQL/etc.
# dependencies should enter the app. The independent closure gate still checks
# every retained binary, so this is not an exception to dependency validation.
for plugin in "$app/Contents/PlugIns/sqldrivers/"*.dylib; do
    [[ -f "$plugin" ]] || continue
    [[ ${plugin##*/} == libqsqlite.dylib ]] || rm "$plugin"
done
mkdir "$output/plank.iconset"
clang -fobjc-arc -mmacosx-version-min="$PLANK_MAC_CLIENT_MIN_MACOS" "$source_root/scripts/package/macos-app-icon.m" \
    -framework Foundation -framework CoreGraphics -framework ImageIO -o "$output/macos-app-icon"
"$output/macos-app-icon" "$source_root/branding/assets/plank-logo.png" "$output/plank.iconset"
iconutil -c icns "$output/plank.iconset" -o "$app/Contents/Resources/plank.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile plank' "$app/Contents/Info.plist"
# Remove only the inherited icon in this newly created packaging tree.
if [[ -f "$app/Contents/Resources/moonlight.icns" ]]; then
    rm "$app/Contents/Resources/moonlight.icns"
fi
mkdir -p "$app/Contents/Resources/licenses"
install -m 0644 "$source_root/packaging/client/config/plank-client.conf" "$app/Contents/Resources/client.conf.example"
cp "$source_root/apps/client/LICENSE" "$app/Contents/Resources/licenses/client.txt"
for name in SDL3-3.4.2 SDL3_ttf-3.2.2 opus-1.5.2 openssl-3.5.5 freetype-2.14.1 ffmpeg-9.0.1; do
    mkdir "$app/Contents/Resources/licenses/$name"
    find "$PLANK_MAC_CLIENT_DEPS/src/$name" -maxdepth 1 -type f \
        \( -name 'COPYING*' -o -name 'LICENSE*' -o -name 'LICENSE.txt' \) \
        -exec cp {} "$app/Contents/Resources/licenses/$name/" \;
done
while IFS= read -r -d '' binary; do
    file -b "$binary" | grep -q 'Mach-O' || continue
    # Remove debug sections before distribution signing, not runtime strings.
    strip -S "$binary"
    # macdeployqt relocates linked libraries; remove developer-only search paths.
    while IFS= read -r rpath; do
        case "$rpath" in
            /Users/*) install_name_tool -delete_rpath "$rpath" "$binary" ;;
        esac
    done < <(otool -l "$binary" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
    if otool -L "$binary" | tail -n +2 | grep -E '^[[:space:]]+/(Users|opt|usr/local)/'; then
        echo "Unbundled dependency in $binary" >&2; exit 1
    fi
    codesign --force --options runtime --timestamp --sign "$PLANK_MACOS_SIGNING_IDENTITY" "$binary"
done < <(find "$app" -type f -print0)
while IFS= read -r -d '' framework; do
    codesign --force --options runtime --timestamp --sign "$PLANK_MACOS_SIGNING_IDENTITY" "$framework"
done < <(find "$app" -depth -type d -name '*.framework' -print0)
python3 "$source_root/scripts/test/check-macos-client-target.py" \
    "$app" --target "$PLANK_MAC_CLIENT_MIN_MACOS" > "$output/client-targets.json"
codesign --force --options runtime --timestamp --sign "$PLANK_MACOS_SIGNING_IDENTITY" \
    --entitlements "$source_root/packaging/client/macos/entitlements.plist" "$app"
codesign --verify --deep --strict "$app"
if ! app_version=$(QT_QPA_PLATFORM=offscreen "$app/Contents/MacOS/plank-client" --version); then
    echo 'Packaged Client failed offscreen launch; inspect ~/Library/Logs/PLANK/Client' >&2
    exit 1
fi
[[ $app_version == "PLANK $PLANK_PACKAGE_VERSION" ]] || {
    echo "Packaged Client version mismatch: $app_version" >&2; exit 1;
}
test "$(/usr/libexec/PlistBuddy -c 'Print :PLANKVersion' "$app/Contents/Info.plist")" = "$PLANK_PACKAGE_VERSION"
install -m 0755 "$source_root/packaging/client/macos/pkg-preinstall" "$output/install-scripts/preinstall"
install -m 0644 "$app/Contents/Resources/client.conf.example" "$output/install-scripts/client.conf.example"
xcrun clang -O2 -mmacosx-version-min="$PLANK_MAC_CLIENT_MIN_MACOS" -fobjc-arc -Wall -Wextra -Werror \
    -I"$source_root/apps/host/macos/session" "$source_root/scripts/package/macos-configure.m" \
    "$source_root/apps/host/macos/session/host-configuration.m" -framework Foundation \
    -o "$output/install-scripts/plank-configure"
codesign --force --options runtime --timestamp --sign "$PLANK_MACOS_SIGNING_IDENTITY" "$output/install-scripts/plank-configure"
pkg="$output/image/plank-client_${PLANK_PACKAGE_VERSION}_arm64.pkg"
pkgbuild --root "$output/payload" --component-plist "$source_root/packaging/client/macos/component.plist" \
    --identifier la.instinctual.PLANK.Client --version "$PLANK_BASE_VERSION" --install-location / \
    --ownership recommended --scripts "$output/install-scripts" "$output/client-component.pkg"
productbuild --package "$output/client-component.pkg" --sign "$PLANK_MACOS_INSTALLER_IDENTITY" --timestamp "$pkg"
pkgutil --check-signature "$pkg"
dmg="$output/plank-client_${PLANK_PACKAGE_VERSION}_arm64.dmg"
python3 "$source_root/scripts/test/check-package-build-paths.py" "$app"
notary_flags=(--keychain-profile "$PLANK_NOTARY_PROFILE")
if [[ -n ${PLANK_NOTARY_KEYCHAIN:-} ]]; then
  [[ $PLANK_NOTARY_KEYCHAIN = /* && -f $PLANK_NOTARY_KEYCHAIN ]]
  notary_flags+=(--keychain "$PLANK_NOTARY_KEYCHAIN")
fi
xcrun notarytool submit "$pkg" "${notary_flags[@]}" --wait --timeout 10m --output-format json > "$output/pkg-notary.json"
test "$(plutil -extract status raw "$output/pkg-notary.json")" = Accepted
xcrun stapler staple "$pkg"
xcrun stapler validate "$pkg"
spctl --assess --type install --verbose=2 "$pkg"
hdiutil create -volname "PLANK Client $PLANK_PACKAGE_VERSION" -srcfolder "$output/image" -format UDZO "$dmg"
codesign --timestamp --sign "$PLANK_MACOS_SIGNING_IDENTITY" "$dmg"
xcrun notarytool submit "$dmg" "${notary_flags[@]}" --wait --timeout 10m --output-format json > "$output/notary.json"
test "$(plutil -extract status raw "$output/notary.json")" = Accepted
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
shasum -a 256 "$dmg"
echo 'macos_client_dmg_gate=pass install=not-performed'
plank_collect_package "$source_root" client macos arm64 "macos-${PLANK_MAC_CLIENT_MIN_MACOS%%.*}" "$dmg"
plank_collect_package "$source_root" client macos arm64 "macos-${PLANK_MAC_CLIENT_MIN_MACOS%%.*}" "$pkg"
