#!/bin/bash
# Non-mutating system-boundary tests; Darwin also deletes isolated user fixtures.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
bash -n "$root/packaging/client/macos/uninstall.sh"
python3 "$root/scripts/test/check-package-build-paths.py" "$root/packaging/client/macos/uninstall.sh"
# The uninstaller is sealed before distribution signing, not injected later.
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
package = (root / 'scripts/package/build-macos-client-dmg.sh').read_text()
assert package.index('packaging/client/macos/uninstall.sh') < package.index('while IFS= read -r -d')
assert 'chmod 0755 "$app/Contents/Resources/uninstall.sh"' in package
build = (root / 'scripts/build/build-macos-client.sh').read_text()
assert 'tests/packaging/macos-client-uninstall.sh' in build
assert 'tests/packaging/macos-client-paths.cpp' in build
client = root / 'apps/client/app/main.cpp'
if client.is_file():
    main = client.read_text()
    for setter, value in [('OrganizationName', 'Instinctual'), ('OrganizationDomain', 'instinctual.la'),
                          ('ApplicationName', 'PLANK')]:
        assert f'QCoreApplication::set{setter}("{value}")' in main
PY
# Load definitions, never the product entry point. Only the platform/process
# boundaries are replaced; normal execution has no test/root-path overrides.
eval "$(sed -e '$d' -e 's|/usr/bin/uname|uname_cmd|g' -e 's|/usr/bin/pgrep|pgrep_cmd|g' \
    "$root/packaging/client/macos/uninstall.sh")"
uname_cmd() { echo Darwin; }
checks=0
ok() { checks=$((checks+1)); }
reject() { if ( "$@" ) >/dev/null 2>&1; then fail 'Expected rejection'; fi; ok; }
(
    current_uid() { echo 0; }
    verify_client() { calls="$calls|verify"; }
    pgrep_cmd() { [[ $* = '-x plank-client' ]]; return 1; }
    receipt_cmd() {
        case $1 in
            --pkgs) printf '%s\n' la.instinctual.PLANK.Host la.instinctual.PLANK.Client org.example.Unrelated ;;
            --forget) [[ $2 = la.instinctual.PLANK.Client ]]; calls="$calls|forget" ;;
            *) exit 90 ;;
        esac
    }
    remove_cmd() { [[ $* = '-rf /Applications/PLANK Client.app' ]]; calls="$calls|app"; }
    verify_policy() { calls="$calls|policy"; }
    confirm_purge() { calls="$calls|confirm"; }
    run_user_purge() { [[ $SUDO_UID = 502 ]]; calls="$calls|user"; }
    calls=''
    uninstall_client >/dev/null
    [[ $calls = '|verify|verify|app|forget' ]]
    # Default does not touch policies, preferences, logs, Host or any user data.
    calls=''
    present() { [[ $1 = /private/etc/plank/client.conf ]]; }
    remove_cmd() {
        case "$*" in
            '/private/etc/plank/client.conf') calls="$calls|config" ;;
            '-rf /Applications/PLANK Client.app') calls="$calls|app" ;;
            *) exit 90 ;;
        esac
    }
    SUDO_UID=502 uninstall_client --purge >/dev/null
    [[ $calls = '|verify|policy|confirm|user|policy|verify|config|app|forget' ]]
    # Missing receipt is harmless; do not forget another product's receipt.
    receipt_cmd() { [[ $1 = --pkgs ]]; echo la.instinctual.PLANK.Host; }
    calls=''
    uninstall_client >/dev/null
    [[ $calls = '|verify|verify|app' ]]
    remove_cmd() { fail 'Unexpected deletion'; }
    reject uninstall_client --unknown
    reject uninstall_client --purge extra
    reject uninstall_client --purge-user-data extra
    unset SUDO_UID
    reject uninstall_client --purge-user-data
    reject uninstall_client --purge
    SUDO_UID=0 reject uninstall_client --purge
    SUDO_UID=invalid reject uninstall_client --purge
    pgrep_cmd() { return 0; }
    [[ $(uninstall_client 2>&1 || true) = *'Quit PLANK Client'* ]]
    pgrep_cmd() { return 2; }
    [[ $(uninstall_client 2>&1 || true) = *'Cannot check'* ]]
    pgrep_cmd() { return 1; }
    receipt_cmd() { return 1; }
    [[ $(uninstall_client 2>&1 || true) = *'Cannot inspect installer receipts'* ]]
    receipt_cmd() { :; }
    confirm_purge() { fail 'fixture cancelled'; }
    [[ $(SUDO_UID=502 uninstall_client --purge 2>&1 || true) = 'PLANK: fixture cancelled' ]]
    confirm_purge() { :; }
    run_user_purge() { return 1; }
    [[ $(SUDO_UID=502 uninstall_client --purge 2>&1 || true) = *'app was not removed'* ]]
    verify_policy() { fail 'fixture unsafe policy'; }
    [[ $(SUDO_UID=502 uninstall_client --purge 2>&1 || true) = 'PLANK: fixture unsafe policy' ]]
    verify_client() { fail 'fixture invalid signature'; }
    [[ $(uninstall_client 2>&1 || true) = 'PLANK: fixture invalid signature' ]]
    current_uid() { echo 502; }
    [[ $(uninstall_client 2>&1 || true) = *'Run this script with sudo'* ]]
)
ok
# Guard user cleanup cannot run as root or interpret arbitrary options.
(
    current_uid() { echo 0; }
    reject purge_user_data
)
ok

if [[ $(uname -s) = Darwin ]]; then
    (
        fixture=$(mktemp -d /tmp/plank-client-uninstall-test.XXXXXX)
        trap '/bin/rm -rf "$fixture"' EXIT
        fixture_home="$fixture/user"
        mkdir -p "$fixture_home/Library/Preferences" \
            "$fixture_home/Library/Application Support/Instinctual/PLANK/host-trust" \
            "$fixture_home/Library/Caches/Instinctual/PLANK" \
            "$fixture_home/Library/Logs/PLANK/Client" \
            "$fixture_home/Library/Saved Application State/la.instinctual.PLANK.Client.savedState" \
            "$fixture/other-user" "$fixture_home/Library/Application Support/PLANK"
        touch "$fixture_home/Library/Preferences/la.instinctual.PLANK.plist" \
            "$fixture_home/Library/Preferences/la.instinctual.PLANK.Client.plist" \
            "$fixture_home/Library/Preferences/la.instinctual.PLANK.Host.plist" \
            "$fixture_home/Library/Application Support/PLANK/host-state" \
            "$fixture_home/Library/Logs/PLANK/host-desktop.log" "$fixture/other-user/bookmarks"
        ln -s "$fixture/other-user" "$fixture_home/Library/Caches/Instinctual/PLANK/link"
        client_user_home() { echo "$fixture_home"; }
        pgrep_cmd() { return 1; }
        # Never contact the real preference daemon in fixtures.
        defaults_cmd() {
            [[ $1 = delete && ( $2 = la.instinctual.PLANK || $2 = la.instinctual.PLANK.Client ) ]]
            /bin/rm "$fixture_home/Library/Preferences/$2.plist"
        }
        remove_cmd() {
            [[ $1 = -rf && $2 = "$fixture_home/Library/"* && $# = 2 ]]
            /bin/rm -rf "$2"
        }
        purge_user_data >/dev/null
        [[ ! -e "$fixture_home/Library/Application Support/Instinctual/PLANK" &&
           ! -e "$fixture_home/Library/Caches/Instinctual/PLANK" &&
           ! -e "$fixture_home/Library/Logs/PLANK/Client" &&
           ! -e "$fixture_home/Library/Saved Application State/la.instinctual.PLANK.Client.savedState" &&
           ! -e "$fixture_home/Library/Preferences/la.instinctual.PLANK.plist" &&
           ! -e "$fixture_home/Library/Preferences/la.instinctual.PLANK.Client.plist" ]]
        [[ -f "$fixture_home/Library/Preferences/la.instinctual.PLANK.Host.plist" &&
           -f "$fixture_home/Library/Application Support/PLANK/host-state" &&
           -f "$fixture_home/Library/Logs/PLANK/host-desktop.log" &&
           -f "$fixture/other-user/bookmarks" ]]
        purge_user_data >/dev/null # Idempotent when data has already gone.
        # A leaf symlink and a parent symlink both reject before any deletion.
        ln -s "$fixture/other-user" "$fixture_home/Library/Logs/PLANK/Client"
        defaults_cmd() { fail 'Validation must precede any preference deletion'; }
        remove_cmd() { fail 'Validation must precede any deletion'; }
        reject purge_user_data
        /bin/rm "$fixture_home/Library/Logs/PLANK/Client"
        /bin/rmdir "$fixture_home/Library/Caches/Instinctual"
        ln -s "$fixture/other-user" "$fixture_home/Library/Caches/Instinctual"
        reject purge_user_data
        client_user_home() { echo /; }
        reject purge_user_data
        client_user_home() { echo /Users; }
        reject purge_user_data
        client_user_home() { echo "$fixture_home/../other-user"; }
        reject purge_user_data
        [[ -f "$fixture/other-user/bookmarks" ]]
    )
    ok
fi
echo "macos_client_uninstall_groups=$checks pass; no installed app or real user data changed"
