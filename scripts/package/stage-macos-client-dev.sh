#!/usr/bin/env bash
# Assemble a locally signed app for development. Never produces a release.
set -euo pipefail
[[ $# == 3 && $1 == /* && $2 == /* && $3 == /* ]] || {
    echo 'usage: stage-macos-client-dev.sh SOURCE BUILD NEW_OUTPUT' >&2; exit 2;
}
source_root=$1
build=$2
output=$3
: "${PLANK_QT_ROOT:?}" "${PLANK_MAC_CLIENT_DEPS:?}"
signing_identity=${PLANK_MACOS_DEV_SIGNING_IDENTITY:--}
signing_flags=(--force --sign "$signing_identity")
if [[ $signing_identity != - ]]; then
    [[ $signing_identity =~ ^[[:xdigit:]]{40}$ ]] || {
        echo 'PLANK_MACOS_DEV_SIGNING_IDENTITY must be a code-signing SHA-1 identity' >&2; exit 2;
    }
    security find-identity -v -p codesigning | grep -Fq "$signing_identity" || {
        echo 'PLANK_MACOS_DEV_SIGNING_IDENTITY is not available in the keychain' >&2; exit 2;
    }
    signing_flags+=(--options runtime --timestamp=none)
fi
source "$source_root/scripts/build/macos-client-target.sh"
plank_macos_client_target
bash "$source_root/scripts/build/build-macos-client.sh" "$source_root" "$build"
mkdir "$output"
app="$output/PLANK Client Development.app"
ditto "$build/app/plank-client.app" "$app"
"$PLANK_QT_ROOT/bin/macdeployqt" "$app" \
    "-qmldir=$source_root/apps/client/app/gui" -always-overwrite -no-strip
cp "$PLANK_QT_ROOT/plugins/platforms/libqoffscreen.dylib" "$app/Contents/PlugIns/platforms/"
for plugin in "$app/Contents/PlugIns/sqldrivers/"*.dylib; do
    [[ -f "$plugin" ]] || continue
    [[ ${plugin##*/} == libqsqlite.dylib ]] || rm "$plugin"
done
mkdir -p "$app/Contents/Resources/licenses"
cp "$source_root/apps/client/LICENSE" "$app/Contents/Resources/licenses/client.txt"
for name in SDL3-3.4.2 SDL3_ttf-3.2.2 opus-1.5.2 openssl-3.5.5 freetype-2.14.1 ffmpeg-9.0.1; do
    mkdir "$app/Contents/Resources/licenses/$name"
    find "$PLANK_MAC_CLIENT_DEPS/src/$name" -maxdepth 1 -type f \
        \( -name 'COPYING*' -o -name 'LICENSE*' \) \
        -exec cp {} "$app/Contents/Resources/licenses/$name/" \;
done
/usr/libexec/PlistBuddy -c 'Add :PLANKDevelopmentBuild bool true' "$app/Contents/Info.plist"
while IFS= read -r -d '' binary; do
    file -b "$binary" | grep -q 'Mach-O' || continue
    strip -S "$binary"
    while IFS= read -r rpath; do
        case "$rpath" in
            /Users/*) install_name_tool -delete_rpath "$rpath" "$binary" ;;
        esac
    done < <(otool -l "$binary" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
    if otool -L "$binary" | tail -n +2 | grep -E '^[[:space:]]+/(Users|opt|usr/local)/'; then
        echo 'Development app has an unbundled dependency' >&2; exit 1
    fi
    codesign "${signing_flags[@]}" "$binary"
done < <(find "$app" -type f -print0)
while IFS= read -r -d '' framework; do
    codesign "${signing_flags[@]}" "$framework"
done < <(find "$app" -depth -type d -name '*.framework' -print0)
python3 "$source_root/scripts/test/check-macos-client-target.py" \
    "$app" --target "$PLANK_MAC_CLIENT_MIN_MACOS" > "$output/client-targets.json"
python3 "$source_root/scripts/test/check-package-build-paths.py" "$app"
codesign "${signing_flags[@]}" --entitlements "$source_root/packaging/client/macos/entitlements.plist" "$app"
codesign --verify --deep --strict "$app"
if [[ $signing_identity != - ]]; then
    requirement=$(codesign -d -r- "$app" 2>&1)
    [[ $requirement != *'cdhash'* ]] || {
        echo 'Development app did not receive a stable signing requirement' >&2; exit 1;
    }
fi
QT_QPA_PLATFORM=offscreen "$app/Contents/MacOS/plank-client" --version
echo 'macos_client_development_app=pass notarized=no live_session=untested'
