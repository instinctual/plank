#!/usr/bin/env bash

set -euo pipefail

if (($# > 2)); then
  echo "usage: $0 [BUILD_DIR] [PREPARED_FFMPEG_DIR]" >&2
  exit 2
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source_dir="${repo_dir}/apps/host/linux"
source "${repo_dir}/scripts/package/package-version.sh"
plank_load_package_version "$repo_dir"
package_version=$PLANK_PACKAGE_VERSION
build_dir=$(realpath -m -- "${1:-${repo_dir}/build/package-host}")
ffmpeg_dir=$(realpath -m -- "${2:-${source_dir}/cmake-build-ffmpeg-x264rgb-install/ffmpeg}")
build_jobs=${PLANK_BUILD_JOBS:-8}
plank_transport_cargo_features=${PLANK_TRANSPORT_CARGO_FEATURES:-quinn-telemetry}
case "$plank_transport_cargo_features" in
  quinn-telemetry|quinn-telemetry,quinn-bbr) ;;
  *)
    echo "unsupported PLANK transport Cargo feature set: ${plank_transport_cargo_features}" >&2
    exit 1
    ;;
esac
[[ -n ${PLANK_BOOST_SOURCE_DIR:-} ]] || {
  echo "prepared Boost source is required; set PLANK_BOOST_SOURCE_DIR" >&2
  exit 1
}
boost_source_dir=$(realpath -e -- "$PLANK_BOOST_SOURCE_DIR")
source "$repo_dir/scripts/build/build-paths.sh"
plank_build_path_flags "$repo_dir" "$build_dir"
plank_native_dependency_flags
[[ $build_jobs =~ ^[1-9][0-9]*$ ]] || {
  echo "invalid host build job count: ${build_jobs}" >&2
  exit 1
}

for command_name in cargo cmake git nm realpath rg rustc; do
  command -v "$command_name" >/dev/null || {
    echo "required command is unavailable: ${command_name}" >&2
    exit 1
  }
done

# The retained Host FFmpeg/x264/x265 source is patched by build-deps. This
# helper must fail closed: a failed forward check is acceptable only when the
# exact patch reverses cleanly (already applied). Otherwise a clean bootstrap
# could silently build incompatible upstream source.
host_patch_helper="${source_dir}/third-party/build-deps/cmake/apply_git_patch.cmake"
[[ -f $host_patch_helper ]] || {
  echo "Host dependency patch helper is unavailable" >&2
  exit 1
}
for required_patch_helper_token in \
  'git apply -v --ignore-whitespace --reverse --check' \
  'patch is neither applicable nor already applied'; do
  rg -Fq "$required_patch_helper_token" "$host_patch_helper" || {
    echo "Host dependency patch helper is not fail-closed: ${required_patch_helper_token}" >&2
    exit 1
  }
done
echo "host_dependency_patch_fail_closed_gate=pass"
"${repo_dir}/scripts/build/verify-host-dependency-patches.sh"
[[ $(rustc --version) == "rustc 1.89.0 "* ]] || {
  echo "PLANK transport requires rustc 1.89.0" >&2
  exit 1
}
[[ $(cargo --version) == "cargo 1.89.0 "* ]] || {
  echo "PLANK transport requires cargo 1.89.0" >&2
  exit 1
}
plank_transport_dir="${repo_dir}/protocol/plank-transport"
for plank_transport_input in \
  Cargo.toml \
  Cargo.lock \
  include/plank_transport.h \
  include/plank_transport_control.h \
  include/plank_transport_event.h \
  include/plank_transport_input.h \
  include/plank_transport_setup.h \
  src/lib.rs; do
  [[ -f ${plank_transport_dir}/${plank_transport_input} ]] || {
    echo "PLANK transport input is unavailable: ${plank_transport_input}" >&2
    exit 1
  }
done
cargo metadata --locked --offline --no-deps \
  --format-version 1 \
  --manifest-path "${plank_transport_dir}/Cargo.toml" >/dev/null
# Run the vendored boundary/accounting and telemetry regressions before the Host.
# This separate test archive is never linked into the product.
CARGO_TARGET_DIR="$build_dir/quinn-tests" cargo test --release --locked --offline \
  --manifest-path "$repo_dir/third_party/quinn-proto-0.11.17/Cargo.toml" \
  --lib connection::datagrams::plank_tests
CARGO_TARGET_DIR="$build_dir/quinn-tests" cargo test --release --locked --offline \
  --manifest-path "$repo_dir/third_party/quinn-proto-0.11.17/Cargo.toml" \
  --features plank-telemetry \
  --lib tests::plank_telemetry_snapshot_is_owned_and_preserves_queue_counters -- --exact
rg -q '^#define PLANK_TRANSPORT_ABI_VERSION 13u$' \
  "${plank_transport_dir}/include/plank_transport.h" || {
  echo "host requires PLANK transport ABI 13" >&2
  exit 1
}
rg -Fq 'uint32_t max_udp_payload_size;' \
  "${plank_transport_dir}/include/plank_transport.h" || {
  echo "host PLANK transport is missing the route MTU contract" >&2
  exit 1
}
for required_rate_contract in \
  'uint32_t initial_video_bitrate_kbps;' \
  'plank_transport_native_set_video_bitrate('; do
  rg -Fq "$required_rate_contract" \
    "${plank_transport_dir}/include/plank_transport.h" || {
    echo "host PLANK transport is missing the encoder-rate contract: ${required_rate_contract}" >&2
    exit 1
  }
done
echo "host_plank_transport_rust_input_gate=pass"
echo "host_plank_transport_cargo_features=${plank_transport_cargo_features}"
for required_plank_transport_token in \
  'PlankTransportCertificateSha256' \
  'PlankTransportToken' \
  'start_plank_transport_data_plane' \
  'session.plank_transport_endpoint' \
  'plank_transport_native_video_send' \
  'plank_transport_native_audio_send' \
  'plank_transport_native_data_send' \
  'plank_transport_native_data_receive' \
  'PLANK_TRANSPORT_SETUP_LAUNCH_REQUEST' \
  'host_feature_flags' \
  'reference_frame_invalidation' \
  'Native QUIC session negotiation active' \
  'drain_plank_transport_control' \
  'if (!session->plank_transport_endpoint)' \
  'Confirmed PLANK encoder target over PlankTransport' \
  'PlankTransport native transport'; do
  rg -Fq "$required_plank_transport_token" \
    "$source_dir/src" || {
    echo "host plank_transport negotiation invariant is missing: ${required_plank_transport_token}" >&2
    exit 1
  }
done
echo "host_plank_transport_negotiation_gate=pass"
for removed_data_plane_selector_token in \
  'plankDataPlane' \
  'PlankDataPlane' \
  'PlankDataPlanes' \
  'legacy,plank_transport'; do
  if rg -Fq "$removed_data_plane_selector_token" "$source_dir/src"; then
    echo "obsolete host data-plane selector remains: ${removed_data_plane_selector_token}" >&2
    exit 1
  fi
done
echo "host_plank_transport_selector_absence_gate=pass"
for removed_legacy_listener_token in \
  'control_server.bind' \
  'video_sock.bind' \
  'audio_sock.bind' \
  'recv_thread = std::jthread'; do
  if rg -Fq "$removed_legacy_listener_token" "$source_dir/src/stream.cpp"; then
    echo "obsolete host data-plane listener remains active: ${removed_legacy_listener_token}" >&2
    exit 1
  fi
done
echo "host_plank_transport_legacy_listener_absence_gate=pass"
for removed_legacy_packetizer_token in \
  'control_server_t' \
  'video_packet_raw_t' \
  'audio_fec_packet_t' \
  'reed_solomon_encode' \
  'enet_host_service' \
  'platf::send_batch' \
  'recv_ping' \
  'video_sock' \
  'audio_sock'; do
  if rg -Fq "$removed_legacy_packetizer_token" "$source_dir/src/stream.cpp"; then
    echo "obsolete host packetizer remains: ${removed_legacy_packetizer_token}" >&2
    exit 1
  fi
done
echo "host_plank_transport_legacy_packetizer_absence_gate=pass"
if rg -Fq 'concat_and_insert' "$source_dir/src" "$source_dir/tests"; then
  echo "obsolete host packet-construction helper or test remains: concat_and_insert" >&2
  exit 1
fi
echo "host_plank_transport_legacy_packetizer_test_absence_gate=pass"
for removed_host_transport_dependency_token in \
  '<enet/enet.h>' \
  'ENetHost' \
  'enet_' \
  '<rs.h>' \
  'reed_solomon_' \
  'moonlight-common-c/nanors' \
  'moonlight-common-c/enet' \
  'ENET_NO_INSTALL'; do
  if rg -Fq "$removed_host_transport_dependency_token" \
      "$source_dir/src" "$source_dir/cmake"; then
    echo "obsolete host transport dependency remains: ${removed_host_transport_dependency_token}" >&2
    exit 1
  fi
done
echo "host_plank_transport_legacy_dependency_absence_gate=pass"
python3 "$repo_dir/scripts/test/check-host-protocol-headers.py" \
  "$source_dir/third-party/moonlight-common-c"
python3 "$repo_dir/tests/packaging/test-host-protocol-headers.py"

# KyProto encrypts native media, input, event, and runtime session negotiation
# traffic. Reject dormant GameStream media-encryption and RTSP setup code.
if rg -n 'encryptionFlagsEnabled|encryption_control_v2|encryption_video|encryption_audio|x-ss-general\.encryption(Supported|Requested|Enabled)' \
  "$source_dir/src"; then
  echo "retired host GameStream media-encryption negotiation is present" >&2
  exit 1
fi
for removed_rtsp_token in \
  'RtspParser.c' \
  'src/rtsp.cpp' \
  'src/rtsp.h' \
  'rtsp_cipher' \
  'rtspenc://' \
  'sessionUrl0' \
  'rikeyid'; do
  if rg -Fq "$removed_rtsp_token" "$source_dir/src" "$source_dir/cmake"; then
    echo "retired host RTSP setup remains: ${removed_rtsp_token}" >&2
    exit 1
  fi
done
echo "host_rtsp_absence_gate=pass"

# PLANK bootstraps only through certificate-profile-validated HTTPS
# on the configured base port. Reject the retired unauthenticated discovery
# listener and the old split HTTPS offset.
for retired_http_token in \
  'PORT_HTTP' \
  'http_server_t' \
  'SimpleWeb::Server<SimpleWeb::HTTP>' \
  '47984'; do
  if rg -Fwq "$retired_http_token" \
      "$source_dir/src/nvhttp.cpp" "$source_dir/src/nvhttp.h"; then
    echo "retired host bootstrap transport remains: ${retired_http_token}" >&2
    exit 1
  fi
done
rg -Fq 'constexpr auto PORT_HTTPS = 0;' "$source_dir/src/nvhttp.h" || {
  echo "host HTTPS control listener is not on the configured base port" >&2
  exit 1
}
echo "host_https_only_bootstrap_gate=pass"

for required_input_transport_token in \
  'plank_transport_native_input_receive' \
  'nativeInputThread' \
  'input::native' \
  'PLANK_TRANSPORT_INPUT_RAW_HID_WACOM'; do
  rg -Fq "$required_input_transport_token" \
    "$source_dir/src" "$plank_transport_dir/include" || {
    echo "host native input transport invariant is missing: ${required_input_transport_token}" >&2
    exit 1
  }
done
echo "host_plank_transport_native_input_gate=pass"
for required_event_transport_token in \
  'send_plank_transport_event' \
  'PLANK_TRANSPORT_EVENT_HDR_MODE' \
  'PLANK_TRANSPORT_EVENT_RAW_HID_WACOM' \
  'PLANK_TRANSPORT_EVENT_CURSOR_SHAPE' \
  'PLANK_TRANSPORT_EVENT_CURSOR_POSITION'; do
  rg -Fq "$required_event_transport_token" \
    "$source_dir/src" "$plank_transport_dir/include" || {
    echo "host native event transport invariant is missing: ${required_event_transport_token}" >&2
    exit 1
  }
done
echo "host_plank_transport_native_event_gate=pass"
for compiler in \
  /opt/rh/gcc-toolset-14/root/usr/bin/gcc \
  /opt/rh/gcc-toolset-14/root/usr/bin/g++ \
  /usr/local/cuda/bin/nvcc; do
  [[ -x ${compiler} ]] || {
    echo "required compiler is unavailable: ${compiler}" >&2
    exit 1
  }
done
[[ -f ${ffmpeg_dir}/lib/libavcodec.a ]] || {
  echo "prepared host FFmpeg tree is unavailable: ${ffmpeg_dir}" >&2
  exit 1
}
[[ -f ${boost_source_dir}/CMakeLists.txt ]] &&
  rg -Fxq 'project(Boost VERSION 1.89.0 LANGUAGES CXX)' \
    "$boost_source_dir/CMakeLists.txt" || {
  echo "prepared Boost source is not exact version 1.89.0: ${boost_source_dir}" >&2
  exit 1
}
echo "host_prepared_boost_gate=pass"

# PLANK does not fetch remote files or expose mutable application
# artwork. Keep the inherited libcurl downloader, application-art endpoint,
# and shared-temporary first-run credential path out of the host.
if rg -n 'download_file|url_escape\(|url_get_host|CURL::|CURL_|libcurl|appasset|desktop_image_path|FRESH_STATE|/tmp/Sunshine' \
  "$source_dir/src" "$source_dir/cmake" "$source_dir/tests" \
  --glob '!**/third-party/**'; then
  echo "legacy host downloader, artwork endpoint, or temporary credential path remains" >&2
  exit 1
fi
for required_secure_write_token in \
  'O_NOFOLLOW' \
  '::fchmod(fd, mode)' \
  'WriteFileRejectsSymbolicLinks'; do
  rg -Fq "$required_secure_write_token" \
    "$source_dir/src/file_handler.cpp" \
    "$source_dir/tests/unit/test_file_handler.cpp" || {
    echo "secure host credential-write invariant is missing: ${required_secure_write_token}" >&2
    exit 1
  }
done
echo "host_legacy_http_surface_absence_gate=pass"
echo "host_secure_credential_write_gate=pass"

# PLANK's Rocky host accepts workstation keyboard, mouse, normalized
# pen, and raw-HID Wacom input only. Keep controller packet routing, feedback,
# Linux virtual-gamepad integration, launch metadata, and configuration UI out
# of the production host even though the shared libvirtualhid dependency
# remains.
if rg -n \
  'MULTI_CONTROLLER_MAGIC|SS_CONTROLLER_(ARRIVAL|TOUCH|MOTION|BATTERY)_MAGIC|gamepad_feedback|terminate_gamepads|probe_gamepads' \
  "$source_dir/src/input.cpp" "$source_dir/src/input.h" \
  "$source_dir/src/stream.cpp" "$source_dir/src/globals.h"; then
  echo "controller packet routing or feedback is present in PLANK host source" >&2
  exit 1
fi
if rg -n -i \
  'gamepad|controller|gcmap' \
  "$source_dir/src/platform/linux/input/virtualhid.cpp" \
  "$source_dir/src/platform/virtualhid_input.cpp" \
  "$source_dir/src/platform/virtualhid_input.h"; then
  echo "Linux gamepad integration or host controller configuration is present" >&2
  exit 1
fi
[[ ! -e ${source_dir}/tests/unit/platform/test_virtualhid_input.cpp ]] || {
  echo "gamepad-specific host tests are present" >&2
  exit 1
}
echo "host_gamepad_absence_gate=pass"

# Linux consumers such as Xorg/libinput may ignore REL_WHEEL_HI_RES unless the
# corresponding accumulated legacy detent is emitted in the same report.
virtualhid_linux_backend="${source_dir}/third-party/libvirtualhid/src/platform/linux/uhid_backend.cpp"
virtualhid_linux_tests="${source_dir}/third-party/libvirtualhid/tests/unit/test_linux_backend.cpp"
for required_scroll_token in \
  vertical_scroll_remainder_ \
  horizontal_scroll_remainder_ \
  'enable_evdev_code(device, EV_REL, REL_WHEEL, "vertical scroll")' \
  'enable_evdev_code(device, EV_REL, REL_HWHEEL, "horizontal scroll")' \
  'emit_event(EV_REL, REL_WHEEL, static_cast<std::int32_t>(legacy_steps))' \
  'emit_event(EV_REL, REL_HWHEEL, static_cast<std::int32_t>(legacy_steps))'; do
  rg -Fq "$required_scroll_token" "$virtualhid_linux_backend" || {
    echo "host compatible wheel-scroll invariant is missing: ${required_scroll_token}" >&2
    exit 1
  }
done
for required_scroll_test_token in \
  UinputMouseAccumulatesLegacyScrollDetents \
  'EXPECT_NE(find_code(mouse, EV_REL, REL_WHEEL), nullptr)' \
  'EXPECT_NE(find_code(mouse, EV_REL, REL_HWHEEL), nullptr)'; do
  rg -Fq "$required_scroll_test_token" "$virtualhid_linux_tests" || {
    echo "host compatible wheel-scroll regression test is missing: ${required_scroll_test_token}" >&2
    exit 1
  }
done
echo "host_mouse_scroll_compat_gate=pass"

# PLANK numeric keypads are always numeric. The host must set the
# XKB state explicitly at connection time, reassert it before dependent keypad
# keys, and consume client Num Lock transitions so local and remote lock state
# cannot drift into opposite states.
for required_num_lock_token in \
  'XkbLockModifiers(display, XkbUseCoreKbd, num_lock_mask, num_lock_mask)' \
  'if (keyCode == VKEY_NUMLOCK)' \
  'if (!release && is_numeric_keypad_key(keyCode) && !enable_num_lock())' \
  ConsumesNumLockWithoutChangingNumericKeypadIdentity; do
  rg -Fq "$required_num_lock_token" \
    "$source_dir/src/input.cpp" "$source_dir/tests/unit/test_input.cpp" || {
    echo "host always-on Num Lock invariant is missing: ${required_num_lock_token}" >&2
    exit 1
  }
done
echo "host_num_lock_always_on_gate=pass"

if rg -n \
  'enable_sops|SUNSHINE_CLIENT_ENABLE_SOPS|resource\["\^/cancel\$"\]|root\.cancel' \
  "$source_dir/src" \
  --glob '*.{cpp,h}'; then
  echo "legacy client-controlled display or remote app cancellation is present in PLANK host" >&2
  exit 1
fi
echo "host_remote_control_absence_gate=pass"

if rg -n \
  'root\.mac|get_mac_address|Unable to find MAC address' \
  "$source_dir/src" \
  --glob '*.{cpp,h,mm}'; then
  echo "Wake-on-LAN MAC metadata is present in PLANK host source" >&2
  exit 1
fi
echo "host_wake_on_lan_absence_gate=pass"

if rg -n 'get_arg\(args, "(uniqueid|uuid)"|launch_session[.>-]+unique_id' \
  "$source_dir/src/nvhttp.cpp" "$source_dir/src/stream.cpp"; then
  echo "legacy request metadata controls PLANK Host launch/input state" >&2
  exit 1
fi
rg -Fq 'session->input_session_id = "plank-desktop";' "$source_dir/src/stream.cpp"
echo "host_legacy_request_metadata_absence_gate=pass"

# PLANK relies on administrator-managed routing and firewall policy.
# Keep inherited Sunshine UPnP discovery, automatic gateway port mappings,
# IPv6 pinholes, configuration/CLI toggles, and miniupnpc build inputs out of
# every first-party host target.
if [[ -e ${source_dir}/src/upnp.cpp || -e ${source_dir}/src/upnp.h ]]; then
  echo "UPnP implementation files remain in PLANK host source" >&2
  exit 1
fi
if rg -n -i 'miniupnp|upnp' \
  "$source_dir/src" \
  "$source_dir/cmake" \
  "$source_dir/scripts" \
  "$source_dir/packaging" \
  "$source_dir/docs" \
  "$source_dir/docker" \
  "$repo_dir/packaging" \
  --glob '!**/third-party/**'; then
  echo "UPnP or miniupnpc capability remains in first-party PLANK host source" >&2
  exit 1
fi
echo "host_upnp_absence_gate=pass"

# PLANK delegates human-account authorization to the branded PAM
# service and the host's PAM/SSSD/HBAC policy. The root media worker is the
# broker's only client, so no service-access or user-allowlist group belongs in
# the product.
pam_broker_source="${source_dir}/src/auth/pam_broker.cpp"
pam_policy="${repo_dir}/packaging/host/linux/pam/plank-host"
pam_unit="${repo_dir}/packaging/host/linux/systemd/plank-pam-broker.service"
host_spec="${repo_dir}/packaging/host/linux/rpm/plank-host.spec"
[[ -f $pam_policy && ! -e ${repo_dir}/packaging/host/linux/pam/remote-desktop &&
   ! -e ${repo_dir}/packaging/sysusers.d/plank.conf ]] || {
  echo "obsolete PLANK PAM or sysusers payload remains" >&2
  exit 1
}
if rg -n 'plank-auth|remote-desktop-users|--group' \
  "$pam_broker_source" "$pam_policy" "$pam_unit" "$host_spec"; then
  echo "obsolete PLANK authentication-group policy remains" >&2
  exit 1
fi
for required_auth_token in \
  'constexpr std::string_view pam_service = "plank-host"' \
  'auth::load_broker_policy(config_path, policy_error)' \
  'if (username == "root" && !allow_root_login)' \
  'chmod(path.parent_path().c_str(), 0700)' \
  'chmod(path.c_str(), 0600)'; do
  rg -Fq "$required_auth_token" "$pam_broker_source" || {
    echo "root-only PAM broker invariant is missing: ${required_auth_token}" >&2
    exit 1
  }
done
rg -Fq 'bool_f(vars, "allow_root_login", broker_allow_root_login)' \
  "$source_dir/src/config.cpp"
rg -Fxq 'ExecStart=/usr/libexec/plank/plank-pam-broker --socket /run/plank/pam/auth.sock --config /etc/plank/host.conf' \
  "$pam_unit"
rg -Fxq 'RuntimeDirectoryMode=0700' "$pam_unit"
rg -Fxq 'auth       substack     system-auth' "$pam_policy"
rg -Fxq 'account    include      system-auth' "$pam_policy"
rg -Fxq 'session    optional     pam_keyinit.so force revoke' "$pam_policy"
rg -Fxq 'session    include      system-auth' "$pam_policy"
if rg -q '^[[:space:]]*(password|auth[[:space:]]+include[[:space:]]+postlogin|session[[:space:]]+include[[:space:]]+postlogin)' "$pam_policy"; then
  echo "PAM service retained an unused password or postlogin stack" >&2
  exit 1
fi
if rg -q 'pam_succeed_if|ingroup' "$pam_policy"; then
  echo "PAM service retained product-specific account authorization" >&2
  exit 1
fi
rg -Fxq 'allow_root_login = false' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf"
rg -Fxq '/etc/pam.d/plank-host' "$host_spec"
rg -Fq 'packaging/host/linux/pam/plank-host' \
  "${repo_dir}/scripts/package/build-host-rpm.sh"
echo "host_auth_group_absence_gate=pass"

# Exercise the actual Unix descriptor protocol before producing a package;
# source-token checks alone cannot detect FD leaks or ancillary truncation.
# This includes the production PAM header and must use the Host's C++23 mode.
mkdir -p "$build_dir/plank-security-tests"
/opt/rh/gcc-toolset-14/root/usr/bin/g++ \
  -std=c++23 -Wall -Wextra -Wpedantic -Werror -pthread \
  -I"$source_dir/src" "$repo_dir/tests/session/test-pam-broker-channel.cpp" \
  -o "$build_dir/plank-security-tests/pam-broker-channel-test"
"$build_dir/plank-security-tests/pam-broker-channel-test"
echo "host_pam_delegation_protocol_gate=pass"

# Compile actual PAM client/manager/broker sources and exercise stalled peers,
# concurrency, cancellation and worker cleanup without touching a real account.
# Keep this gate active even though the shipped payload has BUILD_TESTS=OFF.
cmake -S "$repo_dir/tests/session/pam" -B "$build_dir/cmake-build-pam-hardening" \
  -DCMAKE_CXX_COMPILER=/opt/rh/gcc-toolset-14/root/usr/bin/g++ \
  -DPLANK_BOOST_SOURCE_DIR="$boost_source_dir" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build "$build_dir/cmake-build-pam-hardening" --parallel "$build_jobs"
ctest --test-dir "$build_dir/cmake-build-pam-hardening" --output-on-failure
echo "host_pam_deadline_isolation_gate=pass"

# A fatal X-server disconnect must not run NVIDIA atexit handlers from the
# cursor/capture thread while the encoder is still alive.
rg -Fq 'SetIOErrorHandler(retire_failed_x11_worker)' "$source_dir/src/platform/linux/x11grab.cpp"
/opt/rh/gcc-toolset-14/root/usr/bin/g++ \
  -std=c++20 -Wall -Wextra -Wpedantic -Werror -pthread \
  -I"$source_dir/src" "$repo_dir/tests/session/test-x11-worker-exit.cpp" \
  -lX11 -o "$build_dir/plank-security-tests/x11-worker-exit-test"
"$build_dir/plank-security-tests/x11-worker-exit-test"
echo "host_x11_worker_exit_gate=pass"

rg -Fq 'plank::session::receive_worker_control(' "$source_dir/src/session/host_supervisor.cpp"
/opt/rh/gcc-toolset-14/root/usr/bin/g++ \
  -std=c++20 -Wall -Wextra -Wpedantic -Werror \
  -I"$source_dir/src" "$repo_dir/tests/session/test-worker-control.cpp" \
  -o "$build_dir/plank-security-tests/worker-control-test"
"$build_dir/plank-security-tests/worker-control-test"
echo "host_worker_control_eof_gate=pass"

python3 "$repo_dir/tests/packaging/test-encoder-probe-order.py" "$source_dir/src/video.cpp"
echo "host_encoder_probe_order_gate=pass"

host_wacom_rule="${repo_dir}/packaging/host/linux/udev/70-plank-host-wacom.rules"
[[ -f $host_wacom_rule &&
   ! -e ${repo_dir}/packaging/host/linux/udev/70-plank-wacom.rules ]] || {
  echo "host Wacom udev rule identity is stale or ambiguous" >&2
  exit 1
}
for required_wacom_rule_token in \
  'SUBSYSTEM=="input"' \
  'SUBSYSTEM=="hidraw"' \
  'SUBSYSTEM=="misc", KERNEL=="uhid"' \
  'TAG+="uaccess"'; do
  rg -Fq "$required_wacom_rule_token" "$host_wacom_rule" || {
    echo "host Wacom udev rule is missing: ${required_wacom_rule_token}" >&2
    exit 1
  }
done
echo "host_wacom_udev_identity_gate=pass"

for required_pc_range_token in \
  'av_color_range_from_name(' \
  'sunshine_colorspace.full_range ? "pc" : "tv"' \
  'colorspace.full_range ? "PC" : "TV"'; do
  rg -Fq "$required_pc_range_token" \
    "$source_dir/src/video_colorspace.cpp" "$source_dir/src/video.cpp" || {
    echo "PLANK PC/full-range encoder terminology is missing: ${required_pc_range_token}" >&2
    exit 1
  }
done
if rg -n 'Color range:.*JPEG|Color range:.*MPEG' "$source_dir/src/video.cpp"; then
  echo "legacy JPEG/MPEG color-range terminology remains in the PLANK encoder log" >&2
  exit 1
fi
echo "host_pc_color_range_gate=pass"

if rg -n \
  'SS_TOUCH_MAGIC|PSS_TOUCH_PACKET|platf::touch_update|create_touchscreen|supports_touchscreen|native_pen_touch' \
  "$source_dir/src/input.cpp" \
  "$source_dir/src/platform/virtualhid_input.cpp" \
  "$source_dir/src/platform/virtualhid_input.h" \
  "$source_dir/src/platform/linux/input/virtualhid.cpp" \
  "$source_dir/src/config.cpp" \
  "$source_dir/src/config.h"; then
  echo "direct touchscreen support is present in PLANK host" >&2
  exit 1
fi
echo "host_touchscreen_absence_gate=pass"

# Losing client-window focus suspends raw-HID transport without destroying the
# host UHID/XInput endpoints. Stable endpoint identity prevents applications
# such as Flame from retaining a stale stylus/eraser device ID after refocus.
host_common_dir="${source_dir}/third-party/moonlight-common-c/src"
for retired_network_path in \
  ConnectionTester.c \
  SimpleStun.c; do
  [[ ! -e "${host_common_dir}/${retired_network_path}" ]] || {
    echo "retired host common-c network probe remains: ${retired_network_path}" >&2
    exit 1
  }
done
if rg -n \
  'LiFindExternalAddressIP4|LiTestClientConnectivity|LiGetPortFlagsFromStage|LiGetPortFlagsFromTerminationErrorCode|LiGetProtocolFromPortFlagIndex|LiGetPortFromPortFlagIndex|LiStringifyPortFlags|ML_PORT_FLAG_|ML_PORT_INDEX_|ML_TEST_RESULT' \
  "$host_common_dir"; then
  echo "retired host common-c STUN or connectivity-test API remains" >&2
  exit 1
fi
echo "host_legacy_network_probe_absence_gate=pass"

for required_raw_hid_token in \
  '#define PLANK_RAW_HID_WIRE_VERSION 2U' \
  'PLANK_RAW_HID_SUSPEND = 13'; do
  rg -Fq "$required_raw_hid_token" "$host_common_dir" || {
    echo "host raw-HID focus-suspend protocol invariant is missing: ${required_raw_hid_token}" >&2
    exit 1
  }
done
rg -q '#define[[:space:]]+LI_FF_RAW_HID_FOCUS_SUSPEND[[:space:]]+0x20' \
  "$host_common_dir/Limelight.h" || {
  echo "host raw-HID focus-suspend feature bit is missing" >&2
  exit 1
}
for required_raw_hid_token in \
  raw_hid_focus_suspend \
  PLANK_RAW_HID_SUSPEND \
  'Suspended raw HID tablet transport while retaining endpoints'; do
  rg -Fq "$required_raw_hid_token" \
    "$source_dir/src/platform/common.h" \
    "$source_dir/src/platform/linux/input/virtualhid.cpp" \
    "$source_dir/src/raw_hid_tablet.cpp" || {
    echo "host raw-HID endpoint-preservation invariant is missing: ${required_raw_hid_token}" >&2
    exit 1
  }
done
echo "host_raw_hid_focus_suspend_gate=pass"

# The qualified X11 host sends exact XFixes cursor images out of band and
# unconditionally excludes the cursor from PLANK video. There is no
# embedded-cursor compatibility mode.
for required_cursor_token in \
  'PLANK_CURSOR_WIRE_VERSION 1U' \
  'PLANK_CURSOR_MAX_CHUNK_SIZE (48U * 1024U)'; do
  rg -Fq "$required_cursor_token" "$host_common_dir" || {
    echo "host local-cursor protocol invariant is missing: ${required_cursor_token}" >&2
    exit 1
  }
done
for required_cursor_token in \
  PLANK_TRANSPORT_EVENT_CURSOR_SHAPE \
  PLANK_TRANSPORT_EVENT_CURSOR_POSITION \
  localCursorThread \
  send_cursor_shape_control \
  XFixesGetCursorImage \
  XFixesSelectCursorInput \
  XQueryPointer \
  consume_shape_change \
  "16'666'667ns" \
  'PLANK local cursor transport is unavailable' \
  'bool capture_cursor = false'; do
  rg -Fq "$required_cursor_token" \
    "$source_dir/src/stream.cpp" \
    "$source_dir/src/platform/linux/x11grab.cpp" \
    "$source_dir/src/session_stream.cpp" \
    "$source_dir/src/video.cpp" || {
    echo "host local-cursor implementation invariant is missing: ${required_cursor_token}" >&2
    exit 1
  }
done
if rg -n \
  '0x5507,  // Local cursor shape|subscribe_position_events|wait_position|std::this_thread::sleep_for\(16ms\)' \
  "$source_dir/src/stream.cpp" \
  "$source_dir/src/platform/linux/x11grab.cpp" \
  "$source_dir/src/platform/linux/x11grab.h"; then
  echo "rejected event-driven or query-time-relative cursor scheduler is present" >&2
  exit 1
fi
if rg -Fq 'display_cursor' "$source_dir/src"; then
  echo "host still contains the legacy global captured-cursor toggle" >&2
  exit 1
fi
echo "host_local_cursor_gate=pass"

# Exact raw-HID and normalized pen-tablet backends must never coexist after a
# raw group attaches. Flame otherwise applies Tablet Margins to the inactive
# generic device while pressure arrives from the exact Wacom endpoint.
for required_tablet_ownership_token in \
  sync_tablet_backend \
  set_normalized_pen_enabled \
  has_endpoints \
  'Exact raw HID tablet active; removed normalized pen fallback' \
  ExactRawTabletSuppressesNormalizedFallbackUntilDetach \
  select_normalized_pen_backend \
  'Normalized pen transport selected; released retained exact raw HID tablet endpoints' \
  NormalizedPenReleasesRetainedRawTabletEndpoints; do
  rg -Fq "$required_tablet_ownership_token" \
    "$source_dir/src/input.cpp" \
    "$source_dir/src/platform/virtualhid_input.cpp" \
    "$source_dir/src/raw_hid_tablet.cpp" \
    "$source_dir/tests/unit/test_input.cpp" || {
    echo "host raw/normalized tablet ownership invariant is missing: ${required_tablet_ownership_token}" >&2
    exit 1
  }
done
echo "host_raw_hid_fallback_exclusion_gate=pass"

# PLANK keeps every host runtime setting in one Sunshine config file.
# mDNS advertisement remains opt-in and defaults to disabled there.
for required_mdns_token in \
  mdns_discovery \
  'PLANK mDNS advertisement is disabled'; do
  rg -Fq "$required_mdns_token" "$source_dir/src/main.cpp" || {
    echo "host mDNS default-off invariant is missing: ${required_mdns_token}" >&2
    exit 1
  }
done
if rg -q 'PLANK_(HOST_OPTIONS|MDNS_DISCOVERY)' \
  "$source_dir/src/main.cpp" \
  "$source_dir/src/session/host_supervisor.cpp" \
  "$repo_dir/packaging/host/linux/bin/plank-host" \
  "$repo_dir/packaging/host/linux/systemd/plank-host.service" \
  "$repo_dir/packaging/host/linux/config/plank-host.conf"; then
  echo "legacy host environment configuration is still present" >&2
  exit 1
fi
rg -Fxq 'mdns_discovery = false' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf" || {
  echo "host mDNS configuration does not default to disabled" >&2
  exit 1
}
for required_mdns_config_doc in \
  'Accepted values: true or false.' \
  'The default is false; manually configured hostname/IP bookmarks continue to' \
  'work when discovery is disabled. Enabling this affects advertisement only'; do
  rg -Fq "$required_mdns_config_doc" \
    "$repo_dir/packaging/host/linux/config/plank-host.conf" || {
    echo "host mDNS configuration documentation is incomplete: ${required_mdns_config_doc}" >&2
    exit 1
  }
done
echo "host_mdns_default_off_gate=pass"

[[ ! -e ${repo_dir}/packaging/host/linux/config/host.env ]] || {
  echo "legacy host.env remains in the package source" >&2
  exit 1
}
[[ ! -e ${repo_dir}/packaging/host/linux/config/plank.conf ]] || {
  echo "ambiguous generic host configuration template remains" >&2
  exit 1
}
rg -Fq '/etc/plank/host.conf' \
  "$repo_dir/packaging/host/linux/bin/plank-host"
if rg -n '/etc/plank/plank\.conf' \
  "$source_dir/src" \
  "$repo_dir/packaging/host/linux/bin" \
  "$repo_dir/packaging/host/linux/systemd" \
  "$repo_dir/packaging/host/linux/rpm/plank-host.spec"; then
  echo "ambiguous generic host configuration path remains" >&2
  exit 1
fi
echo "host_single_config_gate=pass"

for required_network_token in \
  'ping_timeout = 10000'; do
  rg -Fq "$required_network_token" \
    "$repo_dir/packaging/host/linux/config/plank-host.conf" || {
    echo "host network configuration is missing: ${required_network_token}" >&2
    exit 1
  }
done
for required_network_token in \
  '"ping_timeout"'; do
  rg -Fq "$required_network_token" \
    "$source_dir/src/config.cpp" "$source_dir/src/network.cpp" || {
    echo "host network runtime is missing: ${required_network_token}" >&2
    exit 1
  }
done
if rg -n 'fec_percentage|fecPercentage' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf" \
  "$source_dir/src/config.cpp" \
  "$source_dir/src/config.h"; then
  echo "dormant host FEC configuration remains" >&2
  exit 1
fi
echo "host_network_config_gate=pass"

# PLANK accepts a deliberately small host configuration surface.
# Reject reintroduction of inherited Sunshine options for unsupported encoder
# platforms, consumer features, legacy display control, or product behaviors
# that are fixed by the client/bookmark protocol.
rg -Fq 'RuntimeOptionsMatchPlankProductPolicy' \
  "$source_dir/tests/integration/test_config_consistency.cpp" || {
  echo "host exact configuration-key policy test is missing" >&2
  exit 1
}
# Keep every retained administrator setting visible in the canonical template.
# Optional automatic selectors may be commented out, but each accepted parser
# key must have exactly one assignment-shaped entry so the package never hides
# a supported override.
mapfile -t retained_config_options < <(
  awk '
    /TEST\(ConfigConsistencyTest, RuntimeOptionsMatchPlankProductPolicy\)/ {
      in_test = 1
    }
    in_test && /const std::set<.*> expected \{/ {
      in_set = 1
      next
    }
    in_set && /};/ {
      exit
    }
    in_set && match($0, /"[a-z0-9_]+"/) {
      print substr($0, RSTART + 1, RLENGTH - 2)
    }
  ' "$source_dir/tests/integration/test_config_consistency.cpp"
)
[[ ${#retained_config_options[@]} -gt 0 ]] || {
  echo "could not extract the retained host configuration-key policy" >&2
  exit 1
}
for retained_config_option in "${retained_config_options[@]}"; do
  retained_config_count=$(
    rg -c \
      "^[[:space:]]*(#[[:space:]]*)?${retained_config_option}[[:space:]]*=" \
      "$repo_dir/packaging/host/linux/config/plank-host.conf" || true
  )
  if [[ $retained_config_count != 1 ]]; then
    echo "canonical host configuration must contain exactly one entry for ${retained_config_option}" >&2
    exit 1
  fi
done
echo "host_complete_config_template_gate=pass"
for removed_config_option in \
  qp \
  qsv_preset qsv_coder qsv_slow_hevc \
  amd_quality amd_rc amd_coder amd_usage amd_preanalysis amd_vbaq amd_enforce_hrd \
  vt_coder vt_software vt_realtime \
  vaapi_quality vaapi_rc vaapi_blbrc vaapi_strict_rc_buffer \
  vk_tune vk_rc_mode \
  dd_configuration_option dd_resolution_option dd_manual_resolution \
  dd_refresh_rate_option dd_manual_refresh_rate dd_hdr_option \
  dd_config_revert_delay dd_config_revert_on_disconnect dd_mode_remapping \
  dd_wa_hdr_toggle_delay \
  nvenc_realtime_hags nvenc_opengl_vulkan_on_dxgi nvenc_latency_over_power \
  external_ip install_steam_audio_drivers virtual_sink \
  max_bitrate packetsize stream_audio \
  mouse keyboard always_send_scancodes high_resolution_scrolling \
  key_rightalt_to_key_win notify_pre_releases locale flags; do
  if rg -Fq "\"${removed_config_option}\"" "$source_dir/src/config.cpp" ||
    rg -Fxq "### ${removed_config_option}" "$source_dir/docs/configuration.md"; then
    echo "removed inherited host configuration option returned: ${removed_config_option}" >&2
    exit 1
  fi
done
if rg -n \
  'config::video\.max_bitrate|config::stream\.packetsize|config::nvhttp\.external_ip' \
  "$source_dir/src" "$source_dir/tests" --glob '*.{cpp,h}'; then
  echo "removed global bitrate, packet-size, or external-IP state remains" >&2
  exit 1
fi
for required_session_authority in \
  'const int applied_kbps = requested_kbps;' \
  'const std::int64_t bitrate = config.bitrate * 1000LL;'; do
  rg -Fq "$required_session_authority" "$source_dir/src" || {
    echo "session bitrate/packet-size authority is missing: ${required_session_authority}" >&2
    exit 1
  }
done
echo "host_config_surface_cleanup_gate=pass"

rg -Fxq '[x264-encoder]' "$repo_dir/packaging/host/linux/config/plank-host.conf" || {
  echo "host configuration is missing the x264-specific encoder section" >&2
  exit 1
}
if rg -Fxq '[software-encoder]' "$repo_dir/packaging/host/linux/config/plank-host.conf"; then
  echo "host configuration retains the obsolete generic software-encoder section" >&2
  exit 1
fi
echo "host_x264_config_section_gate=pass"

# Capture output is negotiated from the authenticated bookmark session. Keep
# the old machine-specific global selector out of both the packaged config and
# Sunshine's static video configuration while retaining session.output_name.
if rg -n '^[[:space:]]*output_name[[:space:]]*=' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf" ||
  rg -n \
    'video_config\.output_name|config::video\.output_name|"output_name",[[:space:]]*video\.output_name' \
    "$source_dir/src" "$source_dir/tests" \
    --glob '*.{cpp,h}'; then
  echo "legacy static capture-output selector is present" >&2
  exit 1
fi
for required_capture_token in \
  'session.output_name = *capture_name' \
  'config.monitor.output_name = launch_session->span_desktop ?' \
  'config.m_device_id = session.output_name'; do
  rg -Fq "$required_capture_token" "$source_dir/src" || {
    echo "negotiated session capture selector is missing: ${required_capture_token}" >&2
    exit 1
  }
done
echo "host_static_capture_selector_absence_gate=pass"

# Capture source and encoder backend are exact per-bookmark protocol choices.
# A host-global [video] selector could hide a qualified backend at startup and
# contradict the accepted session, so it must not exist in configuration,
# parser state, documentation, or platform selection code.
if rg -n '^\[video\]$|^[[:space:]]*(capture|encoder)[[:space:]]*=' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf" ||
  rg -n \
    'config::video\.(capture|encoder)|std::string[[:space:]]+(capture|encoder);|string_f\(vars,[[:space:]]*"(capture|encoder)"' \
    "$source_dir/src" "$source_dir/tests" --glob '*.{cpp,h}' ||
  rg -n '^###[[:space:]]+(capture|encoder)$' \
    "$source_dir/docs/configuration.md"; then
  echo "legacy global capture or encoder selector remains" >&2
  exit 1
fi
for required_backend_invariant in \
  'if (verify_nvfbc())' \
  'if (verify_x11())' \
  'validate_encoder(software_cuda' \
  'validate_encoder(nvenc_direct' \
  'No exact PLANK encoder backend is available.' \
  'Requested PLANK capture source is unavailable' \
  'config.monitor.encoder_backend = launch_session->encoder_backend' \
  'config.monitor.capture_source = video::capture_source_e::nvfbc_8bit' \
  'config.monitor.capture_source = video::capture_source_e::x11_native10'; do
  rg -Fq "$required_backend_invariant" "$source_dir/src" || {
    echo "PLANK per-session backend invariant is missing: ${required_backend_invariant}" >&2
    exit 1
  }
done
echo "host_global_video_selector_absence_gate=pass"

# PLANK exposes exactly two Linux capture paths: qualified NvFBC
# 8-bit capture and the experimental owner-restricted Native X11/XShm 10-bit
# path. Keep Sunshine's dormant generic X11 SHM/XGetImage fallbacks out of the
# first-party host source, including their world-accessible SysV SHM mode.
x11_capture_source="${source_dir}/src/platform/linux/x11grab.cpp"
linux_platform_source="${source_dir}/src/platform/linux/misc.cpp"
if rg -n \
  'struct[[:space:]]+shm_attr_t|IPC_CREAT[[:space:]]*\|[[:space:]]*0777|"XGetImage"|xcb_shm_attach"' \
  "$x11_capture_source" ||
  rg -n 'Screencasting with X11"' "$linux_platform_source"; then
  echo "legacy generic X11 capture remains in first-party PLANK host source" >&2
  exit 1
fi
for required_native_x11_token in \
  'config.capture_source != ::video::capture_source_e::x11_native10' \
  'Rejecting unsupported generic X11 capture source' \
  'IPC_CREAT | 0600' \
  'segment_info.shm_perm.mode = 0600' \
  'xcb::shm_attach_checked' \
  'shmctl(img->shm_id, IPC_RMID, nullptr)' \
  'config_max_ref_frames.capture_source = capture_source_e::nvfbc_8bit' \
  'config_autoselect.capture_source = capture_source_e::nvfbc_8bit'; do
  rg -Fq "$required_native_x11_token" \
    "$x11_capture_source" "$source_dir/src/video.cpp" || {
    echo "explicit PLANK capture-source invariant is missing: ${required_native_x11_token}" >&2
    exit 1
  }
done
for required_native_x11_x264_token in \
  'scale_xrgb10_to_gbr10_rows' \
  'Native X11 x264 10-bit scaling:' \
  'validate_h264_high10_444_identity' \
  'video::encoding_mode_available(session.encoding_mode)' \
  'PlankEncodingModes", get_plank_encoding_modes()'; do
  rg -Fq "$required_native_x11_x264_token" "$source_dir/src" || {
    echo "Native X11 x264 invariant is missing: ${required_native_x11_x264_token}" >&2
    exit 1
  }
done
echo "host_native_x11_x264_gate=pass"
echo "host_legacy_x11_capture_absence_gate=pass"

# Virtual-display preparation augments the Autodesk Xorg baseline before GDM.
# It is opt-in, bounded to qualified layouts, and may not reconfigure a live
# display manager.
for required_display_token in \
  'startup_layout = physical' \
  'physical = preserve connected monitors' \
  'virtual = initialize one internal 1920x1080 output'; do
  rg -Fq "$required_display_token" \
    "$repo_dir/packaging/host/linux/config/plank-host.conf" || {
    echo "host display default is missing: ${required_display_token}" >&2
    exit 1
  }
done
for required_display_token in \
  'Before=display-manager.service' \
  'ExecStart=/usr/libexec/plank/plank-display-prepare' \
  'ReadWritePaths=/etc/X11/xorg.conf.d'; do
  rg -Fxq "$required_display_token" \
    "$repo_dir/packaging/host/linux/systemd/plank-display-prepare.service" || {
    echo "host display-preparation unit invariant is missing: ${required_display_token}" >&2
    exit 1
  }
done
for required_display_token in \
  'physical|virtual' \
  'active_layout=single' \
  'virtual-1.edid' \
  'refusing to change the display topology while the display manager is active'; do
  rg -Fq "$required_display_token" \
    "$repo_dir/packaging/host/linux/bin/plank-display-prepare" || {
    echo "host display-preparation helper invariant is missing: ${required_display_token}" >&2
    exit 1
  }
done
if rg -q 'virtual_mode_[12]' "$repo_dir/packaging/host/linux/config/plank-host.conf" ||
   rg -q 'key != "virtual_mode_[12]"|values\["virtual_mode_[12]"\]' \
     "$repo_dir/packaging/host/linux/bin/plank-display-prepare"; then
  echo "removed administrator virtual-mode settings remain in display packaging" >&2
  exit 1
fi
echo "host_display_startup_layout_gate=pass"

rg -Fxq \
  'X-PLANK-ApplicationId=la.instinctual.Plank.Host' \
  "$repo_dir/packaging/host/linux/systemd/plank-host.service" || {
  echo "host systemd metadata does not carry the canonical application ID" >&2
  exit 1
}
echo "host_application_id_gate=pass"

# Host runtime diagnostics are written privately to a bounded persistent file.
# Helper stdout/stderr uses separate product logs rather than journald. systemd
# owns the writable directory; logrotate bounds the low-volume helper logs.
rg -Fxq 'log_path = /var/log/plank/host.log' \
  "$repo_dir/packaging/host/linux/config/plank-host.conf" || {
  echo "host persistent log path is not configured" >&2
  exit 1
}
for required_log_directory_token in \
  'LogsDirectory=plank' \
  'LogsDirectoryMode=0700'; do
  rg -Fxq "$required_log_directory_token" \
    "$repo_dir/packaging/host/linux/systemd/plank-host.service" || {
    echo "host private systemd log directory invariant is missing: ${required_log_directory_token}" >&2
    exit 1
  }
done
for required_log_rotation_token in \
  'retained_log_file_count {10}' \
  'max_log_file_size {10U * 1024U * 1024U}' \
  'rotating_file_stream'; do
  rg -Fq "$required_log_rotation_token" \
    "$source_dir/src/logging.h" "$source_dir/src/logging.cpp" || {
    echo "host bounded log rotation invariant is missing: ${required_log_rotation_token}" >&2
    exit 1
  }
done
for unit_log_pair in \
  'plank-host.service:host-supervisor.log' \
  'plank-pam-broker.service:pam-broker.log' \
  'plank-display-prepare.service:display-prepare.log'; do
  unit_name=${unit_log_pair%%:*}
  log_name=${unit_log_pair#*:}
  unit_path="$repo_dir/packaging/host/linux/systemd/$unit_name"
  rg -Fxq 'LogsDirectory=plank' "$unit_path"
  rg -Fxq 'LogsDirectoryMode=0700' "$unit_path"
  rg -Fxq "StandardOutput=append:/var/log/plank/${log_name}" "$unit_path"
  rg -Fxq "StandardError=append:/var/log/plank/${log_name}" "$unit_path"
done
logrotate_policy="$repo_dir/packaging/host/linux/logrotate/plank-host"
for helper_log in host-supervisor.log pam-broker.log display-prepare.log; do
  rg -Fq "/var/log/plank/${helper_log}" "$logrotate_policy"
done
rg -Fxq '    size 10M' "$logrotate_policy"
rg -Fxq '    rotate 10' "$logrotate_policy"
rg -Fxq '    copytruncate' "$logrotate_policy"
rg -F -B5 -A1 'add_stream(stream)' "$source_dir/src/logging.cpp" |
  rg -Fq '!defined(__linux__)' || {
  echo "host Linux runtime logs are still mirrored to stdout" >&2
  exit 1
}
echo "host_persistent_logging_gate=pass"

host_source_commit=$(git -C "$source_dir" rev-parse HEAD)
env \
  BRANCH=plank-package \
  BUILD_VERSION="$package_version" \
  COMMIT="$host_source_commit" \
  cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_C_FLAGS=$PLANK_C_FILE_FLAGS" \
  "-DCMAKE_CXX_FLAGS=$PLANK_C_FILE_FLAGS" \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DSUNSHINE_ASSETS_DIR=share/plank \
  -DCMAKE_C_COMPILER=/opt/rh/gcc-toolset-14/root/usr/bin/gcc \
  -DCMAKE_CXX_COMPILER=/opt/rh/gcc-toolset-14/root/usr/bin/g++ \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
  -DCMAKE_CUDA_HOST_COMPILER=/opt/rh/gcc-toolset-14/root/usr/bin/g++ \
  -DFETCHCONTENT_SOURCE_DIR_BOOST="$boost_source_dir" \
  -DFFMPEG_PREPARED_BINARIES="$ffmpeg_dir" \
  -DBUILD_DOCS=OFF \
  -DBUILD_TESTS=OFF \
  -DSUNSHINE_ENABLE_CUDA=ON \
  -DSUNSHINE_ENABLE_DRM=ON \
  -DSUNSHINE_ENABLE_KMS=OFF \
  -DSUNSHINE_ENABLE_KWIN=OFF \
  -DSUNSHINE_ENABLE_PORTAL=OFF \
  -DSUNSHINE_ENABLE_VAAPI=ON \
  -DSUNSHINE_ENABLE_VULKAN=OFF \
  -DSUNSHINE_ENABLE_WAYLAND=OFF \
  -DSUNSHINE_ENABLE_X11=ON \
  -DSUNSHINE_ENABLE_XDG_PORTAL=OFF \
  -DPLANK_ENABLE_TRANSPORT=ON \
  -DPLANK_PRODUCT_BUILD=ON \
  -DPLANK_TRANSPORT_DIR="$plank_transport_dir" \
  -DPLANK_TRANSPORT_CARGO_FEATURES="$plank_transport_cargo_features"
cmake --build "$build_dir" --parallel "$build_jobs" \
  --target sunshine plank-pam-broker plank-host-supervisor

# Exercise the exact compiled transport policy, including real FEC/UDP and
# active/setup-promoted C ABI paths. BUILD_TESTS=OFF above is for the Host's
# hardware-dependent C++ suite, not permission to skip transport qualification.
(
  export CARGO_TARGET_DIR="$build_dir/plank-transport-cargo"
  # Qualify the shipping policy. There is no alternate application-paced mode.
  cargo test --locked --offline --release --features "$plank_transport_cargo_features" \
    --manifest-path "$plank_transport_dir/Cargo.toml"
  PLANK_TRANSPORT_CARGO_FEATURES="$plank_transport_cargo_features" SC_NATIVE_CARGO_PROFILE=release \
    bash "$repo_dir/scripts/test/run-plank-transport-native-loopback.sh"
  PLANK_TRANSPORT_CARGO_FEATURES="$plank_transport_cargo_features" \
    bash "$repo_dir/scripts/test/run-plank-transport-native-ffi-loopback.sh"
)
echo "host_transport_policy_loopback_gate=pass features=$plank_transport_cargo_features"

rg -a -Fq 'PLANK sender: controller-budget-floor-bps=1000000000' \
  "$build_dir/plank-host" || {
  echo "host binary is missing the shared sender budget policy" >&2
  exit 1
}
echo "host_send_budget_binary_gate=pass"

nm -C "$build_dir/plank-host" | \
  rg ' [Tt] plank_transport_abi_version$' >/dev/null || {
  echo "host binary does not link the PLANK transport ABI" >&2
  exit 1
}
rg -a -Fq 'PLANK native transport ABI ' \
  "$build_dir/plank-host" || {
  echo "host binary does not report the inactive plank_transport boundary" >&2
  exit 1
}
echo "host_plank_transport_link_gate=pass"

if rg -a -q '/usr/local/assets' "$build_dir/plank-host"; then
  echo "package binary contains the development asset path" >&2
  exit 1
fi
rg -a -q '/usr/share/plank' "$build_dir/plank-host"
rg -Fxq 'PLANK_PRODUCT_BUILD:BOOL=ON' "$build_dir/CMakeCache.txt" || {
  echo "host product build mode is not enabled" >&2
  exit 1
}
if find "$build_dir" -maxdepth 1 -type f \
  \( -name 'dev.lizardbyte.app.Sunshine*' -o -name 'app-dev.lizardbyte.app.Sunshine*' \) \
  -print -quit | rg -q .; then
  echo "host build generated inherited Sunshine application metadata" >&2
  exit 1
fi
for product_identity in \
  'PlankHost' \
  'Package Publisher: ' \
  'Instinctual' \
  'https://instinctual.la'; do
  rg -a -Fq "$product_identity" "$build_dir/plank-host" || {
    echo "host binary is missing product identity: ${product_identity}" >&2
    exit 1
  }
done
rg -Fq 'PROJECT_FQDN=\"la.instinctual.Plank.Host\"' \
  "$build_dir/CMakeFiles/sunshine.dir/flags.make" || {
  echo "host compiler definitions are missing the product application ID" >&2
  exit 1
}
for inherited_identity in \
  'dev.lizardbyte.app.Sunshine' \
  'https://app.lizardbyte.dev/support'; do
  if rg -a -Fq "$inherited_identity" "$build_dir/plank-host"; then
    echo "host binary retains inherited identity: ${inherited_identity}" >&2
    exit 1
  fi
done
echo "host_product_identity_gate=pass"
[[ ! -d ${build_dir}/assets/web ]] || {
  echo "host Web UI assets were produced" >&2
  exit 1
}
if nm -C "$build_dir/plank-host" | rg -q 'confighttp::'; then
  echo "host binary still contains the configuration HTTP server" >&2
  exit 1
fi
if rg -a -q 'Sunshine - Web UI|Configuration UI available at' "$build_dir/plank-host"; then
  echo "host binary still contains Web UI runtime paths" >&2
  exit 1
fi
if nm -C "$build_dir/plank-host" | rg -q 'nvhttp::(pair|pin|unpair_client|getservercert|clientchallenge|clientpairingsecret)'; then
  echo "host binary still contains legacy pairing code" >&2
  exit 1
fi

for required_desktop_token in \
  'inline constexpr int desktop_app_id = 881448767' \
  'inline constexpr std::string_view desktop_app_name = "Desktop"' \
  'std::atomic<int> _app_id {0}' \
  'Reserving PLANK Desktop stream'; do
  rg -Fq "$required_desktop_token" \
    "$source_dir/src/process.h" "$source_dir/src/process.cpp" || {
    echo "fixed Desktop reservation invariant is missing: ${required_desktop_token}" >&2
    exit 1
  }
done
for required_session_takeover_token in \
  'feature_session_takeover = 0x8000' \
  'PLANK workstation session is active' \
  'plankTakeover' \
  'PLANK_TRANSPORT_TERMINATION_SESSION_TAKEN_OVER' \
  'launch_owner_' \
  'plank_transport_native_endpoint_stop(endpoint);'; do
  rg -Fq "$required_session_takeover_token" \
    "$source_dir/src/nvhttp.cpp" \
    "$source_dir/src/plank_topology.h" \
    "$source_dir/src/session_stream.cpp" || {
    echo "host active-session takeover invariant is missing: ${required_session_takeover_token}" >&2
    exit 1
  }
done
echo "host_session_takeover_gate=pass"
rg -Fq 'if(WIN32 OR APPLE)' \
  "$source_dir/cmake/dependencies/Boost_Sunshine.cmake" || {
  echo "Boost.Process is not gated away from the Linux host build" >&2
  exit 1
}
if rg -n 'apps\.json|file_apps|global_prep_cmd|Steam Big Picture|Low Res Desktop' \
  "$source_dir/src" "$source_dir/src_assets" "$source_dir/cmake" \
  "$source_dir/packaging" "$source_dir/docs"; then
  echo "legacy application catalog or command-launch configuration remains" >&2
  exit 1
fi
if rg -n 'run_command|request_process_group_exit|process_group_running|open_url' \
  "$source_dir/src/platform/common.h" "$source_dir/src/platform/linux" \
  "$source_dir/tests/integration"; then
  echo "legacy Linux external-command launcher remains" >&2
  exit 1
fi
for removed_app_asset in box.png desktop-alt.png steam.png; do
  if find "$source_dir/src_assets" -type f -name "$removed_app_asset" -print -quit | rg -q .; then
    echo "legacy application artwork remains: ${removed_app_asset}" >&2
    exit 1
  fi
done
if rg -a -q 'apps\.json|Steam Big Picture|Low Res Desktop|SUNSHINE_APP_ID|SUNSHINE_APP_NAME' \
  "$build_dir/plank-host"; then
  echo "host binary still contains the legacy application catalog or launcher" >&2
  exit 1
fi
if nm -C "$build_dir/plank-host" | \
    rg -q 'platf::(run_command|request_process_group_exit|process_group_running|open_url)'; then
  echo "host binary still contains the legacy external-command launcher" >&2
  exit 1
fi
echo "host_fixed_desktop_reservation_gate=pass"

for required_reconnect_token in \
  'std::mutex session_start_mutex' \
  'session_stream::session_count() == 0' \
  'session_stream::launch_session_pending()' \
  'Clearing orphaned PLANK Desktop reservation before launch'; do
  rg -Fq "$required_reconnect_token" \
    "$source_dir/src/nvhttp.cpp" "$source_dir/src/session_stream.cpp" \
    "$source_dir/src/session_stream.h" || {
    echo "rapid reconnect host cleanup invariant is missing: ${required_reconnect_token}" >&2
    exit 1
  }
done
echo "host_rapid_reconnect_cleanup_gate=pass"

"${repo_dir}/scripts/package/audit-package-runtime.sh" "$build_dir/plank-host" >/dev/null

echo "host_web_ui_absence_gate=pass"
echo "host_binary=${build_dir}/plank-host"
echo "pam_broker_binary=${build_dir}/plank-pam-broker"
echo "host_supervisor_binary=${build_dir}/plank-host-supervisor"
echo "host_package_binary_gate=pass"
