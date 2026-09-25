#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
unit=${repo_dir}/packaging/host/linux/systemd/plank-host.service
pam_unit=${repo_dir}/packaging/host/linux/systemd/plank-pam-broker.service
display_unit=${repo_dir}/packaging/host/linux/systemd/plank-display-prepare.service
pam_policy=${repo_dir}/packaging/host/linux/pam/plank-host
host_wacom_rule=${repo_dir}/packaging/host/linux/udev/70-plank-host-wacom.rules
spec=${repo_dir}/packaging/host/linux/rpm/plank-host.spec
builder=${repo_dir}/scripts/package/build-host-rpm.sh
firewalld_service=${repo_dir}/packaging/host/linux/firewalld/plank.xml
logrotate_policy=${repo_dir}/packaging/host/linux/logrotate/plank-host

rg -Fxq 'ExecStart=/usr/libexec/plank/plank-host-supervisor' "$unit"
rg -Fxq 'WantedBy=multi-user.target' "$unit"
if rg -q '^EnvironmentFile=' "$unit"; then
  echo 'host service still loads a second environment configuration file' >&2
  exit 1
fi
rg -Fxq 'NoNewPrivileges=yes' "$unit"
rg -Fxq 'CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SYS_PTRACE' "$unit"
rg -Fxq 'ProtectHome=read-only' "$unit"
rg -Fxq 'RuntimeDirectory=plank/host' "$unit"
rg -Fxq 'RuntimeDirectoryMode=0700' "$unit"
rg -Fxq 'LogsDirectory=plank' "$unit"
rg -Fxq 'LogsDirectoryMode=0700' "$unit"
rg -Fxq 'StandardOutput=append:/var/log/plank/host-supervisor.log' "$unit"
rg -Fxq 'StandardError=append:/var/log/plank/host-supervisor.log' "$unit"
if rg -q '47990' "$firewalld_service"; then
  echo 'firewalld service still exposes the removed Web UI port' >&2
  exit 1
fi
rg -Fxq '  <port protocol="tcp" port="28989"/>' "$firewalld_service"
rg -Fxq '  <port protocol="udp" port="28989"/>' "$firewalld_service"
if rg -q '47984|47989|48010|47998|47999|48000' "$firewalld_service"; then
  echo "retired PLANK port remains in firewalld service" >&2
  exit 1
fi
rg -Fxq 'RuntimeDirectory=plank/pam' "$pam_unit"
rg -Fxq 'RuntimeDirectoryMode=0700' "$pam_unit"
rg -Fxq 'LogsDirectory=plank' "$pam_unit"
rg -Fxq 'LogsDirectoryMode=0700' "$pam_unit"
rg -Fxq 'StandardOutput=append:/var/log/plank/pam-broker.log' "$pam_unit"
rg -Fxq 'StandardError=append:/var/log/plank/pam-broker.log' "$pam_unit"
rg -Fxq 'ExecStart=/usr/libexec/plank/plank-pam-broker --socket /run/plank/pam/auth.sock --config /etc/plank/host.conf' "$pam_unit"
rg -Fxq 'LogsDirectory=plank' "$display_unit"
rg -Fxq 'LogsDirectoryMode=0700' "$display_unit"
rg -Fxq 'StandardOutput=append:/var/log/plank/display-prepare.log' "$display_unit"
rg -Fxq 'StandardError=append:/var/log/plank/display-prepare.log' "$display_unit"
rg -Fq 'PLANK_PAM_CHANNEL_FD' \
  "$repo_dir/packaging/host/linux/bin/plank-host"
rg -Fxq 'account    include      system-auth' "$pam_policy"
rg -Fxq 'auth       substack     system-auth' "$pam_policy"
rg -Fxq 'session    optional     pam_keyinit.so force revoke' "$pam_policy"
rg -Fxq 'session    include      system-auth' "$pam_policy"
if rg -q '^[[:space:]]*(password|auth[[:space:]]+include[[:space:]]+postlogin|session[[:space:]]+include[[:space:]]+postlogin)' "$pam_policy"; then
  echo 'PLANK PAM policy retains an unused password or postlogin stack' >&2
  exit 1
fi
if rg -q 'pam_succeed_if|ingroup|remote-desktop-users' "$pam_policy"; then
  echo 'PLANK PAM policy still contains product-specific account authorization' >&2
  exit 1
fi
if rg -q '^CapabilityBoundingSet=.*CAP_(SETUID|SETGID|KILL)' "$unit"; then
  echo 'machine Sender retained obsolete identity-switching capabilities' >&2
  exit 1
fi
if rg -q '%h|graphical-session.target' "$unit"; then
  echo 'host unit still depends on a graphical user login' >&2
  exit 1
fi

rg -Fq '/usr/libexec/plank/plank-host-supervisor' "$spec"
rg -Fq '/usr/libexec/plank/plank-pam-broker' "$spec"
if rg -q '/usr/bin/plank-(host-supervisor|pam-broker)' \
  "$unit" "$pam_unit" "$spec" "$builder"; then
  echo 'internal host service binaries remain exposed in /usr/bin' >&2
  exit 1
fi
rg -Fxq 'Requires:       xorg-x11-server-utils' "$spec"
rg -Fq '/usr/libexec/plank/plank-host' "$spec"
rg -Fq 'OUTPUT_NAME "plank-host"' \
  "$repo_dir/apps/host/linux/cmake/targets/common.cmake"
rg -Fq '/usr/libexec/plank/plank-host' \
  "$repo_dir/packaging/host/linux/bin/plank-host"
rg -Fq '/usr/lib/systemd/system/plank-host.service' "$spec"
rg -Fq '/usr/lib/systemd/system-preset/90-plank.preset' "$spec"
rg -Fq 'systemctl preset plank-display-prepare.service' "$spec"
rg -Fxq '%systemd_postun plank-display-prepare.service' "$spec"
rg -Fxq '%systemd_postun_with_restart plank-pam-broker.service plank-host.service' "$spec"
if rg -n '^%systemd_postun_with_restart .*plank-display-prepare\.service' "$spec"; then
  echo 'boot-only display preparation is restarted during package upgrades' >&2
  exit 1
fi
rg -Fq 'plank-host-certificate' "$spec"
rg -Fq 'plank-host-state' "$spec"
rg -Fq '/var/lib/plank/plank-state.json' "$spec"
rg -Fxq 'file_state = /var/lib/plank/plank-state.json' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf"
rg -Fxq 'allow_root_login = false' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf"
rg -Fxq '/etc/pam.d/plank-host' "$spec"
rg -Fxq '%config(noreplace) /etc/logrotate.d/plank-host' "$spec"
rg -Fxq 'Requires:       logrotate' "$spec"
rg -Fxq '%dir %attr(0700,root,root) /var/log/plank' "$spec"
rg -Fq 'install -d -m 0700 "$payload_dir/var/log/plank"' "$builder"
rg -Fq 'host_rpm_log_directory_gate=pass' "$builder"
for helper_log in host-supervisor.log pam-broker.log display-prepare.log; do
  rg -Fq "/var/log/plank/${helper_log}" "$logrotate_policy"
done
rg -Fxq '    size 10M' "$logrotate_policy"
rg -Fxq '    rotate 10' "$logrotate_policy"
rg -Fxq '    copytruncate' "$logrotate_policy"
test -f "$host_wacom_rule"
test ! -e "$repo_dir/packaging/host/linux/udev/70-plank-wacom.rules"
rg -Fq '/usr/lib/udev/rules.d/70-plank-host-wacom.rules' "$spec"
if rg -Fq '/usr/lib/udev/rules.d/70-plank-wacom.rules' "$spec"; then
  echo 'host RPM spec retains the ambiguous Wacom rule filename' >&2
  exit 1
fi
rg -Fxq '%dir %attr(0700,root,root) /etc/plank/tls' "$spec"
rg -Fxq '%ghost %config(noreplace) %attr(0600,root,root) /etc/plank/tls/key.pem' "$spec"
if rg -q 'plank-auth|remote-desktop-users|/etc/pam\.d/remote-desktop|sysusers' \
  "$pam_unit" "$pam_policy" "$spec" \
  "$repo_dir/apps/host/linux/src/auth/pam_broker.cpp"; then
  echo 'obsolete PLANK authentication-group policy remains' >&2
  exit 1
fi
rg -Fq 'packaging/host/linux/pam/plank-host' "$builder"
rg -Fq 'packaging/host/linux/udev/70-plank-host-wacom.rules' "$builder"
if rg -q 'packaging/host/linux/pam/remote-desktop|packaging/sysusers\.d' "$builder"; then
  echo 'host package builder still installs obsolete authentication-group files' >&2
  exit 1
fi
rg -Fq 'constexpr std::string_view pam_service = "plank-host"' \
  "$repo_dir/apps/host/linux/src/auth/pam_broker.cpp"
rg -Fq 'auth::load_broker_policy(config_path, policy_error)' \
  "$repo_dir/apps/host/linux/src/auth/pam_broker.cpp"
rg -Fq 'if (username == "root" && !allow_root_login)' \
  "$repo_dir/apps/host/linux/src/auth/pam_broker.cpp"
rg -Fq 'bool_f(vars, "allow_root_login", broker_allow_root_login)' \
  "$repo_dir/apps/host/linux/src/config.cpp"
rg -Fq 'chmod(path.parent_path().c_str(), 0700)' \
  "$repo_dir/apps/host/linux/src/auth/pam_broker.cpp"
rg -Fq 'chmod(path.c_str(), 0600)' \
  "$repo_dir/apps/host/linux/src/auth/pam_broker.cpp"
if rg -Fq '/usr/lib/systemd/user/plank-host.service' "$spec"; then
  echo 'RPM manifest still contains the obsolete host user unit' >&2
  exit 1
fi

rg -Fq 'refusing to package a dirty PLANK source tree' "$builder"
rg -Fq 'plank-host-supervisor' "$builder"
rg -Fq 'plank-host-certificate' "$builder"
rg -Fq 'plank-host-state' "$builder"
rg -Fq 'PLANK_BOOST_SOURCE_DIR' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'project(Boost VERSION 1.89.0 LANGUAGES CXX)' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'FETCHCONTENT_SOURCE_DIR_BOOST' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_mouse_scroll_compat_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_num_lock_always_on_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'client_bookmark_resolution_policy_gate=pass' \
  "$repo_dir/scripts/build/build-client-package-binaries.sh"
rg -Fq 'client_wacom_generation_transport_gate=pass' \
  "$repo_dir/scripts/build/build-client-package-binaries.sh"
rg -Fq 'restrict_worker_capabilities' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'stage_pulse_cookie' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq '/run/plank/host/pulse-cookie' \
  "$repo_dir/apps/host/linux/src/session/session_context.cpp"
rg -Fq 'PLANK_SESSION_CONTROL_FD' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
if rg -q 'PLANK_(HOST_OPTIONS|MDNS_DISCOVERY)' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp" \
  "$repo_dir/apps/host/linux/src/main.cpp" \
  "$repo_dir/packaging/host/linux/bin/plank-host"; then
  echo 'legacy host environment configuration remains' >&2
  exit 1
fi
rg -Fq 'mdns_discovery' \
  "$repo_dir/apps/host/linux/src/config.cpp"
rg -Fxq 'mdns_discovery = false' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf"
rg -Fq '/etc/plank/host.conf' \
  "$repo_dir/packaging/host/linux/bin/plank-host"
[[ ! -e ${repo_dir}/packaging/host/linux/config/plank.conf ]]
if rg -n '/etc/plank/plank\.conf' \
  "$repo_dir/packaging/host/linux/bin" \
  "$repo_dir/packaging/host/linux/systemd" \
  "$repo_dir/packaging/host/linux/rpm/plank-host.spec" \
  "$repo_dir/apps/host/linux/src"; then
  echo 'ambiguous generic host configuration path remains' >&2
  exit 1
fi
if rg -n '^[[:space:]]*output_name[[:space:]]*=' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf" ||
  rg -n \
    'video_config\.output_name|config::video\.output_name|"output_name",[[:space:]]*video\.output_name' \
    "$repo_dir/apps/host/linux/src" \
    "$repo_dir/apps/host/linux/tests" \
    --glob '*.{cpp,h}'; then
  echo 'legacy static capture-output selector remains' >&2
  exit 1
fi
rg -Fq 'session.output_name = *capture_name' \
  "$repo_dir/apps/host/linux/src/nvhttp.cpp"
rg -Fq 'config.monitor.output_name = launch_session->span_desktop ?' \
  "$repo_dir/apps/host/linux/src/session_stream.cpp"
rg -Fq 'config.m_device_id = session.output_name' \
  "$repo_dir/apps/host/linux/src/display_device.cpp"
rg -Fq 'host_static_capture_selector_absence_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_global_video_selector_absence_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_rpm_global_video_selector_absence_gate=pass' \
  "$repo_dir/scripts/package/build-host-rpm.sh"
rg -Fq 'host_x264_config_section_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_complete_config_template_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_rpm_x264_config_section_gate=pass' \
  "$repo_dir/scripts/package/build-host-rpm.sh"
rg -Fxq '[x264-encoder]' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf"
if rg -Fxq '[software-encoder]' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf"; then
  echo 'packaged host configuration retains the obsolete software-encoder section' >&2
  exit 1
fi
if rg -n '^\[video\]$|^[[:space:]]*(capture|encoder)[[:space:]]*=' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf"; then
  echo 'packaged host configuration still exposes global video selectors' >&2
  exit 1
fi
if rg -n \
  'config::video\.(capture|encoder)|std::string[[:space:]]+(capture|encoder);|string_f\(vars,[[:space:]]*"(capture|encoder)"' \
  "$repo_dir/apps/host/linux/src" \
  "$repo_dir/apps/host/linux/tests" \
  --glob '*.{cpp,h}'; then
  echo 'host source still contains global video selectors' >&2
  exit 1
fi
rg -Fq 'host_legacy_x11_capture_absence_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_upnp_absence_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_auth_group_absence_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_fixed_desktop_reservation_gate=pass' \
  "$repo_dir/scripts/build/build-host-package-binaries.sh"
rg -Fq 'host_rpm_fixed_desktop_gate=pass' \
  "$repo_dir/scripts/package/build-host-rpm.sh"
rg -Fq 'inline constexpr int desktop_app_id = 881448767' \
  "$repo_dir/apps/host/linux/src/process.h"
rg -Fq 'std::atomic<int> _app_id {0}' \
  "$repo_dir/apps/host/linux/src/process.h"
rg -Fq 'if(WIN32 OR APPLE)' \
  "$repo_dir/apps/host/linux/cmake/dependencies/Boost_Sunshine.cmake"
if rg -n 'apps\.json|file_apps|global_prep_cmd|Steam Big Picture|Low Res Desktop' \
  "$repo_dir/apps/host/linux/src" \
  "$repo_dir/apps/host/linux/src_assets" \
  "$repo_dir/apps/host/linux/cmake" \
  "$repo_dir/apps/host/linux/packaging" \
  "$repo_dir/apps/host/linux/docs"; then
  echo 'legacy host application catalog remains' >&2
  exit 1
fi
if rg -n 'run_command|request_process_group_exit|process_group_running|open_url' \
  "$repo_dir/apps/host/linux/src/platform/common.h" \
  "$repo_dir/apps/host/linux/src/platform/linux" \
  "$repo_dir/apps/host/linux/tests/integration"; then
  echo 'legacy Linux external-command launcher remains' >&2
  exit 1
fi
if [[ -e $repo_dir/apps/host/linux/src/upnp.cpp || \
      -e $repo_dir/apps/host/linux/src/upnp.h ]]; then
  echo 'UPnP implementation files remain' >&2
  exit 1
fi
if rg -n -i 'miniupnp|upnp' \
  "$repo_dir/apps/host/linux/src" \
  "$repo_dir/apps/host/linux/cmake" \
  "$repo_dir/apps/host/linux/scripts" \
  "$repo_dir/apps/host/linux/packaging" \
  "$repo_dir/apps/host/linux/docs" \
  "$repo_dir/apps/host/linux/docker" \
  "$repo_dir/packaging" \
  --glob '!**/third-party/**'; then
  echo 'UPnP or miniupnpc capability remains' >&2
  exit 1
fi
rg -Fq 'host_rpm_upnp_absence_gate=pass' \
  "$repo_dir/scripts/package/build-host-rpm.sh"
rg -Fq 'restarting the PLANK media worker for fresh X11/NvFBC state' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'stop_worker(worker);' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'Scheduled PLANK display transition from ' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'PLANK live display transition completed for UID' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
if ! rg -Uq \
  '(?s)X509_digest\(certificate, EVP_sha256\(\).*?util::hex_vec\(std::vector<std::uint8_t>\(.*?\), true\);' \
  "$repo_dir/apps/host/linux/src/nvhttp.cpp"; then
  echo 'plank_transport certificate pin is not emitted in conventional TLS byte order' >&2
  exit 1
fi
rg -Fq 'Temporary PLANK physical-display lease acquired for UID' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq '/usr/libexec/plank/plank-display-prepare' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fxq 'ReadWritePaths=/etc/X11/xorg.conf.d' \
  "$repo_dir/packaging/host/linux/systemd/plank-host.service"
rg -Fq 'Only the active desktop user may change its display layout' \
  "$repo_dir/apps/host/linux/src/nvhttp.cpp"
rg -Fq 'The requested display layout is not supported by this workstation' \
  "$repo_dir/apps/host/linux/src/nvhttp.cpp"
rg -Fq 'persistent virtual display transitions are disabled by display.startup_layout' \
  "$repo_dir/packaging/host/linux/bin/plank-display-prepare"
rg -Fq 'Restored the exact pre-session physical NVIDIA MetaMode' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'safe native physical output' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
if rg -q 'reboot|systemctl_path, \{"restart", "display-manager' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"; then
  echo 'physical display recovery retained a reboot or display-manager restart path' >&2
  exit 1
fi
# The layout builder captures the already-validated request, including output
# ordering. Keep guarding both selected modes and the actual bounded call.
rg -Fq 'plank::topology::virtual_mode_size(request.mode_1)' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'plank::topology::virtual_mode_size(request.mode_2)' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'layout_arguments(),' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq '"--fb", std::to_string(canvas_width) + "x" + std::to_string(canvas_height)' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'Virtual ${maximum_canvas_width} ${maximum_canvas_height}' \
  "$repo_dir/packaging/host/linux/bin/plank-display-prepare"
rg -Fq 'maximum_canvas_width=8192' \
  "$repo_dir/packaging/host/linux/bin/plank-display-prepare"
rg -Fq '"--rate", "60"' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq '"--set", "non-desktop", "0"' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq '"--off", "--set", "non-desktop", "1"' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'visibility_session_id != selected->id' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'visibility_session_id = selected->id' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq 'constexpr std::string_view systemd_run_path = "/usr/bin/systemd-run"' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq '"--uid=" + account.name' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
rg -Fq '"--property=NoNewPrivileges=yes"' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"
if rg -q 'set(uid|gid|groups)\(' \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"; then
  echo "host supervisor must delegate user-command identity to systemd" >&2
  exit 1
fi
if rg -q 'AllowNonEdidModes|--newmode|--addmode|PLANK-' \
  "$repo_dir/packaging/host/linux/bin/plank-display-prepare" \
  "$repo_dir/apps/host/linux/src/session/host_supervisor.cpp"; then
  echo 'host retained non-EDID live mode injection' >&2
  exit 1
fi
if rg -q 'plank_authentication|/pair|pair_session_t|pairing' \
  "$repo_dir/apps/host/linux/src/nvhttp.cpp" \
  "$repo_dir/apps/host/linux/src/nvhttp.h"; then
  echo 'host retained legacy PIN/certificate pairing code' >&2
  exit 1
fi
rg -Fq 'PLANK PAM broker is unavailable; refusing to start session negotiation' \
  "$repo_dir/apps/host/linux/src/nvhttp.cpp"
rg -Fq '/run/plank/pam/auth.sock' \
  "$repo_dir/apps/host/linux/src/auth/pam_broker_channel.h"
rg -Fq 'broker_channel::request_connection()' \
  "$repo_dir/apps/host/linux/src/nvhttp.cpp" \
  "$repo_dir/apps/host/linux/src/auth/pam_client.cpp"
if rg -q 'connect_broker|auth.sock|PLANK_AUTH_SOCKET' \
  "$repo_dir/apps/host/linux/src/auth/pam_client.cpp" \
  "$repo_dir/apps/host/linux/src/nvhttp.cpp" \
  "$repo_dir/packaging/host/linux/bin/plank-host"; then
  echo 'media worker still opens a privileged PAM filesystem socket' >&2
  exit 1
fi

client_session="$repo_dir/apps/client/app/streaming/session.cpp"
client_http="$repo_dir/apps/client/app/backend/nvhttp.cpp"
client_manager="$repo_dir/apps/client/app/backend/computermanager.cpp"
client_input="$repo_dir/apps/client/app/streaming/input/input.cpp"
client_raw_wacom="$repo_dir/apps/client/app/streaming/input/linuxrawwacom.cpp"
rg -Fq 'PLANK transport ended' "$client_session"
# Reconnect now consults the bounded policy gate before every request, rather
# than running a cancellation-only loop that can retry indefinitely.
rg -Fq 'for (int attempt = 1; waitForPlankReconnectRequest(); ++attempt)' "$client_session"
rg -Fq 'constexpr int RetryDelayMs = 1000' "$client_session"
rg -Fq 'replacement worker has no app to resume' "$client_session"
rg -Fq 'worker already has an active Desktop stream' "$client_session"
rg -Fq 'm_InputHandler->beginRawHidReconnect();' "$client_session"
rg -Fq 'm_InputHandler->finishRawHidReconnect();' "$client_session"
rg -Fq 'suspendForReconnect();' "$client_session"
rg -Fq 'resumeAfterReconnect();' "$client_session"
rg -Fq 'handlePlankLocalUserEvent' "$client_session"
rg -Fq 'one-shot pending latches' "$client_session"
rg -Fq 'display transition is still pending' "$client_session"
rg -Fq 'authentication will be refreshed once' "$client_session"
rg -Fq "response.trimmed().startsWith(QLatin1Char('<'))" "$client_http"
rg -Fq 'verifyResponseStatus(response);' "$client_http"
rg -Fq 'm_LinuxRawWacomInput->beginReconnect();' "$client_input"
rg -Fq 'm_LinuxRawWacomInput->finishReconnect();' "$client_input"
rg -Fq 'release(false);' "$client_raw_wacom"
rg -Fq 'm_AttachFailed.store(false);' "$client_raw_wacom"
rg -Fq 'm_CanReconnect.store(false)' "$client_session"
rg -Fq 'PLANK_TRANSPORT_TERMINATION_SESSION_TAKEN_OVER' "$client_session"
rg -Fq 'This PLANK session was transferred to another client.' "$client_session"
rg -Fq 'PLANK workstation session is active' "$client_session"
rg -Fq '&plankTakeover=1' "$client_http"
rg -Fq 'rememberPlankReconnectCredentials' "$client_manager"

host_http="$repo_dir/apps/host/linux/src/nvhttp.cpp"
host_sessions="$repo_dir/apps/host/linux/src/session_stream.cpp"
rg -Fq 'PLANK workstation session is active' "$host_http"
rg -Fq 'PLANK_TRANSPORT_TERMINATION_SESSION_TAKEN_OVER' "$host_http"
rg -Fq 'launch_owner_' "$host_sessions"
rg -Fq 'plank_transport_native_endpoint_stop(endpoint);' "$host_sessions"
