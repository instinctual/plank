#!/bin/bash
# Build appends this entry point to the shared lifecycle functions before
# signing the application. No sourced helper, Python or separate PKG required.
# Parse the entire function before removing the app containing this script.
uninstall_host() {
    local label path
    [[ $# = 0 ]] || fail 'Usage: sudo "/Applications/PLANK Host.app/Contents/Resources/uninstall.sh"'
    preflight /
    stop_roles
    if present "$microphone_driver"; then
        verify_microphone_driver
        /bin/rm -rf '/Library/Audio/Plug-Ins/HAL/PLANK Microphone.driver'
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
    echo 'PLANK Host removed. Configuration, certificates, logs and privacy permissions preserved. Restart the Mac to unload PLANK Microphone; it remains silent until then.'
}
uninstall_host "$@"
