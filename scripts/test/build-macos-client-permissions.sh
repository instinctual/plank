#!/usr/bin/env bash
# Synthetic permission boundaries + real Qt Quick layout. No installed app/TCC.
set -euo pipefail
[[ $# == 2 && $1 == /* && $2 == /* && $(uname -s) == Darwin ]] || exit 2
: "${PLANK_QT_ROOT:?Pinned Qt required}"
source_root=$1; output=$2
mkdir -p "$output"
client="$source_root/apps/client"
qt_headers=()
for framework in QtCore QtGui QtQml QtQuick; do
    qt_headers+=("-I$PLANK_QT_ROOT/lib/$framework.framework/Headers")
done
"$PLANK_QT_ROOT/libexec/moc" "$client/app/backend/macpermissions.h" -o "$output/moc_macpermissions.cpp"
xcrun clang++ -std=c++17 -fobjc-arc -include arm_acle.h -mmacosx-version-min=15.0 \
    -Wall -Wextra -Werror -F"$PLANK_QT_ROOT/lib" -I"$PLANK_QT_ROOT/include" "${qt_headers[@]}" \
    "$source_root/tests/packaging/macos-client-permissions.mm" "$output/moc_macpermissions.cpp" \
    -framework QtCore -framework QtGui -framework QtQml -framework QtQuick \
    -framework Foundation -framework ApplicationServices -framework IOKit \
    -Wl,-rpath,"$PLANK_QT_ROOT/lib" -o "$output/client-permissions-test"
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=Material \
    "$output/client-permissions-test" "$client/app/gui" "$output/client-permissions.png"
