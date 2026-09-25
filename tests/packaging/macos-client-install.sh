#!/bin/bash
# Execute real handoff logic with OS commands replaced; no install or launch.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
/bin/bash -n "$root/packaging/client/macos/pkg-postinstall"
eval "$(/usr/bin/sed '$d' "$root/packaging/client/macos/pkg-postinstall")"
client_running() { [[ $1 = 502 ]] || exit 90; return 1; }
(
    console_uid() { echo 502; }
    calls=''
    launchctl_cmd() { calls="$calls|$*"; }
    open_permission_setup
    [[ $calls = '|print gui/502|asuser 502 /usr/bin/sudo -n -u #502 /usr/bin/open -n /Applications/PLANK Client.app --args --setup-permissions' ]]
)
(
    launchctl_cmd() { echo 'Unexpected launch' >&2; exit 90; }
    for test_uid in 0 '' invalid -1; do
        console_uid() { echo "$test_uid"; }
        [[ $(open_permission_setup) = *'Permission setup is pending'* ]]
    done
    console_uid() { return 1; }
    [[ $(open_permission_setup) = *'Permission setup is pending'* ]]
)
(
    console_uid() { echo 502; }
    launchctl_cmd() { [[ $1 = print ]] || exit 90; return 1; }
    [[ $(open_permission_setup) = *'Permission setup is pending'* ]]
)
(
    console_uid() { echo 502; }
    launchctl_cmd() { [[ $1 = print ]]; }
    [[ $(open_permission_setup) = *'Open PLANK Client to complete permission setup'* ]]
)
(
    console_uid() { echo 502; }
    launchctl_cmd() { [[ $1 = print ]] || exit 90; }
    for process_status in 0 2; do
        client_running() { return "$process_status"; }
        [[ $(open_permission_setup) = *'Quit PLANK Client, then reopen it'* ]]
    done
)
echo 'Client install: user-scoped handoff, absent desktop, running-client guard, lookup and launch failure passed'
