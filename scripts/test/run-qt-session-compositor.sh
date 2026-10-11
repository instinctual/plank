#!/usr/bin/env bash
set -euo pipefail

# Run only on the Ubuntu builder. This starts a separate headless compositor,
# private session bus and in-memory settings; it never joins the user's desktop.
: "${PLANK_QT_SESSION_TEST_BUILD:?Set the existing Qt-session test build directory}"
command -v gnome-shell >/dev/null
command -v dbus-run-session >/dev/null
test -x "$PLANK_QT_SESSION_TEST_BUILD/tests/qtsession"
runtime=$(mktemp -d /tmp/plank-qt-compositor.XXXXXXXX)
chmod 0700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
export GSETTINGS_BACKEND=memory
unset DISPLAY WAYLAND_DISPLAY

dbus-run-session -- bash -eu -c '
    gnome-shell --headless --wayland --no-x11 --wayland-display plank-qt-test \
        --virtual-monitor 1920x1080 >"$XDG_RUNTIME_DIR/compositor.log" 2>&1 &
    compositor_pid=$!
    trap '\''kill "$compositor_pid" 2>/dev/null || true; wait "$compositor_pid" 2>/dev/null || true'\'' EXIT
    for attempt in $(seq 1 100); do
        if test -S "$XDG_RUNTIME_DIR/plank-qt-test"; then break; fi
        kill -0 "$compositor_pid" 2>/dev/null || { echo "Headless compositor failed; inspect its local log" >&2; exit 1; }
        sleep 0.1
    done
    test -S "$XDG_RUNTIME_DIR/plank-qt-test"
    export WAYLAND_DISPLAY=plank-qt-test
    export QT_QPA_PLATFORM=wayland
    export QSG_RHI_BACKEND=opengl
    unset QT_QUICK_BACKEND
    "$PLANK_QT_SESSION_TEST_BUILD/tests/qtsession"
    "$PLANK_QT_SESSION_TEST_BUILD/probe/plank-qt-session-probe" --native-child --fullscreen --quit-after 2
    if test "${PLANK_QT_CHECK_PRECISION:-0}" = 1; then
        # Only the decorated shell/native scene is the proposed architecture.
        # The direct decorated QQuickView remains a separate negative comparison.
        precision_status=0
        "$PLANK_QT_SESSION_TEST_BUILD/probe/plank-qt-session-probe" --precision-check --native-child || precision_status=1
        "$PLANK_QT_SESSION_TEST_BUILD/probe/plank-qt-session-probe" --precision-check --native-child --fullscreen || precision_status=1
        "$PLANK_QT_SESSION_TEST_BUILD/probe/plank-qt-session-probe" --precision-check --native-child --roundtrip || precision_status=1
        "$PLANK_QT_SESSION_TEST_BUILD/probe/plank-qt-session-probe" --precision-check --native-child --fullscreen --roundtrip || precision_status=1
        exit "$precision_status"
    fi
'
# Logs are intentionally retained in the named, owner-only temporary directory.
printf 'Compositor log retained in %s\n' "$runtime"
