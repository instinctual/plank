#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared by Installer scripts and the signed app's standalone uninstaller.
# No persistent helper or TCC writes.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
umask 077
ulimit -c 0

app='/Applications/PLANK Host.app'
microphone_driver='/Library/Audio/Plug-Ins/HAL/PLANK Microphone.driver'
executable="$app/Contents/MacOS/plank-host"
state='/Library/Application Support/PLANK'
logs='/Library/Logs/PLANK'
machine=la.instinctual.PLANK.Host.machine
desktop=la.instinctual.PLANK.Host.desktop
signin=la.instinctual.PLANK.Host.sign-in
team='@TEAM@'
version='@VERSION@'

fail() { echo "PLANK: $*" >&2; exit 1; }
present() { [[ -e $1 || -L $1 ]]; }

# All writable product paths have root-only writers. Check parents too, not
# just the leaf; /Applications is Apple's root:admin writable exception.
safe_directory() {
    local path=$1 mode owner group
    [[ $path = /* && $path != / ]] || fail "Invalid product directory: $path"
    if [[ ${path%/*} != '' ]]; then safe_directory "${path%/*}"; fi
    [[ -d $path && ! -L $path ]] || fail "Unsafe directory: $path"
    read -r owner group mode < <(/usr/bin/stat -f '%u %g %Lp' "$path")
    [[ $owner = 0 ]] || fail "Directory is not root-owned: $path"
    (( (8#$mode & 0002) == 0 )) || fail "World-writable directory: $path"
    if (( (8#$mode & 0020) != 0 )); then
        [[ $path = /Applications && $group = 80 ]] || fail "Group-writable directory: $path"
    fi
}

safe_file() {
    local path=$1 expected=$2 owner mode links
    safe_directory "${path%/*}"
    [[ -f $path && ! -L $path ]] || fail "Unsafe file: $path"
    read -r owner mode links < <(/usr/bin/stat -f '%u %Lp %l' "$path")
    [[ $owner = 0 && $mode = "$expected" && $links = 1 ]] || fail "Unsafe file metadata: $path"
}

ensure_directory() {
    local path=$1 mode=$2
    safe_directory "${path%/*}"
    if ! present "$path"; then /bin/mkdir -m "$mode" "$path"; fi
    safe_directory "$path"
    [[ $(/usr/bin/stat -f '%Lp' "$path") = "$mode" ]] || fail "Unexpected directory mode: $path"
}

verify_app() {
    local allow_development=${1:-no} requirement
    safe_directory "$app"
    requirement="identifier \"la.instinctual.PLANK.Host\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\" and (certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    if [[ $allow_development = yes ]]; then
        requirement+=' or certificate leaf[field.1.2.840.113635.100.6.1.12] exists'
    fi
    /usr/bin/codesign --verify --strict --all-architectures -R "=$requirement)" "$app"
}

verify_microphone_driver() {
    safe_directory "$microphone_driver"
    safe_file "$microphone_driver/Contents/Info.plist" 644
    safe_file "$microphone_driver/Contents/MacOS/plank-microphone" 755
    /usr/bin/codesign --verify --strict --all-architectures \
        -R "=identifier \"la.instinctual.PLANK.Microphone\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" \
        "$microphone_driver"
}

job_path() {
    if [[ $1 = "$machine" ]]; then echo "/Library/LaunchDaemons/$1.plist";
    else echo "/Library/LaunchAgents/$1.plist"; fi
}

verify_jobs() {
    local label path role
    for label in "$machine" "$desktop" "$signin"; do
        path=$(job_path "$label")
        if ! present "$path"; then continue; fi
        safe_file "$path" 644
        case $label in "$machine") role=--machine;; "$desktop") role=--desktop;; *) role=--sign-in;; esac
        [[ $(/usr/libexec/PlistBuddy -c 'Print :Label' "$path") = "$label" &&
           $(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$path") = "$executable" &&
           $(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$path") = "$role" &&
           $(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$path") = "$machine" ]] || fail "Unrelated launchd entry: $path"
        if /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:3' "$path" >/dev/null 2>&1; then
            fail "Unexpected launchd arguments: $path"
        fi
    done
}

# Inspection errors are not absence. These wrappers also allow non-mutating
# tests to substitute launchd/process state without production test switches.
launchctl_cmd() { /bin/launchctl "$@"; }
process_alive() { /bin/kill -0 "$1" 2>/dev/null; }
pause_drain() { /bin/sleep 0.1; }
missing_job() {
    [[ $2 = *"Could not find service \"${1##*/}\""* || $2 = *'Could not find domain for'* ]]
}
job_state() {
    local job=$1
    if job_output=$(launchctl_cmd print "$job" 2>&1); then return 0; fi
    missing_job "$job" "$job_output" || fail "Cannot inspect $job: $job_output"
    return 1
}
stop_job() {
    local job=$1 pid attempt pending pids='' registered
    if ! job_state "$job"; then return; fi
    pids=$(echo "$job_output" | /usr/bin/awk '$1 == "pid" && $2 == "=" && $3 ~ /^[1-9][0-9]*$/ {print $3}')
    launchctl_cmd bootout "$job" >/dev/null 2>&1 || true
    for ((attempt=0; attempt<200; attempt++)); do
        registered=0
        if job_state "$job"; then
            registered=1
            pid=$(echo "$job_output" | /usr/bin/awk '$1 == "pid" && $2 == "=" && $3 ~ /^[1-9][0-9]*$/ {print $3}')
            pids="$pids $pid"
        fi
        pending=''
        for pid in $pids; do if process_alive "$pid"; then pending="$pending $pid"; fi; done
        pids=$pending
        [[ $registered = 0 && -z $pids ]] && return 0
        pause_drain
    done
    fail "Timed out draining $job; no forced termination or app replacement. Disconnect and retry."
}

gui_domains() {
    local uid output accounts
    accounts=$(/usr/bin/dscl /Search -list /Users UniqueID) || fail 'Cannot enumerate OS users'
    for uid in $(echo "$accounts" | /usr/bin/awk '$NF ~ /^[1-9][0-9]*$/ {print $NF}' | /usr/bin/sort -un); do
        if output=$(launchctl_cmd print "gui/$uid" 2>&1); then echo "gui/$uid";
        elif [[ $output != *'Could not find domain for'* && $output != *'125: Domain does not support specified action'* ]]; then
            fail "Cannot inspect gui/$uid: $output"
        fi
    done
}
console_uid() { /usr/bin/stat -f %u /dev/console; }
open_permission_setup() {
    local uid
    uid=$(console_uid)
    if [[ $uid =~ ^[1-9][0-9]*$ ]]; then
        # Open the signed app as the existing console user, never as root.
        # The app uses normal macOS consent prompts; no TCC writes or reset.
        # The graphical worker shares this bundle ID. Without -n LaunchServices
        # may reactivate that headless worker instead of running the setup UI.
        if ! launchctl_cmd asuser "$uid" /usr/bin/sudo -n -u "#$uid" /usr/bin/open -n "$app"; then
            echo 'PLANK Host installed; open PLANK Host in Applications to complete privacy setup.'
        fi
    else
        echo 'PLANK Host installed at LoginWindow. Log into the Mac and open PLANK Host once for privacy setup.'
    fi
}
stop_roles() {
    local domains domain pids pid attempt pending
    domains=$(gui_domains) || fail 'Cannot enumerate graphical domains'
    if [[ $(console_uid) = 0 ]]; then stop_job "loginwindow/$signin"; fi
    for domain in $domains; do stop_job "$domain/$desktop"; done
    # A retiring root graphical worker may outlive its LoginWindow domain.
    pids=$(/bin/ps -ax -o pid= -o uid= -o command= | /usr/bin/awk -v exe="$executable" \
        '$2 == 0 {pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "");
        if (index($0, exe " --sign-in ") == 1 || index($0, exe " --graphical ") == 1) print pid}')
    for ((attempt=0; attempt<200; attempt++)); do
        pending=''
        for pid in $pids; do if process_alive "$pid"; then pending="$pending $pid"; fi; done
        pids=$pending
        [[ -z $pids ]] && break
        pause_drain
    done
    [[ -z $pids ]] || fail 'Root graphical worker still retiring; retry later'
    stop_job "system/$machine"
}
start_roles() {
    local domains domain
    domains=$(gui_domains) || fail 'Cannot enumerate graphical domains'
    launchctl_cmd bootstrap system "$(job_path "$machine")"
    for domain in $domains; do launchctl_cmd bootstrap "$domain" "$(job_path "$desktop")"; done
    if [[ $(console_uid) = 0 ]]; then launchctl_cmd bootstrap loginwindow "$(job_path "$signin")"; fi
}

check_configuration() {
    local port uuid
    if present "$state/host.plist"; then
        safe_file "$state/host.plist" 644
        /usr/bin/plutil -lint "$state/host.plist" >/dev/null
        [[ $(/usr/bin/plutil -extract Address raw -expect string "$state/host.plist") = 0.0.0.0 ]] || fail 'Host must listen on all interfaces'
        port=$(/usr/bin/plutil -extract Port raw -expect integer "$state/host.plist")
        [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || fail 'Invalid Host port'
        [[ -n $(/usr/bin/plutil -extract Name raw -expect string "$state/host.plist") ]] || fail 'Invalid Host name'
        uuid=$(/usr/bin/plutil -extract UUID raw -expect string "$state/host.plist")
        [[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail 'Invalid Host identity'
    fi
    if present "$state/SignIn"; then
        safe_directory "$state/SignIn"
        [[ $(/usr/bin/stat -f %Lp "$state/SignIn") = 700 ]] || fail 'Identity directory must be private'
        local name
        for name in cert.pem key.pem cert.der key.der; do safe_file "$state/SignIn/$name" 600; done
    fi
}
preflight() {
    [[ $(/usr/bin/id -u) = 0 && ${1:-} = / ]] || fail 'Administrator privileges on the running system volume are required'
    [[ $(/usr/bin/uname -m) = arm64 && $(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1) -ge 27 ]] || fail 'Requires Apple Silicon and macOS 27 or newer'
    safe_directory /Applications
    safe_directory /Library/LaunchDaemons
    safe_directory /Library/LaunchAgents
    verify_jobs
    if present "$app"; then verify_app yes; fi
    if present "$microphone_driver"; then verify_microphone_driver; fi
    if present "$state"; then safe_directory "$state"; check_configuration; fi
}

# Validate every existing log before changing anything. Allow administrator
# reads, with root-only writes, only on root-owned product objects;
# never follow links, chmod recursively, or take ownership of someone else's file.
prepare_logs() {
    local name mode
    safe_directory "${logs%/*}"
    if present "$logs"; then
        safe_directory "$logs"
        for name in host-machine.log host-sign-in.log; do
            if present "$logs/$name"; then
                mode=$(/usr/bin/stat -f %Lp "$logs/$name")
                safe_file "$logs/$name" "$mode"
                (( (8#$mode & 07022) == 0 )) || fail "Unsafe log permissions: $logs/$name"
            fi
        done
    else
        ensure_directory "$logs" 700
    fi
    for name in host-machine.log host-sign-in.log; do
        if ! present "$logs/$name"; then (set -C; : > "$logs/$name"); fi
        /usr/sbin/chown root:admin "$logs/$name"
        /bin/chmod 640 "$logs/$name"
        safe_file "$logs/$name" 640
    done
    /usr/sbin/chown root:admin "$logs"
    /bin/chmod 750 "$logs"
    ensure_directory "$logs" 750
}

initialize_state() {
    local stage name
    ensure_directory "$state" 755
    if ! present "$state/host.plist"; then
        stage=$(/usr/bin/mktemp "$state/.config.XXXXXX")
        /usr/bin/plutil -create xml1 "$stage"
        /usr/bin/plutil -insert Address -string 0.0.0.0 "$stage"
        /usr/bin/plutil -insert Port -integer 28989 "$stage"
        /usr/bin/plutil -insert Name -string 'PLANK Mac Host' "$stage"
        /usr/bin/plutil -insert UUID -string "$(/usr/bin/uuidgen)" "$stage"
        /bin/chmod 644 "$stage"
        /bin/mv "$stage" "$state/host.plist"
    fi
    if ! present "$state/SignIn"; then
        stage=$(/usr/bin/mktemp -d "$state/.identity.XXXXXX")
        /usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
            -subj '/CN=PLANK Host Machine' -addext subjectAltName=DNS:plank-host \
            -addext basicConstraints=critical,CA:TRUE,pathlen:0 \
            -addext keyUsage=critical,digitalSignature,keyCertSign \
            -keyout "$stage/initial.pem" -out "$stage/cert.pem"
        /usr/bin/openssl rsa -in "$stage/initial.pem" -out "$stage/key.pem"
        /usr/bin/openssl rsa -in "$stage/key.pem" -outform DER -out "$stage/key.der"
        /usr/bin/openssl x509 -in "$stage/cert.pem" -outform DER -out "$stage/cert.der"
        /bin/rm "$stage/initial.pem"
        for name in cert.pem key.pem cert.der key.der; do /bin/chmod 600 "$stage/$name"; done
        /bin/mv "$stage" "$state/SignIn"
    fi
    check_configuration
    prepare_logs
}

# Run after the old roles have stopped. Upgrade/renew the certificate, not the
# machine key: Client trust is an SPKI fingerprint, independent of expiry,
# certificate serial and which user currently owns the desktop.
prepare_machine_authority() {
    local certificate="$state/SignIn/cert.pem" key="$state/SignIn/key.pem" stage text key_public cert_public
    check_configuration
    # Validate the retained key even when the certificate looks current. A
    # damaged key must never trigger silent replacement of the machine identity.
    /usr/bin/openssl rsa -in "$key" -check -noout >/dev/null 2>&1 || fail 'Invalid machine identity key; it was not replaced'
    key_public=$(/usr/bin/openssl rsa -in "$key" -noout -modulus 2>/dev/null)
    cert_public=$(/usr/bin/openssl x509 -in "$certificate" -noout -modulus 2>/dev/null) || cert_public=''
    text=$(/usr/bin/openssl x509 -in "$certificate" -noout -text 2>/dev/null) || text=''
    if [[ $text = *'CA:TRUE, pathlen:0'* && $text = *'PLANK Host Machine'* ]] &&
        /usr/bin/openssl x509 -in "$certificate" -noout -checkend 2592000 >/dev/null 2>&1 &&
        /usr/bin/openssl verify -CAfile "$certificate" "$certificate" >/dev/null 2>&1 &&
        [[ -n $key_public && $key_public = "$cert_public" ]] &&
        /usr/bin/cmp -s <(/usr/bin/openssl x509 -in "$certificate" -outform DER) "$state/SignIn/cert.der"; then
        return
    fi
    stage=$(/usr/bin/mktemp -d "$state/SignIn/.renew.XXXXXX")
    /usr/bin/openssl req -new -x509 -key "$key" -sha256 -days 3650 \
        -subj '/CN=PLANK Host Machine' -addext subjectAltName=DNS:plank-host \
        -addext basicConstraints=critical,CA:TRUE,pathlen:0 \
        -addext keyUsage=critical,digitalSignature,keyCertSign -out "$stage/cert.pem"
    /usr/bin/openssl x509 -in "$stage/cert.pem" -outform DER -out "$stage/cert.der"
    /bin/chmod 600 "$stage/cert.pem" "$stage/cert.der"
    /bin/mv "$stage/cert.pem" "$certificate"
    /bin/mv "$stage/cert.der" "$state/SignIn/cert.der"
    /bin/rmdir "$stage"
}
