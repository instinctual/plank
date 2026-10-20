#!/usr/bin/env bash
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
test $# -eq 1 && test -x "$1"
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
runtime=$(mktemp -d /tmp/plank-qt-audio.XXXXXXXX)
chmod 0700 "$runtime"
mkdir -p "$runtime/config/pipewire/pipewire.conf.d" "$runtime/state"
cp "$source_root/tests/audio/qt-pipewire.conf" "$runtime/config/pipewire/pipewire.conf.d/90-plank-test.conf"
export XDG_RUNTIME_DIR="$runtime" XDG_CONFIG_HOME="$runtime/config" XDG_STATE_HOME="$runtime/state"
unset PIPEWIRE_REMOTE PIPEWIRE_CONFIG_DIR PIPEWIRE_CONFIG_NAME
export PLANK_PIPEWIRE_TEST=1
dbus-run-session -- bash -eu -c '
    pipewire >"$XDG_RUNTIME_DIR/pipewire.log" 2>&1 &
    server_pid=$!
    manager_pid=""
    trap '\''if test -n "$manager_pid"; then kill "$manager_pid" 2>/dev/null || true; wait "$manager_pid" 2>/dev/null || true; fi
        kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true'\'' EXIT
    for attempt in $(seq 1 100); do
        test ! -S "$XDG_RUNTIME_DIR/pipewire-0" || break
        kill -0 "$server_pid"
        sleep 0.05
    done
    test -S "$XDG_RUNTIME_DIR/pipewire-0"
    wireplumber >"$XDG_RUNTIME_DIR/wireplumber.log" 2>&1 &
    manager_pid=$!
    sleep 1
    kill -0 "$manager_pid"
    for quantum in 1024 4096; do
        pw-metadata -n settings 0 clock.force-quantum "$quantum"
        PLANK_PIPEWIRE_TEST_QUANTUM="$quantum" \
            timeout 30 "$1" realPipeWirePlayback unavailableServerFailsPromptly
    done
' qt-audio "$1" || {
    # Only the disposable test daemon logs, never the users desktop.
    tail -n 100 "$runtime/pipewire.log" "$runtime/wireplumber.log"
    exit 1
}
printf 'Isolated PipeWire logs retained at %s\n' "$runtime"
