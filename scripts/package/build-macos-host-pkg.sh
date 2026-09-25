#!/bin/bash
# Receipt-backed distribution on an authorized macOS builder (including CI).
set -euo pipefail
if [[ $# != 3 || $1 != /* || $2 != /* || $3 != /* || $(uname -s) != Darwin ]]; then
  echo 'Usage: build-macos-host-pkg.sh CLEAN_SOURCE NEW_OUTPUT RETAINED_TRANSPORT_ARCHIVE' >&2; exit 2
fi
source_root=$1; output=$2; archive=$3
: "${PLANK_MACOS_SIGNING_IDENTITY:?Developer ID Application SHA1 required}"
: "${PLANK_MACOS_INSTALLER_IDENTITY:?Developer ID Installer SHA1 required}"
: "${PLANK_MACOS_TEAM_ID:?Developer Team ID required}"
: "${PLANK_MACOS_APP_PROVISION_PROFILE:?Production Host system-extension installation profile required}"
: "${PLANK_NOTARY_PROFILE:?Keychain profile required}"
[[ $PLANK_MACOS_SIGNING_IDENTITY =~ ^[[:xdigit:]]{40}$ && $PLANK_MACOS_INSTALLER_IDENTITY =~ ^[[:xdigit:]]{40}$ ]]
[[ $PLANK_MACOS_TEAM_ID =~ ^[A-Z0-9]{10}$ ]]
test -z "$(git -C "$source_root" status --porcelain)"
source "$source_root/scripts/package/package-version.sh"
plank_load_package_version "$source_root"
export PLANK_MACOS_HOST_VERSION=$PLANK_PACKAGE_VERSION PLANK_MACOS_DISTRIBUTION=1
identities=$(security find-identity -v)
echo "$identities" | grep -F "$PLANK_MACOS_SIGNING_IDENTITY" | grep -F '"Developer ID Application:'
echo "$identities" | grep -F "$PLANK_MACOS_INSTALLER_IDENTITY" | grep -F '"Developer ID Installer:'
mkdir "$output"
# Only public distribution staging lives here. Installed private state retains
# its separate restrictive umask in pkg-common.sh.
umask 022
printf '%s\n' "source=$(git -C "$source_root" rev-parse HEAD)" "version=$PLANK_PACKAGE_VERSION"
shasum -a 256 "$archive"
bash "$source_root/scripts/build/build-macos-host.sh" "$source_root" "$output/host" "$archive"
bash "$source_root/tests/packaging/macos-pkg-scripts.sh"

mkdir -p "$output/payload/Applications" "$output/install-scripts" "$output/resources"
app="$output/payload/Applications/PLANK Host.app"
ditto "$output/host/PLANK Host.app" "$app"
mkdir -p "$output/payload/Library/Audio/Plug-Ins/HAL"
driver="$output/payload/Library/Audio/Plug-Ins/HAL/PLANK Microphone.driver"
ditto "$output/host/PLANK Microphone.driver" "$driver"
output_driver="$output/payload/Library/Audio/Plug-Ins/HAL/PLANK Output.driver"
ditto "$output/host/PLANK Output.driver" "$output_driver"
codesign --verify --strict -R "=identifier \"la.instinctual.PLANK.Output\" and anchor apple generic and certificate leaf[subject.OU] = \"$PLANK_MACOS_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$output_driver"
codesign --verify --strict -R "=identifier \"la.instinctual.PLANK.Microphone\" and anchor apple generic and certificate leaf[subject.OU] = \"$PLANK_MACOS_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$driver"
codesign --verify --strict -R "=identifier \"la.instinctual.PLANK.Host\" and anchor apple generic and certificate leaf[subject.OU] = \"$PLANK_MACOS_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$app"
camera="$app/Contents/Library/SystemExtensions/la.instinctual.PLANK.Host.Camera.systemextension"
codesign --verify --strict -R "=identifier \"la.instinctual.PLANK.Host.Camera\" and anchor apple generic and certificate leaf[subject.OU] = \"$PLANK_MACOS_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$camera"
test "$(/usr/libexec/PlistBuddy -c 'Print :PLANKVersion' "$app/Contents/Info.plist")" = "$PLANK_PACKAGE_VERSION"
test -z "$(find "$output/payload" -name '*.py' -print)"
codesign -d --verbose=4 "$app" 2>&1 | grep 'flags=.*runtime'
codesign -d --verbose=4 "$app" 2>&1 | grep '^Timestamp='
otool -L "$app/Contents/MacOS/plank-host"
sed -e "s/@TEAM@/$PLANK_MACOS_TEAM_ID/g" -e "s/@VERSION@/$PLANK_PACKAGE_VERSION/g" \
  "$source_root/packaging/host/macos/pkg-common.sh" > "$output/install-scripts/pkg-common.sh"
chmod 0644 "$output/install-scripts/pkg-common.sh"
install -m 0755 "$app/Contents/Resources/plank-configure" "$output/install-scripts/"
install -m 0644 "$app/Contents/Resources/host.conf.example" "$output/install-scripts/"
mkdir -p "$output/payload/Library/LaunchDaemons" "$output/payload/Library/LaunchAgents"
for role in machine desktop sign-in; do
  if [[ $role = machine ]]; then directory=LaunchDaemons; else directory=LaunchAgents; fi
  plist="la.instinctual.PLANK.Host.$role.plist"
  plutil -lint "$source_root/packaging/host/macos/$plist"
  install -m 0644 "$source_root/packaging/host/macos/$plist" "$output/payload/Library/$directory/$plist"
done
install -m 0755 "$source_root/packaging/host/macos/pkg-preinstall" "$output/install-scripts/preinstall"
install -m 0755 "$source_root/packaging/host/macos/pkg-postinstall" "$output/install-scripts/postinstall"
test -x "$app/Contents/Resources/uninstall.sh"
bash -n "$app/Contents/Resources/uninstall.sh"
install -m 0644 "$source_root/packaging/host/macos/welcome.html" "$source_root/packaging/host/macos/conclusion.html" "$output/resources/"
python3 "$source_root/scripts/test/check-package-build-paths.py" "$output/payload"
python3 "$source_root/scripts/test/check-macos-host-permissions.py" --payload "$output/payload"
pkgbuild --root "$output/payload" --component-plist "$source_root/packaging/host/macos/component.plist" \
  --identifier la.instinctual.PLANK.Host --version "$PLANK_BASE_VERSION" --install-location / \
  --ownership recommended --scripts "$output/install-scripts" "$output/host-component.pkg"
name="plank-host_${PLANK_PACKAGE_VERSION}_arm64.pkg"
sed -e "s/@TITLE@/PLANK Host $PLANK_PACKAGE_VERSION/g" \
  -e 's/@WELCOME@/welcome.html/g' -e 's/@CONCLUSION@/conclusion.html/g' \
  -e 's/@IDENTIFIER@/la.instinctual.PLANK.Host/g' -e "s/@VERSION@/$PLANK_BASE_VERSION/g" \
  -e 's/@COMPONENT@/host-component.pkg/g' \
  "$source_root/packaging/host/macos/distribution.xml.in" > "$output/host-distribution.xml"
productbuild --distribution "$output/host-distribution.xml" --resources "$output/resources" \
  --package-path "$output" --sign "$PLANK_MACOS_INSTALLER_IDENTITY" --timestamp "$output/$name"
pkgutil --check-signature "$output/$name"
if [[ $(/usr/sbin/installer -query RestartAction -pkg "$output/$name") != RecommendRestart ]]; then
  echo 'Host package must recommend a restart through macOS Installer.' >&2; exit 1
fi
python3 "$source_root/scripts/test/check-macos-host-permissions.py" --pkg "$output/$name"
notary_flags=(--keychain-profile "$PLANK_NOTARY_PROFILE")
if [[ -n ${PLANK_NOTARY_KEYCHAIN:-} ]]; then
  [[ $PLANK_NOTARY_KEYCHAIN = /* && -f $PLANK_NOTARY_KEYCHAIN ]]
  notary_flags+=(--keychain "$PLANK_NOTARY_KEYCHAIN")
fi
xcrun notarytool submit "$output/$name" "${notary_flags[@]}" --wait --timeout 10m --output-format json > "$output/host-notary.json"
/usr/bin/plutil -extract status raw "$output/host-notary.json" | grep -x Accepted
xcrun stapler staple "$output/$name"
xcrun stapler validate "$output/$name"
spctl --assess --type install --verbose=2 "$output/$name"
shasum -a 256 "$output/$name"
echo 'macos_pkg_gate=pass install=not-performed'
plank_collect_package "$source_root" host macos arm64 macos-27 "$output/$name"
