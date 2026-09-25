#!/bin/bash
# Build appends this entry point to the shared lifecycle functions before
# signing the application. No sourced helper, Python or separate PKG required.
# Parse the entire function before removing the app containing this script.
camera_extensions() { /usr/bin/systemextensionsctl list; }
remove_camera() {
    local extensions uid result attempt
    extensions=$(camera_extensions) || fail 'Cannot inspect installed camera extensions; Host was not removed.'
    [[ $extensions = *'la.instinctual.PLANK.Host.Camera'* ]] || return 0
    present "$app" || fail 'The signed PLANK Host app is required to remove its camera extension; reinstall Host, then retry uninstall.'
    uid=$(console_uid) || fail 'Cannot determine the console user; Host was not removed.'
    [[ $uid =~ ^[1-9][0-9]*$ ]] || fail 'Log into the Mac desktop and run uninstall again to approve camera removal. Host was not removed.'
    launchctl_cmd print "gui/$uid" >/dev/null 2>&1 || fail 'No active desktop for camera removal; Host was not removed.'
    echo 'Removing PLANK Camera. Approve the macOS prompt if one appears on the Mac desktop.'
    # The signed containing app submits the supported SystemExtensions request
    # as the console user. asuser alone changes the bootstrap domain, not UID.
    # Direct execution waits for the real result; open would only confirm launch.
    result=0
    launchctl_cmd asuser "$uid" /usr/bin/sudo -n -u "#$uid" "$executable" --disable-camera || result=$?
    case $result in
        0) ;;
        2) fail 'macOS requires a restart to finish removing PLANK Camera. Restart when ready, then run this same uninstall command again. Host was not removed.' ;;
        *) fail 'Camera removal did not complete. Host was not removed; approve removal on the Mac desktop and retry uninstall.' ;;
    esac
    # Allow the system registry to settle, but never mistake successful request
    # submission for completed removal. A pending restart still retains the app.
    for ((attempt=0; attempt<50; attempt++)); do
        extensions=$(camera_extensions) || fail 'Cannot verify camera removal; Host was not removed.'
        [[ $extensions = *'la.instinctual.PLANK.Host.Camera'* ]] || return 0
        pause_drain
    done
    fail 'PLANK Camera is still registered. Restart when ready, then run this same uninstall command again. Host was not removed.'
}
uninstall_host() {
    local label path
    [[ $# = 0 ]] || fail 'Usage: sudo "/Applications/PLANK Host.app/Contents/Resources/uninstall.sh"'
    preflight /
    # The OS owns registered system extensions. Keep the signed containing app
    # available until the user-authorized deactivation is complete.
    remove_camera
    stop_roles
    if present "$microphone_driver"; then
        verify_microphone_driver
        /bin/rm -rf '/Library/Audio/Plug-Ins/HAL/PLANK Microphone.driver'
    fi
    if present "$output_driver"; then
        verify_output_driver
        /bin/rm -rf '/Library/Audio/Plug-Ins/HAL/PLANK Output.driver'
    fi
    for label in "$machine" "$desktop" "$signin"; do
        path=$(job_path "$label")
        if present "$path"; then /bin/rm "$path"; fi
    done
    if present "$app"; then
        verify_app yes
        /bin/rm -rf '/Applications/PLANK Host.app'
    fi
    if /usr/sbin/pkgutil --pkg-info la.instinctual.PLANK.Host >/dev/null 2>&1; then
        /usr/sbin/pkgutil --forget la.instinctual.PLANK.Host
    fi
    echo 'PLANK Host removed. Configuration, certificates, logs and privacy permissions preserved. Restart the Mac to unload the PLANK audio devices.'
}
uninstall_host "$@"
