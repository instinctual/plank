#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Standalone script inside the signed distribution app. No installed helper.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
umask 077
client_app='/Applications/PLANK Client.app'
client_script="$client_app/Contents/Resources/uninstall.sh"
client_policy='/private/etc/plank/client.conf'
client_receipt='la.instinctual.PLANK.Client'
client_team='@TEAM@'

fail() { echo "PLANK: $*" >&2; exit 1; }
present() { [[ -e $1 || -L $1 ]]; }
current_uid() { /usr/bin/id -u; }
remove_cmd() { /bin/rm "$@"; }
defaults_cmd() { /usr/bin/defaults "$@"; }
receipt_cmd() { /usr/sbin/pkgutil "$@"; }

require_quit() {
    local result=0
    /usr/bin/pgrep -x plank-client >/dev/null || result=$?
    [[ $result = 1 ]] || {
        [[ $result = 0 ]] && fail 'Quit PLANK Client in all user sessions before uninstalling. No process was terminated.'
        fail 'Cannot check whether PLANK Client is running.'
    }
}

safe_system_directory() {
    local path=$1 owner group mode
    [[ $path = / ]] && return 0
    [[ $path = /* ]] || fail 'Invalid system path.'
    if [[ -n ${path%/*} ]]; then safe_system_directory "${path%/*}"; fi
    [[ -d $path && ! -L $path ]] || fail "Unsafe directory: $path"
    read -r owner group mode < <(/usr/bin/stat -f '%u %g %Lp' "$path")
    [[ $owner = 0 ]] && (( (8#$mode & 0002) == 0 )) || fail "Unsafe directory ownership/mode: $path"
    if (( (8#$mode & 0020) != 0 )); then
        [[ $path = /Applications && $group = 80 ]] || fail "Group-writable directory: $path"
    fi
}

verify_client() {
    safe_system_directory "$client_app"
    [[ $client_team =~ ^[A-Z0-9]{10}$ ]] || fail 'Invalid signing team in uninstaller.'
    /usr/bin/codesign --verify --strict --all-architectures \
        -R "=identifier \"la.instinctual.PLANK.Client\" and anchor apple generic and certificate leaf[subject.OU] = \"$client_team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" \
        "$client_app" || fail 'Client signature verification failed; nothing was removed.'
}

verify_policy() {
    if present /private/etc/plank; then safe_system_directory /private/etc/plank; fi
    if present "$client_policy"; then
        [[ -f $client_policy && ! -L $client_policy ]] || fail 'Unsafe Client configuration file.'
        local owner mode links
        read -r owner mode links < <(/usr/bin/stat -f '%u %Lp %l' "$client_policy")
        [[ $owner = 0 && $mode = 644 && $links = 1 ]] || fail 'Unsafe Client configuration metadata.'
    fi
}

# Never use root's HOME or walk other users' homes. This phase runs without
# administrator privileges, in a separate invocation of the signed script.
client_user_home() {
    local record
    record=$(/usr/bin/dscl /Search -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory) || fail 'Cannot find your account home directory.'
    [[ $record = 'NFSHomeDirectory: /'* ]] || fail 'Invalid account home directory.'
    printf '%s\n' "${record#NFSHomeDirectory: }"
}

validate_user_path() {
    local path=${1%/} parent
    [[ $path = "$client_home/Library" || $path = "$client_home/Library/"* ]] || fail 'Refusing a path outside Client user data.'
    parent=${path%/*}
    if [[ $parent != "$client_home" ]]; then validate_user_path "$parent"; fi
    if present "$path"; then
        [[ ! -L $path && ( -d $path || -f $path ) && $(/usr/bin/stat -f %u "$path") = "$client_uid" ]] || fail "Unsafe Client user-data path: $path"
    fi
}

purge_user_data() {
    local client_uid client_home path domain
    client_uid=$(current_uid)
    [[ $client_uid =~ ^[1-9][0-9]*$ ]] || fail 'User data must never be removed as root.'
    client_home=$(client_user_home) || fail 'Cannot resolve Client user data.'
    [[ $client_home = /* && $client_home != / && $client_home != /Users &&
       $client_home != /var/root && $client_home != /private/var/root &&
       $client_home != *'/../'* && $client_home != */.. && $client_home != *'/./'* &&
       $client_home != */. && $client_home != */ && $client_home != *$'\n'* &&
       -d $client_home && ! -L $client_home && $(/usr/bin/stat -f %u "$client_home") = "$client_uid" ]] || fail 'Unsafe account home directory.'
    local paths=(
        "$client_home/Library/Preferences/la.instinctual.PLANK.plist"
        "$client_home/Library/Preferences/la.instinctual.PLANK.Client.plist"
        "$client_home/Library/Application Support/Instinctual/PLANK"
        "$client_home/Library/Caches/Instinctual/PLANK"
        "$client_home/Library/Logs/PLANK/Client"
        "$client_home/Library/Saved Application State/la.instinctual.PLANK.Client.savedState"
    )
    require_quit
    # Validate every exact target before the first deletion. rm never follows
    # nested symlinks; running as the user also limits any concurrent path race.
    for path in "${paths[@]}"; do validate_user_path "$path"; done
    for domain in la.instinctual.PLANK la.instinctual.PLANK.Client; do
        path="$client_home/Library/Preferences/$domain.plist"
        if present "$path"; then
            defaults_cmd delete "$domain" || fail 'Could not clear Client preferences; uninstall stopped.'
        fi
    done
    for path in "${paths[@]}"; do
        if present "$path"; then remove_cmd -rf "$path"; fi
    done
    echo 'Removed your Client bookmarks, preferences, trusted Hosts, caches and logs.'
}

confirm_purge() {
    local answer
    echo 'WARNING: --purge permanently removes client.conf and YOUR Client bookmarks, preferences, trusted Hosts, caches and logs.'
    echo 'Other users, Host files and macOS privacy permissions are not changed.'
    printf 'Type DELETE to continue: ' > /dev/tty
    read -r answer < /dev/tty || fail 'Confirmation required; nothing was removed.'
    [[ $answer = DELETE ]] || fail 'Cancelled; nothing was removed.'
}

run_user_purge() {
    /usr/bin/sudo -H -n -u "#$SUDO_UID" "$client_script" --purge-user-data
}

uninstall_client() {
    local purge=0 receipts
    [[ $(/usr/bin/uname -s) = Darwin ]] || fail 'This uninstaller is for macOS.'
    case "${1:-}" in
        '') [[ $# = 0 ]] || fail 'Invalid arguments.' ;;
        --purge) [[ $# = 1 ]] || fail 'Invalid arguments.'; purge=1 ;;
        --purge-user-data)
            [[ $# = 1 && ${SUDO_UID:-} = 0 ]] || fail 'Internal user-data phase; use sudo uninstall.sh --purge.'
            purge_user_data; return ;;
        *) fail 'Usage: sudo "/Applications/PLANK Client.app/Contents/Resources/uninstall.sh" [--purge]' ;;
    esac
    [[ $(current_uid) = 0 ]] || fail 'Run this script with sudo.'
    verify_client
    require_quit
    receipts=$(receipt_cmd --pkgs) || fail 'Cannot inspect installer receipts; nothing was removed.'
    if [[ $purge = 1 ]]; then
        [[ ${SUDO_UID:-} =~ ^[1-9][0-9]*$ ]] || fail 'Run sudo from your own account to purge only your Client data.'
        verify_policy
        confirm_purge
        run_user_purge || fail 'Client data cleanup failed; the app was not removed.'
        verify_policy
    fi
    require_quit
    verify_client
    if [[ $purge = 1 ]] && present "$client_policy"; then remove_cmd '/private/etc/plank/client.conf'; fi
    remove_cmd -rf '/Applications/PLANK Client.app'
    case $'\n'$receipts$'\n' in
        *$'\n'la.instinctual.PLANK.Client$'\n'*) receipt_cmd --forget la.instinctual.PLANK.Client ;;
    esac
    if [[ $purge = 0 ]]; then echo 'PLANK Client removed. Configuration and user data preserved.';
    else echo 'PLANK Client removed with Client configuration and your user data. Other users and Host files preserved.'; fi
    echo 'No restart required. macOS privacy permissions were not reset.'
}
uninstall_client "$@"
