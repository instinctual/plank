#!/bin/bash
# Non-mutating lifecycle tests. --filesystem adds an isolated root-owned fixture.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/packaging/host/macos/pkg-common.sh"
checks=0
ok() { checks=$((checks+1)); }
reject() { if ( "$@" ) >/dev/null 2>&1; then fail "Expected rejection: $*"; fi; ok; }
for script in pkg-common.sh pkg-preinstall pkg-postinstall uninstall.sh; do
    /bin/bash -n "$root/packaging/host/macos/$script"; ok
done
# Exercise the exact uninstall entry point with destructive commands replaced
# only in this fixture. Never execute the product uninstaller in these tests.
(
    # Bash 3.2 on macOS can return early when sourcing a process-substitution
    # pipe. Read the complete trusted fixture before defining its function.
    eval "$(/usr/bin/sed -e '$d' -e 's|/bin/rm|remove_cmd|g' \
        -e 's|/usr/bin/systemextensionsctl|extension_cmd|g' \
        -e 's|/usr/sbin/pkgutil|receipt_cmd|g' "$root/packaging/host/macos/uninstall.sh")"
    calls=''
    preflight() { [[ $1 = / ]]; calls="$calls|preflight"; }
    stop_roles() { calls="$calls|stop"; }
    present() { return 0; }
    verify_app() { [[ $1 = yes ]]; calls="$calls|verify"; }
    verify_microphone_driver() { calls="$calls|verify-microphone"; }
    verify_output_driver() { calls="$calls|verify-output"; }
    remove_cmd() { calls="$calls|remove:$*"; }
    receipt_cmd() { calls="$calls|receipt:$*"; }
    extension_cmd() { [[ $1 = list ]]; }
    reject uninstall_host unexpected-argument
    uninstall_host >/dev/null
    [[ $calls = "|preflight|stop|verify-microphone|remove:-rf /Library/Audio/Plug-Ins/HAL/PLANK Microphone.driver|verify-output|remove:-rf /Library/Audio/Plug-Ins/HAL/PLANK Output.driver|remove:/Library/LaunchDaemons/$machine.plist|remove:/Library/LaunchAgents/$desktop.plist|remove:/Library/LaunchAgents/$signin.plist|verify|remove:-rf /Applications/PLANK Host.app|receipt:--pkg-info la.instinctual.PLANK.Host|receipt:--forget la.instinctual.PLANK.Host" ]]
    # Never remove anything when preflight or bounded shutdown fails.
    remove_cmd() { echo 'unexpected removal'; exit 90; }
    extension_cmd() { echo 'la.instinctual.PLANK.Host.Camera'; }
    reject uninstall_host
    extension_cmd() { return 1; }
    reject uninstall_host
    extension_cmd() { :; }
    preflight() { fail 'fixture unsafe metadata'; }
    [[ $(uninstall_host 2>&1 || true) = 'PLANK: fixture unsafe metadata' ]]
    preflight() { :; }
    stop_roles() { fail 'fixture drain timeout'; }
    [[ $(uninstall_host 2>&1 || true) = 'PLANK: fixture drain timeout' ]]
)
ok
[[ ! -e "$root/packaging/host/macos/pkg-uninstall" && ! -e "$root/packaging/host/macos/uninstall.html" ]]
ok
! grep -q 'uninstall-component\|uninstall-scripts\|plank-host-uninstall_' "$root/scripts/package/build-macos-host-pkg.sh"
ok
/usr/bin/awk '/^initialize_state$/ {prepared=1} /^stop_roles$/ {if (!prepared) exit 1; found=1} END {if (!found) exit 1}' \
    "$root/packaging/host/macos/pkg-preinstall"
ok
missing_job system/example 'Could not find service "example" in domain for system'; ok
missing_job gui/501/example 'Could not find domain for'; ok
reject missing_job system/example 'Could not find service "unrelated"'
reject missing_job system/example 'Operation not permitted'
reject preflight /Volumes/Other

# Test actual job_state failure handling; never invoke launchctl.
(
    launchctl_cmd() { echo 'Operation not permitted'; return 1; }
    reject job_state system/example
)
ok
(
    launchctl_cmd() { echo 'Could not find service "example"'; return 1; }
    if job_state system/example; then fail 'Missing job accepted as present'; fi
)
ok

(
    step=0; bootouts=0; sleeps=0
    launchctl_cmd() { [[ $1 = bootout ]]; bootouts=$((bootouts+1)); }
    pause_drain() { sleeps=$((sleeps+1)); }
    # launchd has removed the job, but its process is still retiring.
    job_state() {
        step=$((step+1)); job_output=' pid = 12345'
        [[ $step = 1 ]]
    }
    process_alive() { [[ $1 = 12345 && $step -lt 5 ]]; }
    stop_job system/example
    [[ $step = 5 && $bootouts = 1 && $sleeps = 3 ]]
)
ok
(
    job_state() { job_output=' pid = 12345'; return 0; }
    launchctl_cmd() { :; }
    process_alive() { return 0; }
    pause_drain() { :; }
    reject stop_job system/example
)
ok
(
    job_state() { return 1; }
    launchctl_cmd() { fail 'Absent job should not be stopped'; }
    stop_job system/example
)
ok
(
    gui_domains() { echo gui/501; echo gui/502; }
    console_uid() { echo 501; }
    calls=''
    launchctl_cmd() { calls="$calls|$*"; }
    start_roles
    [[ $calls = "|bootstrap system /Library/LaunchDaemons/$machine.plist|bootstrap gui/501 /Library/LaunchAgents/$desktop.plist|bootstrap gui/502 /Library/LaunchAgents/$desktop.plist" ]]
)
ok
(
    gui_domains() { :; }
    console_uid() { echo 0; }
    calls=''
    launchctl_cmd() { calls="$calls|$*"; }
    start_roles
    [[ $calls = "|bootstrap system /Library/LaunchDaemons/$machine.plist|bootstrap loginwindow /Library/LaunchAgents/$signin.plist" ]]
)
ok

(
    console_uid() { echo 502; }
    calls=''
    launchctl_cmd() { calls="$*"; }
    open_permission_setup
    [[ $calls = "asuser 502 /usr/bin/sudo -n -u #502 /usr/bin/open -n $app" ]]
)
ok
(
    console_uid() { echo 0; }
    launchctl_cmd() { fail 'Must not open permission UI as root at LoginWindow'; }
    [[ $(open_permission_setup) = *'Log into the Mac'* ]]
)
ok
(
    console_uid() { echo 502; }
    launchctl_cmd() { return 1; }
    [[ $(open_permission_setup) = *'open PLANK Host in Applications'* ]]
)
ok

if [[ $(uname -s) = Darwin ]]; then
    for role in machine desktop sign-in; do
        plist="$root/packaging/host/macos/la.instinctual.PLANK.Host.$role.plist"
        /usr/bin/plutil -lint "$plist" >/dev/null
        [[ $(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist") = "$executable" ]]
        ok
        [[ $(/usr/bin/plutil -extract AssociatedBundleIdentifiers raw -expect array "$plist") = 1 ]]
        [[ $(/usr/bin/plutil -extract AssociatedBundleIdentifiers.0 raw -expect string "$plist") = \
           "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$root/packaging/host/macos/host-info.plist")" ]]
        ok
    done
fi

if [[ ${1:-} = --filesystem ]]; then
    [[ $(uname -s) = Darwin && $(id -u) = 0 ]] || fail 'Filesystem fixture requires root on an authorized Mac builder'
    fixture=$(/usr/bin/mktemp -d '/Library/Application Support/PLANKPackageTest.XXXXXX')
    cleanup() {
        case $fixture in '/Library/Application Support/PLANKPackageTest.'*) /bin/rm -rf "$fixture";; esac
    }
    trap cleanup EXIT
    /bin/chmod 755 "$fixture"
    /usr/bin/cc -std=gnu11 -Wall -Wextra -Werror \
        "$root/tests/packaging/macos-log-access.c" -o "$fixture/log-access"
    state="$fixture/state"; logs="$fixture/logs"
    initialize_state
    prepare_machine_authority
    [[ $(/usr/bin/stat -f '%Su:%Lp' "$state") = root:755 ]]; ok
    [[ $(/usr/bin/stat -f '%Su:%Lp' "$state/OutputRouting") = root:700 ]]; ok
    # Reproduce the shared-parent/private-journal mismatch and reject unsafe
    # pre-existing routing storage instead of broadening its access.
    /bin/chmod 755 "$state/OutputRouting"
    reject initialize_state
    /bin/chmod 700 "$state/OutputRouting"
    /bin/rmdir "$state/OutputRouting"
    /bin/ln -s "$state/SignIn" "$state/OutputRouting"
    reject initialize_state
    /bin/rm "$state/OutputRouting"
    initialize_state
    [[ $(/usr/bin/stat -f '%Su:%Lp' "$state/OutputRouting") = root:700 ]]; ok
    [[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$logs") = root:admin:750 ]]; ok
    for name in host-machine.log host-sign-in.log; do
        [[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$logs/$name") = root:admin:640 ]]; ok
        "$fixture/log-access" "$logs" "$logs/$name" "$state/SignIn/key.pem" admin; ok
        "$fixture/log-access" "$logs" "$logs/$name" "$state/SignIn/key.pem" wheel; ok
    done
    [[ $(/usr/libexec/PlistBuddy -c 'Print :Address' "$state/host.plist") = 0.0.0.0 ]]; ok
    [[ $(/usr/libexec/PlistBuddy -c 'Print :Port' "$state/host.plist") = 28989 ]]; ok
    /usr/bin/plutil -replace Port -integer 29999 "$state/host.plist"
    before=$(/usr/bin/shasum -a 256 "$state/host.plist" "$state/SignIn/"* "$logs/"*)
    initialize_state
    after=$(/usr/bin/shasum -a 256 "$state/host.plist" "$state/SignIn/"* "$logs/"*)
    [[ $before = "$after" ]]; ok
    # Renewal and the CA-profile upgrade retain the machine private key. No
    # root key is copied to desktop users, and a second install is idempotent.
    machine_key_before=$(/usr/bin/shasum -a 256 "$state/SignIn/key.pem" "$state/SignIn/key.der")
    /usr/bin/openssl req -new -x509 -key "$state/SignIn/key.pem" -days 1 \
        -subj '/CN=PLANK Host' -addext subjectAltName=DNS:plank-host -out "$state/SignIn/cert.pem"
    prepare_machine_authority
    /usr/bin/openssl x509 -in "$state/SignIn/cert.pem" -noout -checkend 2592000; ok
    [[ $machine_key_before = "$(/usr/bin/shasum -a 256 "$state/SignIn/key.pem" "$state/SignIn/key.der")" ]]; ok
    before=$(/usr/bin/shasum -a 256 "$state/host.plist" "$state/SignIn/"* "$logs/"*)
    prepare_machine_authority
    [[ $before = "$(/usr/bin/shasum -a 256 "$state/host.plist" "$state/SignIn/"* "$logs/"*)" ]]; ok
    # An interrupted certificate-pair update must be repaired on reinstall.
    printf 'damaged DER fixture' > "$state/SignIn/cert.der"
    prepare_machine_authority
    /usr/bin/cmp -s <(/usr/bin/openssl x509 -in "$state/SignIn/cert.pem" -outform DER) "$state/SignIn/cert.der"; ok
    [[ $machine_key_before = "$(/usr/bin/shasum -a 256 "$state/SignIn/key.pem" "$state/SignIn/key.der")" ]]; ok
    before=$(/usr/bin/shasum -a 256 "$state/host.plist" "$state/SignIn/"* "$logs/"*)
    # Reproduce the real .82 failure without changing product paths/services.
    /bin/chmod 744 "$logs"
    /bin/chmod 644 "$logs/host-machine.log" "$logs/host-sign-in.log"
    initialize_state
    [[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$logs") = root:admin:750 ]]; ok
    safe_file "$logs/host-machine.log" 640; ok
    safe_file "$logs/host-sign-in.log" 640; ok
    [[ $before = "$(/usr/bin/shasum -a 256 "$state/host.plist" "$state/SignIn/"* "$logs/"*)" ]]; ok
    # Upgrade the previous root-only policy without changing contents or keys.
    /usr/sbin/chown root:wheel "$logs" "$logs/host-machine.log" "$logs/host-sign-in.log"
    /bin/chmod 700 "$logs"
    /bin/chmod 600 "$logs/host-machine.log" "$logs/host-sign-in.log"
    initialize_state
    [[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$logs") = root:admin:750 ]]; ok
    for name in host-machine.log host-sign-in.log; do
        [[ $(/usr/bin/stat -f '%Su:%Sg:%Lp' "$logs/$name") = root:admin:640 ]]; ok
    done
    check_configuration; ok
    [[ $before = "$(/usr/bin/shasum -a 256 "$state/host.plist" "$state/SignIn/"* "$logs/"*)" ]]; ok
    /bin/chmod 660 "$logs/host-sign-in.log"
    reject prepare_logs
    /bin/chmod 640 "$logs/host-sign-in.log"
    /bin/chmod 770 "$logs"
    reject prepare_logs
    /bin/chmod 750 "$logs"
    /bin/ln "$logs/host-machine.log" "$fixture/log-hardlink"
    reject prepare_logs
    /bin/rm "$fixture/log-hardlink"
    /bin/chmod 666 "$logs/host-machine.log"
    reject prepare_logs
    /bin/chmod 600 "$logs/host-machine.log"
    /usr/sbin/chown nobody "$logs/host-machine.log"
    reject prepare_logs
    /usr/sbin/chown root "$logs/host-machine.log"
    /bin/ln -s "$state/host.plist" "$fixture/symlink"
    reject safe_file "$fixture/symlink" 644
    /bin/ln "$state/host.plist" "$fixture/hardlink"
    reject safe_file "$state/host.plist" 644
    /bin/rm "$fixture/hardlink"
    /bin/chmod 666 "$state/host.plist"
    reject check_configuration
    /bin/chmod 644 "$state/host.plist"
    /bin/ln -s "$state" "$fixture/directory-link"
    reject safe_directory "$fixture/directory-link"
    /bin/chmod 777 "$logs"
    reject initialize_state
    /bin/chmod 700 "$logs"
    /bin/rm "$logs/host-machine.log"
    /bin/ln -s "$fixture/not-a-log" "$logs/host-machine.log"
    reject initialize_state
    [[ ! -e $fixture/not-a-log ]]; ok
fi
echo "macos_pkg_scripts_checks=$checks pass; no product services changed"
