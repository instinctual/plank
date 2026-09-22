#!/usr/bin/env bash

set -euo pipefail

if (($# < 2 || $# > 3)); then
  echo "usage: $0 PLANK_CLIENT_SOURCE_DIR FFMPEG_WORK_DIR [BUILD_DIR]" >&2
  exit 2
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source_dir=$(realpath -- "$1")
ffmpeg_work_dir=$(realpath -- "$2")
build_dir=$(realpath -m -- "${3:-${repo_dir}/build/package-client}")
ffmpeg_prefix="${ffmpeg_work_dir}/install"
source "$repo_dir/scripts/build/build-paths.sh"
plank_build_path_flags "$repo_dir" "$build_dir"
plank_native_dependency_flags
frame_flow_qmake=()
case ${PLANK_CLIENT_FRAME_FLOW_TRACE:-0} in
  0) ;;
  1) frame_flow_qmake+=(CONFIG+=plank-frame-flow-trace) ;;
  *) echo "PLANK_CLIENT_FRAME_FLOW_TRACE must be 0 or 1" >&2; exit 2 ;;
esac

for command_name in cc c++ cargo cmp diff find git make mktemp nm patch pkg-config qmake6 readelf realpath rg rustc sha256sum stat tar timeout; do
  command -v "$command_name" >/dev/null || {
    echo "required command is unavailable: ${command_name}" >&2
    exit 1
  }
done

# The exact HEVC Main444 10-bit VA-API path depends on the EGL/DMA-BUF
# frontend. Keep its qmake qualification test on native SDL3 and fail before
# compilation if a clean builder cannot provide either dependency. A stale
# SDL2 probe previously disabled HAVE_EGL silently and forced 4K software
# decoding on otherwise-qualified Intel hardware.
rg -Fxq 'PKGCONFIG += sdl3 egl libavcodec libavutil' \
  "$source_dir/config.tests/EGL/EGL.pro" || {
  echo "client EGL qualification test is not using native SDL3" >&2
  exit 1
}
for sdl3_egl_header in SDL_egl.h SDL_opengles2.h; do
  rg -Fq "#include <SDL3/${sdl3_egl_header}>" \
    "$source_dir/config.tests/EGL/main.cpp" || {
    echo "client EGL qualification test is not using SDL3 headers" >&2
    exit 1
  }
done
pkg-config --exists sdl3 egl || {
  echo "client EGL/DMA-BUF build dependencies are unavailable" >&2
  exit 1
}
echo "client_egl_build_input_gate=pass"

identity_gbr_patch="$source_dir/app/deploy/linux/ffmpeg-patches/0001-hevc-enable-hwaccel-for-identity-gbr.patch"
identity_gbr_patch_sha256=059cc9c0d585d71e292cd7421a43f239b1e7ce94e8598d0a7427dfe48e55847e
ffmpeg_archive_sha256=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
ffmpeg_identity_source_sha256=f3e5ce5ab334c0bc39661dccd68dcc91f90c47fcaae72d3c20511088f71387e8
ffmpeg_archive="$ffmpeg_work_dir/ffmpeg-9.0.1.tar.xz"
ffmpeg_identity_source="$ffmpeg_work_dir/ffmpeg-9.0.1/libavcodec/hevc/hevcdec.c"
[[ -f ${identity_gbr_patch} && -f ${ffmpeg_archive} && -f ${ffmpeg_identity_source} ]] || {
  echo "client identity-GBR FFmpeg source inputs are unavailable" >&2
  exit 1
}
printf '%s  %s\n' "$identity_gbr_patch_sha256" "$identity_gbr_patch" |
  sha256sum --check --status
patch --batch --reverse --no-backup-if-mismatch --dry-run \
  -d "$ffmpeg_work_dir/ffmpeg-9.0.1" -p1 \
  < "$identity_gbr_patch" >/dev/null 2>&1 || {
  echo "prepared Client FFmpeg is missing the identity-GBR hardware-decode patch" >&2
  exit 1
}
if find "$ffmpeg_work_dir/ffmpeg-9.0.1" -type f \
    \( -name '*.orig' -o -name '*.rej' \) -print -quit | grep -q .; then
  echo "prepared Client FFmpeg contains patch backup or reject files" >&2
  exit 1
fi
printf '%s  %s\n' "$ffmpeg_archive_sha256" "$ffmpeg_archive" |
  sha256sum --check --status
printf '%s  %s\n' "$ffmpeg_identity_source_sha256" "$ffmpeg_identity_source" |
  sha256sum --check --status
ffmpeg_source_audit_dir=$(mktemp -d --tmpdir plank-client-ffmpeg-source-audit.XXXXXX)
cleanup_ffmpeg_source_audit() {
  find "$ffmpeg_source_audit_dir" -depth -type f -delete
  find "$ffmpeg_source_audit_dir" -depth -type l -delete
  find "$ffmpeg_source_audit_dir" -depth -type d -empty -delete
}
trap cleanup_ffmpeg_source_audit EXIT
tar -xJf "$ffmpeg_archive" -C "$ffmpeg_source_audit_dir"
if ! diff -qr --exclude=hevcdec.c \
    "$ffmpeg_source_audit_dir/ffmpeg-9.0.1" \
    "$ffmpeg_work_dir/ffmpeg-9.0.1"; then
  echo "prepared Client FFmpeg contains changes beyond the tracked identity-GBR patch" >&2
  exit 1
fi
cleanup_ffmpeg_source_audit
trap - EXIT
echo "client_ffmpeg_pristine_source_gate=pass"
echo "client_ffmpeg_identity_gbr_patch_gate=pass"

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
rg -q '^#define PLANK_TRANSPORT_ABI_VERSION 13u$' \
  "${plank_transport_dir}/include/plank_transport.h" || {
  echo "client requires PLANK transport ABI 13" >&2
  exit 1
}
rg -Fq 'uint32_t max_udp_payload_size;' \
  "${plank_transport_dir}/include/plank_transport.h" || {
  echo "client PLANK transport is missing the route MTU contract" >&2
  exit 1
}
rg -Fq 'uint32_t initial_video_bitrate_kbps;' \
  "${plank_transport_dir}/include/plank_transport.h" || {
  echo "client PLANK transport is missing the encoder-rate contract" >&2
  exit 1
}
echo "client_plank_transport_rust_input_gate=pass"

# The PLANK client must not contact upstream Moonlight services or
# offer help actions that leave the appliance UI. Network reachability is
# evaluated against the configured workstation and its selected route only.
if rg -n 'moonlight-stream\.org/compatibility|qt\.conntest\.moonlight-stream\.org|stun\.moonlight-stream\.org|moonlight-docs|Qt\.openUrlExternally|Dialog\.Help|helpUrl' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "upstream Moonlight network or help integration remains in PLANK client" >&2
  exit 1
fi
echo "client_upstream_network_absence_gate=pass"

# PLANK exposes one authenticated Desktop session. Keep the hidden
# game catalog, artwork downloader, and CLI app-list surface out of the build.
if rg -n 'AppView|AppModel|BoxArtManager|CliListApps|ListCommandLineParser|View All Apps|cli/listapps' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "legacy game catalog remains in PLANK client" >&2
  exit 1
fi
echo "client_game_catalog_absence_gate=pass"

# The workstation model exposes only the active PLANK bookmark and
# Desktop-session contract. Do not restore Moonlight's running-game model
# roles or generic current-game session launcher.
if rg -n 'BusyRole|PlankAuthenticationRole|createSessionForCurrentGame' \
  "$source_dir/app/gui/computermodel.h" \
  "$source_dir/app/gui/computermodel.cpp"; then
  echo "legacy ComputerModel game/session surface remains" >&2
  exit 1
fi
echo "client_computer_model_legacy_surface_absence_gate=pass"

# Host/profile capability negotiation replaces NVIDIA GFE version heuristics.
if rg -n 'CompatFetcher|isSupportedServerVersion|SER_NVIDIASOFTWARE|GeForce Experience 3\.0' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "legacy GeForce Experience compatibility gate remains in PLANK client" >&2
  exit 1
fi
echo "client_gfe_compatibility_absence_gate=pass"

for required_plank_transport_token in \
  'PlankTransportCertificateSha256' \
  'isCanonicalSha256Hex' \
  'startPlankTransportDataPlane' \
  'negotiatePlankTransportSession' \
  'PLANK_TRANSPORT_SETUP_LAUNCH_REQUEST' \
  'plank_transport_native_video_receive' \
  'LiSubmitPlankVideoFrame' \
  'plank_transport_native_audio_receive' \
  'LiSubmitPlankAudioPacket' \
  'LiSetPlankNativeControlSender' \
  'plankTransportNativeControlSender' \
  'plankTransportDataReceiveLoop'; do
  rg -Fq "$required_plank_transport_token" \
    "$source_dir/app" || {
    echo "client plank_transport negotiation invariant is missing: ${required_plank_transport_token}" >&2
    exit 1
  }
done
echo "client_plank_transport_negotiation_gate=pass"
for removed_data_plane_selector_token in \
  'plank-data-plane' \
  'plankDataPlane' \
  'PlankDataPlane' \
  'SCDP_LEGACY' \
  'PLANK_DATA_PLANE' \
  'Legacy PLANK transport' \
  'PlankTransport single-port transport (Experimental)'; do
  if rg -Fq "$removed_data_plane_selector_token" "$source_dir/app"; then
    echo "obsolete client data-plane selector remains: ${removed_data_plane_selector_token}" >&2
    exit 1
  fi
done
echo "client_plank_transport_selector_absence_gate=pass"
for required_audio_transport_token in \
  'LiSubmitPlankVideoFrame' \
  'LiSubmitPlankAudioPacket' \
  'PLANK_VIDEO_FRAME_FLAG_KEY'; do
  rg -Fq "$required_audio_transport_token" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src" || {
    echo "client native media transport invariant is missing: ${required_audio_transport_token}" >&2
    exit 1
  }
done
echo "client_plank_transport_native_media_gate=pass"
for removed_legacy_media_token in \
  'LiSetPlankNativeMediaEnabled' \
  'PlankNativeMediaEnabled' \
  'VideoPingThreadProc' \
  'VideoReceiveThreadProc' \
  'AudioPingThreadProc' \
  'AudioReceiveThreadProc' \
  'RtpvAddPacket' \
  'RtpaAddPacket'; do
  if rg -Fq "$removed_legacy_media_token" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src/VideoStream.c" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src/AudioStream.c" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src/Connection.c" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src/Limelight.h" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src/Limelight-internal.h"; then
    echo "obsolete client media transport remains: ${removed_legacy_media_token}" >&2
    exit 1
  fi
done
echo "client_plank_transport_legacy_media_absence_gate=pass"
if rg -n '^#define STREAM_CFG_(LOCAL|REMOTE|AUTO)|^[[:space:]]*int (packetSize|streamingRemotely);' \
  "$source_dir/moonlight-common-c/moonlight-common-c/src/Limelight.h"; then
  echo "obsolete GameStream route and packet-size policy remains in client common-c" >&2
  exit 1
fi
echo "client_gamestream_packet_policy_absence_gate=pass"
for removed_media_bridge_token in \
  'PlankVideoPacketReceiver' \
  'PlankAudioPacketReceiver'; do
  if rg -Fq "$removed_media_bridge_token" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src" \
    "$source_dir/app/streaming"; then
    echo "obsolete tunneled media bridge remains: ${removed_media_bridge_token}" >&2
    exit 1
  fi
done
echo "client_plank_transport_legacy_media_bridge_absence_gate=pass"
for required_control_transport_token in \
  'PlankNativeControlSender' \
  'LI_SC_NATIVE_CONTROL_REQUEST_IDR' \
  'LI_SC_NATIVE_CONTROL_INVALIDATE_REFERENCE_FRAMES' \
  'LI_SC_NATIVE_CONTROL_SET_VIDEO_BITRATE'; do
  rg -Fq "$required_control_transport_token" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src" || {
    echo "client external control transport invariant is missing: ${required_control_transport_token}" >&2
    exit 1
  }
done
echo "client_plank_transport_native_control_sender_gate=pass"
for required_input_transport_token in \
  'PlankNativeInputSender' \
  'LiSetPlankNativeInputSender' \
  'plankTransportNativeInputSender' \
  'plank_transport_native_input_send' \
  'PLANK_TRANSPORT_INPUT_RAW_HID_WACOM'; do
  rg -Fq "$required_input_transport_token" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src" \
    "$source_dir/app/streaming" \
    "$plank_transport_dir/include" || {
    echo "client native input transport invariant is missing: ${required_input_transport_token}" >&2
    exit 1
  }
done
echo "client_plank_transport_native_input_gate=pass"
for required_event_transport_token in \
  'plank_transport_event.h' \
  'PLANK_TRANSPORT_EVENT_CURSOR_SHAPE' \
  'LiNotifyPlankHdrMode' \
  'LiNotifyPlankRawHidControl' \
  'LiNotifyPlankCursorPosition'; do
  rg -Fq "$required_event_transport_token" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src" \
    "$source_dir/app/streaming" \
    "$plank_transport_dir/include" || {
    echo "client native event transport invariant is missing: ${required_event_transport_token}" >&2
    exit 1
  }
done
echo "client_plank_transport_native_event_gate=pass"
for required_control_receiver_token in \
  'plank_transport_control.h' \
  'LiNotifyPlankVideoBitrateApplied' \
  'LiNotifyPlankHostTermination' \
  'plank_transport_native_data_receive' \
  'plankTransportDataReceiveLoop'; do
  if ! rg -Fq "$required_control_receiver_token" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src" \
    "$source_dir/app/streaming"; then
    echo "client external control receiver invariant is missing: ${required_control_receiver_token}" >&2
    exit 1
  fi
done
echo "client_plank_transport_native_control_receiver_gate=pass"
for removed_control_bridge_token in \
  'PlankControlPacketSender' \
  'PlankControlPacketReceiver' \
  'externalControlPacketSender' \
  'externalControlPacketReceiver' \
  'plank_transportControlPacketSender' \
  'plank_transportControlPacketReceiver'; do
  if rg -Fq "$removed_control_bridge_token" \
    "$source_dir/moonlight-common-c/moonlight-common-c/src" \
    "$source_dir/app/streaming"; then
    echo "obsolete encrypted control bridge remains: ${removed_control_bridge_token}" >&2
    exit 1
  fi
done
echo "client_plank_transport_legacy_control_bridge_absence_gate=pass"
echo "client_plank_transport_control_receiver_gate=pass"

source "${repo_dir}/scripts/package/package-version.sh"
plank_load_package_version "$repo_dir"
package_version=$PLANK_PACKAGE_VERSION

[[ -f ${source_dir}/moonlight-qt.pro ]] || {
  echo "Moonlight source tree is unavailable: ${source_dir}" >&2
  exit 1
}
if [[ -n $(git -C "$source_dir" status --porcelain) ]]; then
  echo "Moonlight source tree is dirty; refusing a package build" >&2
  exit 1
fi
submodule_status=$(git -C "$source_dir" submodule status --recursive)
if rg -q '^[+-U]' <<<"$submodule_status"; then
  echo "Moonlight recursive submodules are missing or not at their pinned commits:" >&2
  printf '%s\n' "$submodule_status" >&2
  exit 1
fi
if [[ -d ${build_dir} && -n $(find "$build_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  echo "package build directory is not empty: ${build_dir}" >&2
  exit 1
fi

# PLANK is a remote-workstation client. Controller input and
# controller-driven UI navigation are deliberately outside the product scope.
for removed_path in \
  app/SDL_GameControllerDB \
  app/gui/GamepadMapper.qml \
  app/gui/sdlgamepadkeynavigation.cpp \
  app/gui/sdlgamepadkeynavigation.h \
  app/settings/mappingfetcher.cpp \
  app/settings/mappingfetcher.h \
  app/settings/mappingmanager.cpp \
  app/settings/mappingmanager.h \
  app/streaming/input/gamepad.cpp; do
  [[ ! -e ${source_dir}/${removed_path} ]] || {
    echo "gamepad support is present in PLANK client source: ${removed_path}" >&2
    exit 1
  }
done
if rg -n \
  'SdlGamepadKeyNavigation|SDL_INIT_(JOYSTICK|GAMECONTROLLER)|Gamepad Settings|multi-controller|background-gamepad|swap-gamepad-buttons' \
  "$source_dir/app" \
  --glob '!**/languages/**' \
  --glob '!**/Info.plist'; then
  echo "gamepad support or controller UI navigation is present in PLANK client source" >&2
  exit 1
fi
echo "client_gamepad_absence_gate=pass"

# PLANK uses per-session operating-system authentication. It has no
# GameStream PIN workflow or persistent client-certificate identity.
for removed_path in \
  app/backend/identitymanager.cpp \
  app/backend/identitymanager.h \
  app/backend/nvpairingmanager.cpp \
  app/backend/nvpairingmanager.h \
  app/cli/pair.cpp \
  app/cli/pair.h \
  app/gui/CliPair.qml; do
  [[ ! -e ${source_dir}/${removed_path} ]] || {
    echo "legacy pairing source is present in PLANK client: ${removed_path}" >&2
    exit 1
  }
done
if rg -n \
  'IdentityManager|NvPairingManager|PendingPairingTask|PairRequested|pairComputer|generatePinString|setServerCert|serverCert' \
  "$source_dir/app" \
  --glob '!**/languages/**' \
  --glob '!**/deploy/**'; then
  echo "legacy PIN or persistent client-certificate workflow is present in PLANK client" >&2
  exit 1
fi
echo "client_pairing_absence_gate=pass"

if rg -n \
  'PLANK_VPN_INTERFACE|isApprovedPlankRoute|approved VPN route' \
  "$source_dir/app"; then
  echo "client-side VPN route restriction is present in PLANK" >&2
  exit 1
fi
echo "client_vpn_route_check_absence_gate=pass"

# PLANK Client is launched explicitly from its desktop entry or
# command. It must not ship or manage a background user service or autostart
# entry.
[[ ! -e ${repo_dir}/packaging/client/linux/systemd/plank-client.service ]] || {
  echo "client systemd user service remains in package source" >&2
  exit 1
}
if find "$repo_dir/packaging" -path '*/autostart/*' -print -quit | rg -q .; then
  echo "client desktop autostart entry remains in package source" >&2
  exit 1
fi
if rg -n 'plank-client\.service|deb-systemd-helper|systemctl[[:space:]]+--user' \
  "$repo_dir/packaging/client/linux/deb/postinst" "$repo_dir/packaging/client/linux/deb/postrm"; then
  echo "client maintainer scripts retain user-service or autostart handling" >&2
  exit 1
fi
echo "client_autostart_absence_gate=pass"

# PLANK disconnects streams without changing the physical workstation
# display or terminating the workstation application. Keep Moonlight's legacy
# SOPS and remote app-cancel controls out of the product.
for removed_path in \
  app/cli/quitstream.cpp \
  app/cli/quitstream.h \
  app/gui/CliQuitStreamSegue.qml \
  app/gui/QuitSegue.qml \
  app/streaming/input/abstouch.cpp \
  app/streaming/input/reltouch.cpp; do
  [[ ! -e ${source_dir}/${removed_path} ]] || {
    echo "remote host-control source is present: ${removed_path}" >&2
    exit 1
  }
done
if rg -n \
  'Host Settings|gameOptimizations|quitAppAfter|quitRunningApp|quitAppCompleted|unlockBitrate|Unlock bitrate limit|absoluteTouchMode|swapMouseButtons|reverseScrollDirection|absoluteMouseMode|touchscreen-trackpad|mouse-buttons-swap|reverse-scroll-direction|absolute-mouse|Use touchscreen as a virtual trackpad|Swap left and right mouse buttons|Reverse mouse scrolling direction|Optimize mouse for remote desktop|KeyComboToggleMouseMode|SDL_FINGER(DOWN|MOTION|UP)|LiSendTouchEvent|SDL_(Get|Set)RelativeMouseMode|[?&]sops=|game-optimization|quit-after' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "legacy SOPS or remote app termination is present in PLANK client" >&2
  exit 1
fi
echo "client_remote_host_control_absence_gate=pass"

# Focus loss must stop local raw-Wacom forwarding without sending the
# destructive detach that removes and recreates host UHID/XInput endpoints.
client_common_dir="${source_dir}/moonlight-common-c/moonlight-common-c/src"
printf '#include "Limelight.h"\nint main() { return 0; }\n' |
  c++ -std=c++17 -fsyntax-only -I"$client_common_dir" -x c++ - || {
    echo "Limelight.h is not a self-contained public C++ header" >&2
    exit 1
  }
echo "client_limelight_header_gate=pass"
for required_raw_hid_token in \
  '#define PLANK_RAW_HID_WIRE_VERSION 2U' \
  'PLANK_RAW_HID_SUSPEND = 13'; do
  rg -Fq "$required_raw_hid_token" "$client_common_dir" || {
    echo "client raw-HID focus-suspend protocol invariant is missing: ${required_raw_hid_token}" >&2
    exit 1
  }
done
rg -q '#define[[:space:]]+LI_FF_RAW_HID_FOCUS_SUSPEND[[:space:]]+0x20' \
  "$client_common_dir/Limelight.h" || {
  echo "client raw-HID focus-suspend feature bit is missing" >&2
  exit 1
}
for required_raw_hid_token in \
  LI_FF_RAW_HID_FOCUS_SUSPEND \
  suspendForFocusLoss \
  'sendFrame(PLANK_RAW_HID_SUSPEND, 0, 0, nullptr, 0)'; do
  rg -Fq "$required_raw_hid_token" \
    "$source_dir/app/streaming/input/input.cpp" \
    "$source_dir/app/streaming/input/linuxrawwacom.cpp" \
    "$source_dir/app/streaming/input/linuxrawwacom.h" || {
    echo "client raw-HID focus-suspend invariant is missing: ${required_raw_hid_token}" >&2
    exit 1
  }
done
rg -U -q 'void LinuxRawWacomInput::setActive\(bool active\)(.|\n)*?if \(!active\) \{(.|\n)*?suspendForFocusLoss\(\);' \
  "$source_dir/app/streaming/input/linuxrawwacom.cpp" || {
  echo "client focus loss does not use non-destructive raw-HID suspension" >&2
  exit 1
}
echo "client_raw_hid_focus_suspend_gate=pass"

# A reconnect must prevent the raw-tablet worker from attaching while the
# replacement control stream is only partially initialized. A bounded attach
# acknowledgement timeout ensures a lost reply cannot leave reports disabled
# for the rest of the session.
for required_raw_hid_reconnect_token in \
  beginRawHidReconnect \
  finishRawHidReconnect \
  'm_Reconnecting.load()' \
  'Timed out waiting for exact Wacom host attachment; retrying'; do
  rg -Fq "$required_raw_hid_reconnect_token" \
    "$source_dir/app/streaming/session.cpp" \
    "$source_dir/app/streaming/input/input.cpp" \
    "$source_dir/app/streaming/input/linuxrawwacom.cpp" || {
    echo "client raw-HID reconnect barrier is missing: ${required_raw_hid_reconnect_token}" >&2
    exit 1
  }
done
echo "client_raw_hid_reconnect_gate=pass"

# First-generation Intuos Pro S/M/L USB interfaces require hid-wacom's real
# USB interface type, which Linux UHID cannot reproduce. Keep the complete
# PTH-x51 family on the existing normalized core-pen path while all newer
# in-scope Wacoms continue to use descriptor-driven exact raw-HID forwarding.
for required_wacom_generation_token in \
  'case 0x0314: // PTH-451' \
  'case 0x0315: // PTH-651' \
  'case 0x0317: // PTH-851' \
  'return PlankWacomTransport::NormalizedPen;' \
  'return PlankWacomTransport::ExactRawHid;' \
  'Using normalized pen transport for first-generation Intuos Pro'; do
  rg -Fq "$required_wacom_generation_token" \
    "$source_dir/app/streaming/input/input.cpp" \
    "$source_dir/app/streaming/input/linuxrawwacom.cpp" \
    "$source_dir/app/streaming/input/linuxrawwacom.h" || {
    echo "client Wacom generation transport invariant is missing: ${required_wacom_generation_token}" >&2
    exit 1
  }
done
echo "client_wacom_generation_transport_gate=pass"

# PLANK uses one compositor-owned local cursor across the stream and
# toolbar. Exact host cursor images arrive on the native KyProto event lane;
# the client must not fall back to synchronizing a cursor embedded in video.
for required_cursor_token in \
  'PLANK_CURSOR_WIRE_VERSION 1U' \
  'PLANK_CURSOR_MAX_CHUNK_SIZE (48U * 1024U)' \
  'LiNotifyPlankCursorChunk' \
  'ML_FF_LOCAL_CURSOR' \
  'LI_FF_LOCAL_CURSOR'; do
  rg -Fq "$required_cursor_token" "$client_common_dir" || {
    echo "client local-cursor protocol invariant is missing: ${required_cursor_token}" >&2
    exit 1
  }
done
if rg -Fq '0x5507' "$client_common_dir/ControlStream.c"; then
  echo "client still contains the retired GameStream cursor message" >&2
  exit 1
fi
for required_cursor_token in \
  handleRemoteCursorChunk \
  applyPendingRemoteCursor \
  SDL_CreateColorCursor \
  SDL_CODE_PLANK_CURSOR; do
  rg -Fq "$required_cursor_token" \
    "$source_dir/app/streaming/input/input.cpp" \
    "$source_dir/app/streaming/input/input.h" \
    "$source_dir/app/streaming/session.cpp" || {
    echo "client local-cursor renderer invariant is missing: ${required_cursor_token}" >&2
    exit 1
  }
done
if rg -Fq 'forwardNativePointerPosition' "$source_dir/app/streaming"; then
  echo "client still forwards toolbar motion to synchronize a video cursor" >&2
  exit 1
fi
echo "client_local_cursor_gate=pass"

# Native KyProto reconstructs video and audio before common-c submission.
# Retired GameStream RTP queues and their second Reed-Solomon implementation
# must not remain compiled into the native-only client.
client_common_root="${source_dir}/moonlight-common-c/moonlight-common-c"
for retired_fec_path in \
  nanors \
  src/RtpAudioQueue.c \
  src/RtpAudioQueue.h \
  src/RtpVideoQueue.c \
  src/RtpVideoQueue.h; do
  [[ ! -e "${client_common_root}/${retired_fec_path}" ]] || {
    echo "retired client FEC path is present: ${retired_fec_path}" >&2
    exit 1
  }
done
if rg -n 'nanors|Rtp(Audio|Video)Queue|reed_solomon_' \
  "${source_dir}/moonlight-common-c/moonlight-common-c.pro" \
  "$client_common_root/CMakeLists.txt" \
  "$client_common_root/src"; then
  echo "retired client RTP/Reed-Solomon integration is present" >&2
  exit 1
fi
echo "client_legacy_media_fec_absence_gate=pass"

# Native KyProto submits complete reconstructed frames. Keep the compact
# frame-assembler path and reject the dormant GameStream RTP depacketizer,
# packet-buffer helpers, and packet-era recovery symbols.
[[ -f "${client_common_root}/src/VideoFrameAssembler.c" ]] || {
  echo "native complete-frame assembler is missing" >&2
  exit 1
}
for retired_video_path in \
  src/VideoDepacketizer.c \
  src/LegacyRtpVideoPacket.h \
  src/ByteBuffer.c \
  src/ByteBuffer.h; do
  [[ ! -e "${client_common_root}/${retired_video_path}" ]] || {
    echo "retired client packet assembly path is present: ${retired_video_path}" >&2
    exit 1
  }
done
if rg -n 'queueRtpPacket|notifyFrameLost|NV_VIDEO_PACKET|RTP_PACKET|VideoDepacketizer|LegacyRtpVideoPacket|ByteBuffer' \
  "${source_dir}/moonlight-common-c/moonlight-common-c.pro" \
  "$client_common_root/CMakeLists.txt" \
  "$client_common_root/src"; then
  echo "retired client RTP depacketizer integration is present" >&2
  exit 1
fi
echo "client_complete_frame_assembler_gate=pass"

# KyProto encrypts native media, input, event, and runtime session negotiation
# traffic. The Client must configure common-c through the mandatory native
# boundary and must not retain the retired GameStream RTSP setup implementation.
for required_native_setup_token in \
  LiSetPlankNativeSessionConfiguration \
  PLANK_NATIVE_SESSION_CONFIGURATION \
  hostFeatureFlags \
  referenceFrameInvalidationSupported; do
  rg -Fq "$required_native_setup_token" \
    "$source_dir/app/streaming/session.cpp" "$client_common_root/src" || {
    echo "client native setup invariant is missing: ${required_native_setup_token}" >&2
    exit 1
  }
done
echo "client_native_setup_gate=pass"
if rg -n 'ENCFLG_|encryptionFlags|EncryptionFeatures|AudioEncryptionEnabled|SS_ENC_|x-ss-general\.encryptionEnabled|hasFastAes|NVFF_AUDIO_ENCRYPTION' \
  "$source_dir/app" "$client_common_root/src"; then
  echo "retired client GameStream media-encryption negotiation is present" >&2
  exit 1
fi
for retired_rtsp_path in \
  src/RtspConnection.c \
  src/RtspParser.c \
  src/Rtsp.h \
  src/SdpGenerator.c; do
  [[ ! -e "${client_common_root}/${retired_rtsp_path}" ]] || {
    echo "retired client RTSP setup path is present: ${retired_rtsp_path}" >&2
    exit 1
  }
done
if rg -n 'performRtspHandshake|rtspSessionUrl|sessionUrl0|rikeyid|remoteInputAes|ENCRYPTED_RTSP_BIT|rtspenc://' \
  "$source_dir/app" "$client_common_root/src" \
  "${source_dir}/moonlight-common-c/moonlight-common-c.pro"; then
  echo "retired client RTSP setup integration is present" >&2
  exit 1
fi
echo "client_rtsp_absence_gate=pass"

# Bootstrap, polling, PAM authentication, and launch must use the one HTTPS
# control endpoint. Reject the retired unauthenticated HTTP discovery URL,
# split-port state, and TCP 47984 connectivity flag.
for retired_bootstrap_token in \
  'DEFAULT_HTTP_PORT' \
  'DEFAULT_HTTPS_PORT' \
  'm_BaseUrlHttp' \
  'activeHttpsPort' \
  'ML_PORT_FLAG_TCP_47984' \
  'ML_PORT_INDEX_TCP_47984' \
  '47984'; do
  if rg -Fwq "$retired_bootstrap_token" \
      "$source_dir/app/backend" "$client_common_root/src"; then
    echo "retired client bootstrap transport remains: ${retired_bootstrap_token}" >&2
    exit 1
  fi
done
rg -Fq 'static constexpr quint16 BuiltInNetworkPort = 28989;' \
  "$source_dir/app/settings/plankclientpolicy.h" || {
  echo "client built-in control-port fallback is missing" >&2
  exit 1
}
if rg -Fq '.arg(DEFAULT_CONTROL_PORT)' \
    "$source_dir/app/streaming/session.cpp"; then
  echo "client connection diagnostics still hardcode the default UDP endpoint" >&2
  exit 1
fi
[[ $(rg -Fc 's_ActiveSession->m_Computer->activeAddress.port()' \
      "$source_dir/app/streaming/session.cpp") -ge 2 ]] || {
  echo "client connection diagnostics do not use the active host endpoint" >&2
  exit 1
}
for retired_network_path in \
  src/ConnectionTester.c \
  src/SimpleStun.c; do
  [[ ! -e "${client_common_root}/${retired_network_path}" ]] || {
    echo "retired client network probe remains: ${retired_network_path}" >&2
    exit 1
  }
done
if rg -n 'LiFindExternalAddressIP4|LiTestClientConnectivity|LiGetPortFlagsFromStage|LiStringifyPortFlags|ML_PORT_FLAG_' \
    "$source_dir/app" "$client_common_root/src" \
    "${source_dir}/moonlight-common-c/moonlight-common-c.pro"; then
  echo "retired client STUN or connectivity-test API remains" >&2
  exit 1
fi
echo "client_legacy_network_probe_absence_gate=pass"
echo "client_https_only_bootstrap_gate=pass"

# Native KyProto owns reliable control and input. The client must not retain
# ENet source, build wiring, submodule state, or obsolete SDP advertisements.
for retired_enet_path in \
  .gitmodules \
  enet; do
  [[ ! -e "${client_common_root}/${retired_enet_path}" ]] || {
    echo "retired client ENet path is present: ${retired_enet_path}" >&2
    exit 1
  }
done
if rg -n -i '\benet\b|useReliableUdp|useControlChannel' \
  "${source_dir}/moonlight-common-c/moonlight-common-c.pro" \
  "$client_common_root/CMakeLists.txt" \
  "$client_common_root/src"; then
  echo "retired client ENet integration is present" >&2
  exit 1
fi
echo "client_legacy_enet_absence_gate=pass"

# Keep the compact toolbar and on-screen presentation ready for the native
# KyProto loss sample. Do not restore a dormant GameStream FEC queue merely to
# produce this statistic.
for required_loss_ui_token in \
  'm_CurrentVideoFecLoss' \
  'currentVideoFecLoss' \
  'VideoPacketLossInterval' \
  'VideoPacketLossPeakWindow' \
  'kWindowMs = 10000' \
  'inline constexpr int VideoPacketLossDisplayDecimalPlaces = 2;' \
  'video_fec_source_symbols' \
  'video_fec_source_symbols_missing' \
  'video_fec_source_symbols_unrecovered' \
  'videoFecLoss.after' \
  'Frame rate (network/decode/render): %.2f/%.2f/%.2f FPS' \
  'Incoming video packet loss (before/after FEC): %s/%s' \
  'Client frame queue drops (%%/render/overflow): %.2f%%/%u/%u' \
  'Frame time (decode/queue/render incl. V-sync): %.2f/%.2f/%.2f ms' \
  'currentNetworkRttMs' \
  'quic_rtt_us' \
  'packetLossColor' \
  'const QColor blue(52, 132, 228)' \
  'const QColor green(52, 199, 110)' \
  'const QColor red(239, 88, 88)' \
  'clampedLoss <= 5.0' \
  '(clampedLoss - 5.0) / 5.0' \
  'QString("%1%").arg(m_PacketLossPercent' \
  'QRect(174, 16, 52, 17)' \
  'return toolbarLeft() + PlankToolbarStats::EncoderTargetLeft' \
  'Network RTT: %s' \
  'PlankToolbarStats::networkRttText(stats.lastRtt)' \
  'PlankToolbarStats::networkRttText(m_NetworkRttMs)'; do
  rg -Fq "$required_loss_ui_token" \
    "$source_dir/app/streaming/session.cpp" \
    "$source_dir/app/streaming/session.h" \
    "$source_dir/app/streaming/videopacketlosswindow.h" \
    "$source_dir/app/streaming/planktoolbar.cpp" \
    "$source_dir/app/streaming/planktoolbar.h" \
    "$source_dir/app/streaming/video/ffmpeg.cpp" || {
    echo "video packet-loss toolbar invariant is missing: ${required_loss_ui_token}" >&2
    exit 1
  }
done

for retired_stats_token in \
  'LiGetEstimatedRttInfo' \
  'Frames dropped by your network connection' \
  'Frames dropped due to network jitter' \
  'Client pacer drops by reason' \
  'Incoming frame rate from network' \
  'Decoding frame rate' \
  'Rendering frame rate' \
  'Average decoding time' \
  'Average frame queue delay' \
  'Average rendering time' \
  'Frames dropped by client frame queues' \
  'Client frame queue drops by reason' \
  'Incoming video packet loss (before FEC)' \
  'Incoming video frame loss (after FEC)'; do
  if rg -Fq "$retired_stats_token" \
    "$source_dir/app/streaming" \
    "$client_common_root/src"; then
    echo "retired client statistics token remains: ${retired_stats_token}" >&2
    exit 1
  fi
done
if rg -Fq '(float)stats.networkDroppedFrames / stats.totalFrames * 100' \
    "$source_dir/app/streaming/video/ffmpeg.cpp"; then
  echo "after-FEC packet loss must not be derived from frame gaps" >&2
  exit 1
fi
echo "client_video_packet_loss_indicator_gate=pass"

# PLANK presents immediately and keeps the optional upstream software
# frame pacer out of user policy. A renderer may still force its internal pacer
# when required for backend correctness.
if rg -n -i \
  'frame.?pacing|SER_FRAMEPACING|framePacing' \
  "$source_dir/app/gui/SettingsView.qml" \
  "$source_dir/app/settings/streamingpreferences.cpp" \
  "$source_dir/app/settings/streamingpreferences.h" \
  "$source_dir/app/cli/commandlineparser.cpp"; then
  echo "obsolete client frame-pacing preference remains" >&2
  exit 1
fi
rg -Fq 'params.enableFramePacing = false;' \
  "$source_dir/app/streaming/session.cpp" || {
  echo "PLANK unpaced presentation policy is missing" >&2
  exit 1
}
echo "client_frame_pacing_preference_absence_gate=pass"

# The speed candidate keeps the accepted system-memory allocator as its
# default and exposes two developer-only alternatives through an environment
# selector. The mapped allocator is the measured reference experiment. The
# host-import allocator preserves cacheable FFmpeg reference frames while
# importing their allocations as Vulkan transfer buffers, avoiding the Intel
# driver's CPU linear-to-tiled upload path.
for required_frame_allocator_token in \
  'static int getMappedBuffer(AVCodecContext *context, AVFrame *frame, int flags);' \
  'static int getImportedHostBuffer(AVCodecContext *context, AVFrame *frame, int flags);' \
  'mappedContext.opaque = const_cast<pl_gpu*>(&renderer->m_Vulkan->gpu);' \
  'return pl_get_buffer2(&mappedContext, frame, flags);' \
  'PLANK_VULKAN_FRAME_ALLOCATOR' \
  'requestedAllocator == "host-import"' \
  'bufferParams.import_handle = PL_HANDLE_HOST_PTR' \
  'Using pooled cacheable FFmpeg decode buffers imported into Vulkan' \
  'context->get_buffer2 = getMappedBuffer;' \
  'Using persistently mapped Vulkan decode buffers'; do
  rg -Fq "$required_frame_allocator_token" \
    "$source_dir/app/streaming/video/ffmpeg-renderers/plvk.cpp" \
    "$source_dir/app/streaming/video/ffmpeg-renderers/plvk.h" || {
    echo "Vulkan frame-allocator invariant is missing: ${required_frame_allocator_token}" >&2
    exit 1
  }
done
echo "client_vulkan_frame_allocator_gate=pass"

# Remote-workstation sessions capture OS-level key combinations by default so
# shortcuts such as Alt+Tab reach the host in both windowed and borderless mode.
rg -U -q 'settings\.value\(SER_CAPTURESYSKEYS,\n[[:space:]]+static_cast<int>\(CaptureSysKeysMode::CSK_ALWAYS\)\)' \
  "$source_dir/app/settings/streamingpreferences.cpp" || {
  echo "system keyboard shortcut capture does not default to Always" >&2
  exit 1
}
echo "client_system_shortcut_default_gate=pass"

# The bookmark owns the complete profile choice, including capture source,
# encoder backend, codec family, bit depth, and chroma. The client advertises
# only that selected format and selects an exact-format decoder internally.
if rg -n \
  'enableHdr|enableYUV444|supportsHdr|Enable HDR|Enable YUV 4:4:4|addToggleOption\("(hdr|yuv444)"|GUI display mode|uiDisplayMode|UIDisplayMode|UI_(WINDOWED|MAXIMIZED|FULLSCREEN)|uidisplaymode|startwindowed' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "optional HDR, YUV 4:4:4, or GUI display-mode controls are present in PLANK client" >&2
  exit 1
fi
if rg -n \
  'VideoCodecConfig|videoCodecConfig|SER_VIDEOCFG|VCC_|video-codec|codecComboBox|resVCCTitle|Video codec' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "the obsolete global video codec preference is still present" >&2
  exit 1
fi
echo "client_global_video_codec_absence_gate=pass"
if rg -n \
  'm_SupportedVideoFormats\.append\(VIDEO_FORMAT_(H264\)|H265\)|H265_MAIN|AV1_MAIN)' \
  "$source_dir/app/streaming/session.cpp"; then
  echo "a 4:2:0 video profile is advertised by the PLANK session" >&2
  exit 1
fi
for required_profile_token in \
  'PLANK_PROFILE_H264_8BIT_422' \
  'PLANK_PROFILE_H264_8BIT_444' \
  'PLANK_PROFILE_H264_10BIT_422' \
  'PLANK_PROFILE_H264_10BIT_444' \
  'PLANK_PROFILE_NVENC_H264_8BIT_444' \
  'PLANK_PROFILE_NVENC_HEVC_8BIT_444' \
  'PLANK_PROFILE_NVENC_HEVC_10BIT_444' \
  'selectedVideoFormat = VIDEO_FORMAT_H264_HIGH8_422;' \
  'selectedVideoFormat = VIDEO_FORMAT_H264_HIGH8_444;' \
  'selectedVideoFormat = VIDEO_FORMAT_H264_HIGH10_422;' \
  'selectedVideoFormat = VIDEO_FORMAT_H265_REXT8_444;' \
  'selectedVideoFormat = VIDEO_FORMAT_H265_REXT10_444;' \
  'int selectedVideoFormat = VIDEO_FORMAT_H264_HIGH10_444;' \
  'm_SupportedVideoFormats.append(selectedVideoFormat);'; do
  rg -Fq "$required_profile_token" \
    "$source_dir/app/settings/streamingpreferences.h" \
    "$source_dir/app/streaming/session.cpp" || {
    echo "PLANK exact H.264 profile selection is missing: ${required_profile_token}" >&2
    exit 1
  }
done
if rg -n 'm_SupportedVideoFormats\.append\(VIDEO_FORMAT_' \
  "$source_dir/app/streaming/session.cpp"; then
  echo "PLANK must advertise the one selected bookmark format, not fixed fallback formats" >&2
  exit 1
fi
for required_bookmark_profile_token in \
  '#define SER_VIDEOPROFILE "plank-video-profile"' \
  'int plankVideoProfile = 0;' \
  'settings.value(SER_VIDEOPROFILE,' \
  'settings.setValue(SER_VIDEOPROFILE, plankVideoProfile);' \
  'plankVideoProfile == that.plankVideoProfile' \
  'plankVideoProfile(int computerIndex) const' \
  'm_PlankVideoProfile'; do
  rg -Fq "$required_bookmark_profile_token" \
    "$source_dir/app/backend/nvcomputer.h" \
    "$source_dir/app/backend/nvcomputer.cpp" \
    "$source_dir/app/gui/computermodel.h" \
    "$source_dir/app/gui/computermodel.cpp" \
    "$source_dir/app/streaming/session.h" \
    "$source_dir/app/streaming/session.cpp" || {
    echo "PLANK bookmark encoding profile is missing: ${required_bookmark_profile_token}" >&2
    exit 1
  }
done
for required_bookmark_profile_ui_token in \
  'addEncodingProfile' \
  'editEncodingProfile' \
  'computerModel.plankVideoProfile(index)'; do
  rg -Fq "$required_bookmark_profile_ui_token" \
    "$source_dir/app/gui/main.qml" "$source_dir/app/gui/PcView.qml" || {
    echo "PLANK bookmark encoding-profile UI is missing: ${required_bookmark_profile_ui_token}" >&2
    exit 1
  }
done
rg -Fq 'addEncodingProfile.currentIndex = 6' \
  "$source_dir/app/gui/main.qml" || {
  echo "new bookmarks do not default to H.265 10-bit 4:4:4 NVENC" >&2
  exit 1
}
if rg -n 'plankVideoProfile|Encoding profile' \
  "$source_dir/app/gui/SettingsView.qml" \
  "$source_dir/app/settings/streamingpreferences.cpp"; then
  echo "encoding profile remains a global PLANK preference" >&2
  exit 1
fi

# Every encoding profile owns an independent startup encoder target within each
# bookmark. The toolbar owns only a session-local copy, and no global or
# command-line bitrate source may compete with the bookmark/profile value.
for required_bookmark_bitrate_token in \
  '#define SER_PLANK_PROFILE_BITRATES "plank-profile-bitrates-kbps"' \
  'QVector<int> plankProfileBitratesKbps =' \
  'plankProfileBitratesFromVariantList(' \
  'plankProfileBitratesToVariantList(' \
  'plankProfileBitratesKbps ==' \
  'plankProfileBitratesKbps(' \
  'plankBitrateForProfile(' \
  'm_PlankBitrateKbps' \
  'm_StreamConfig.bitrate = m_PlankBitrateKbps;' \
  'PlankH264DefaultBitrateKbps = 80000' \
  'PlankHevcDefaultBitrateKbps = 50000'; do
  rg -Fq "$required_bookmark_bitrate_token" \
    "$source_dir/app/backend/nvcomputer.h" \
    "$source_dir/app/backend/nvcomputer.cpp" \
    "$source_dir/app/gui/computermodel.h" \
    "$source_dir/app/gui/computermodel.cpp" \
    "$source_dir/app/streaming/session.h" \
    "$source_dir/app/streaming/session.cpp" \
    "$source_dir/app/settings/streamingpreferences.h" || {
    echo "PLANK bookmark bitrate invariant is missing: ${required_bookmark_bitrate_token}" >&2
    exit 1
  }
done
for required_bookmark_bitrate_ui_token in \
  addBitrateSlider \
  editBitrateSlider \
  'Startup encoder target:' \
  'Saved independently for each encoding profile. Toolbar adjustments apply only to the active session.' \
  'rememberProfileBitrate' \
  'computerModel.plankProfileBitratesKbps(index)'; do
  rg -Fq "$required_bookmark_bitrate_ui_token" \
    "$source_dir/app/gui/main.qml" "$source_dir/app/gui/PcView.qml" || {
    echo "PLANK bookmark bitrate UI is missing: ${required_bookmark_bitrate_ui_token}" >&2
    exit 1
  }
done
if rg -n \
  'Q_PROPERTY\(int bitrateKbps|\bbitrateKbps MEMBER|#define SER_BITRATE "bitrate"|plank-bitrate-kbps|getDefaultBitrate|StreamingPreferences\.bitrateKbps|m_Preferences\.bitrateKbps|preferences->bitrateKbps|addValueOption\("bitrate"' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "global or command-line bitrate configuration remains in PLANK client" >&2
  exit 1
fi
if rg -n 'NVENC \(Experimental\)' \
  "$source_dir/app/gui/main.qml" "$source_dir/app/gui/PcView.qml" \
  "$repo_dir/protocol/encoding-profiles.md"; then
  echo "NVENC encoding profiles must not be labeled Experimental" >&2
  exit 1
fi
for native_capture_label in \
  'Native X11/XShm — 10-bit (Experimental)'; do
  rg -Fq "$native_capture_label" \
    "$source_dir/app/gui/PlankCaptureSourceBox.qml" || {
    echo "native X11 capture must retain its Experimental label" >&2
    exit 1
  }
done
for bookmark_dialog in main.qml PcView.qml; do
  rg -Fq 'PlankCaptureSourceBox {' "$source_dir/app/gui/$bookmark_dialog" || {
    echo "bookmark dialog must use the shared host-aware capture selector" >&2
    exit 1
  }
done
for native_x264_profile_label in \
  'H.264 10-bit 4:4:4 (identity GBR) — x264'; do
  rg -Fq "$native_x264_profile_label" \
    "$source_dir/app/gui/main.qml" "$source_dir/app/gui/PcView.qml" || {
    echo "native X11 profile must identify x264 explicitly" >&2
    exit 1
  }
done
for bookmark_layout_token in \
  'height: Math.min(implicitHeight, parent.height - 20)' \
  'id: unreachableActionComboBox' \
  'width: parent.width'; do
  rg -Fq "$bookmark_layout_token" \
    "$source_dir/app/gui/main.qml" "$source_dir/app/gui/PcView.qml" \
    "$source_dir/app/gui/SettingsView.qml" || {
    echo "PLANK bookmark/settings layout invariant is missing: ${bookmark_layout_token}" >&2
    exit 1
  }
done
for audio_settings_token in \
  'Mute audio stream when the client is not the active window' \
  'Mutes streamed audio when you Alt+Tab out of the stream or click on a different window.'; do
  rg -Fq "$audio_settings_token" \
    "$source_dir/app/gui/SettingsView.qml" || {
    echo "PLANK Audio Settings wording is missing: ${audio_settings_token}" >&2
    exit 1
  }
done
if rg -n 'Mute audio stream when Moonlight|Mutes Moonlight.s audio' \
  "$source_dir/app/gui/SettingsView.qml"; then
  echo "Moonlight branding remains in PLANK Audio Settings" >&2
  exit 1
fi
if rg -n -U 'id: uiSettingsGroupBox\n[[:space:]]+parent: settingsColumn2' \
  "$source_dir/app/gui/SettingsView.qml"; then
  echo "UI Settings must remain in the left preference column" >&2
  exit 1
fi
echo "client_bookmark_bitrate_gate=pass"

for required_session_takeover_token in \
  'SessionTakeoverFeature = 0x8000' \
  '&plankTakeover=1' \
  'PLANK workstation session is active' \
  'Disconnect the existing client and continue?' \
  'm_WaitingForActiveSessionTakeoverDecision' \
  'PLANK_TRANSPORT_TERMINATION_SESSION_TAKEN_OVER' \
  'Host display layout transition is currently unavailable' \
  'This PLANK session was transferred to another client.'; do
  rg -Fq "$required_session_takeover_token" \
    "$source_dir/app/streaming/session.cpp" \
    "$source_dir/app/backend/nvhttp.cpp" \
    "$source_dir/app/backend/outputtopology.h" \
    "$source_dir/app/streaming/session.h" \
    "$source_dir/app/gui/StreamSegue.qml" || {
    echo "active-session takeover invariant is missing: ${required_session_takeover_token}" >&2
    exit 1
  }
done
if rg -Fq 'Waiting for previous workstation session to finish...' \
    "$source_dir/app/streaming/session.cpp"; then
  echo "legacy timed active-session polling remains in the client" >&2
  exit 1
fi
echo "client_session_takeover_gate=pass"

for required_topology_retry_token in \
  'bool Session::configurePlankLaunchGeometry()' \
  'm_InputHandler->setStreamDimensions' \
  'PLANK refreshed stale topology and launch geometry; retrying launch:'; do
  rg -Fq "$required_topology_retry_token" \
    "$source_dir/app/streaming/session.cpp" || {
    echo "stale-topology retry geometry invariant is missing: ${required_topology_retry_token}" >&2
    exit 1
  }
done
echo "client_topology_retry_geometry_gate=pass"

for required_display_transition_token in \
  'display transition is still pending' \
  'authentication will be refreshed once' \
  'configurePlankLaunchGeometry()' \
  'retryError.getStatusCode() != 409' \
  'MaximumVirtualCanvasWidth = 8192' \
  'matchesRequestedHostLayout'; do
  rg -Fq "$required_display_transition_token" \
    "$source_dir/app/streaming/session.cpp" \
    "$source_dir/app/backend/outputtopology.h" || {
    echo "display-transition retry invariant is missing: ${required_display_transition_token}" >&2
    exit 1
  }
done
echo "client_display_transition_retry_gate=pass"

for required_retained_renderer_token in \
  'suspendForReconnect()' \
  'resumeAfterReconnect()' \
  'Paused FFmpeg decode while retaining the stream renderer' \
  'resumedRenderer ? "retained" : "recreated"'; do
  rg -Fq "$required_retained_renderer_token" \
    "$source_dir/app/streaming/session.cpp" \
    "$source_dir/app/streaming/video/decoder.h" \
    "$source_dir/app/streaming/video/ffmpeg.cpp" || {
    echo "retained reconnect renderer invariant is missing: ${required_retained_renderer_token}" >&2
    exit 1
  }
done
echo "client_retained_reconnect_renderer_gate=pass"

for required_reconnect_local_event_token in \
  'handlePlankLocalUserEvent' \
  'applyPendingRemoteCursor();' \
  'applyPendingTabletCursorActivation();' \
  'applyPendingRemoteCursorPosition();' \
  'one-shot pending latches'; do
  rg -Fq "$required_reconnect_local_event_token" \
    "$source_dir/app/streaming/session.cpp" || {
    echo "responsive reconnect local-event invariant is missing: ${required_reconnect_local_event_token}" >&2
    exit 1
  }
done
echo "client_reconnect_local_event_gate=pass"

for required_client_identity_token in \
  'QGuiApplication::setApplicationDisplayName("PLANK Client");' \
  'SDL_SetAppMetadata("PLANK Client",' \
  '"la.instinctual.Plank.Client");' \
  'app.setDesktopFileName("la.instinctual.Plank.Client");'; do
  rg -Fq "$required_client_identity_token" "$source_dir/app/main.cpp" || {
    echo "client application identity is missing: ${required_client_identity_token}" >&2
    exit 1
  }
done
if rg -n 'SDL_(AUDIO_DEVICE_APP_NAME|VIDEO_(WAYLAND|X11)_WMCLASS)' \
    "$source_dir/app/main.cpp"; then
  echo "client source still uses removed SDL2 application identity variables" >&2
  exit 1
fi
rg -Fq 'TARGET = plank-client' "$source_dir/app/app.pro" || {
  echo "client build target is not branded plank-client" >&2
  exit 1
}
approved_client_logo="$repo_dir/branding/assets/plank-logo.png"
runtime_client_logo="$source_dir/app/res/plank-logo.png"
[[ -f $approved_client_logo ]] || {
  echo "approved PLANK client logo is unavailable: ${approved_client_logo}" >&2
  exit 1
}
cmp --silent "$approved_client_logo" "$runtime_client_logo" || {
  echo "runtime client logo differs from the approved PLANK artwork" >&2
  exit 1
}
echo "client_approved_logo_source_gate=pass"
client_desktop="$source_dir/app/deploy/linux/la.instinctual.Plank.Client.desktop"
client_appstream="$source_dir/app/deploy/linux/la.instinctual.Plank.Client.appdata.xml"
rg -Fxq 'Name=PLANK Client' "$client_desktop" || {
  echo "client desktop display name is not PLANK Client" >&2
  exit 1
}
rg -Fxq 'StartupWMClass=la.instinctual.Plank.Client' \
  "$client_desktop" || {
  echo "client desktop application ID is not canonical" >&2
  exit 1
}
rg -Fq '<id>la.instinctual.Plank.Client</id>' \
  "$client_appstream" || {
  echo "client AppStream application ID is not canonical" >&2
  exit 1
}
echo "client_application_id_gate=pass"

if rg -n \
  'VideoDecoderSelection|videoDecoderSelection|VDS_FORCE_|VDS_AUTO|video-decoder|DECODER_HINT|text:[[:space:]]*qsTr\("Video decoder"\)' \
  "$source_dir/app" --glob '!**/languages/**'; then
  echo "the removed global video decoder preference or override is still present" >&2
  exit 1
fi
for required_exact_decoder_token in \
  'DecoderSelectionMode::PreferExactHardwareThenSoftware' \
  'validateDecodedProfileFrame(frame, params)' \
  'frame->hw_frames_ctx->data' \
  'Exact profile validation rejected decoded format' \
  'Exact identity GBR validation rejected decoded color metadata'; do
  rg -Fq "$required_exact_decoder_token" "$source_dir/app" || {
    echo "exact decoder qualification is missing: ${required_exact_decoder_token}" >&2
    exit 1
  }
done
echo "client_exact_decoder_selection_gate=pass"

# The PLANK client is Wayland-only. It offers compositor-managed
# borderless and decorated/resizable windowed streaming, but no exclusive
# modesetting path.
if rg -n '\bWM_FULLSCREEN\b|\{"fullscreen",[[:space:]]*StreamingPreferences::WM|m_FullScreenFlag[[:space:]]*=[[:space:]]*SDL_WINDOW_FULLSCREEN;' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "exclusive fullscreen support is present in the Wayland-only PLANK client" >&2
  exit 1
fi
for required_window_token in \
  SDL_HINT_VIDEO_WAYLAND_ALLOW_LIBDECOR \
  SDL_HINT_VIDEO_WAYLAND_PREFER_LIBDECOR \
  SDL_HINT_OVERRIDE \
  SDL_RestoreWindow \
  SDL_SetWindowBordered \
  SDL_SetWindowResizable \
  'Action::ToggleFullscreen' \
  fullscreenContains \
  'toolbar fullscreen toggle requested'; do
  rg -q "$required_window_token" "$source_dir/app" || {
    echo "decorated Wayland window invariant is missing: ${required_window_token}" >&2
    exit 1
  }
done
echo "client_wayland_window_mode_gate=pass"

# Stream resolution belongs to each bookmark's Scaling policy. Scaled-Span
# derives its transport canvas from the active client display, while Native
# uses the selected host canvas exactly. Do not restore the old global
# resolution preference, saved width/height state, or CLI override path.
if rg -n \
  'plankAutoResolution|SER_(WIDTH|HEIGHT)|Q_PROPERTY\(int (width|height)|add(Value|Flag)Option\("(resolution|720|1080|1440|4K)"|Use native client display resolution|Resolution and FPS' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "obsolete global stream-resolution preference is present" >&2
  exit 1
fi
for required_resolution_policy_token in \
  'text: qsTr("Frame rate")' \
  'text: qsTr("Window Mode")' \
  'resolution-policy=%s' \
  '"host-native" : "client-native"'; do
  rg -Fq "$required_resolution_policy_token" "$source_dir/app" || {
    echo "bookmark-owned resolution policy is missing: ${required_resolution_policy_token}" >&2
    exit 1
  }
done
echo "client_bookmark_resolution_policy_gate=pass"

# Manually entered workstations are persistent bookmarks even while offline.
# They retain both the entered address and editable nickname, then bind to the
# first server identity that successfully answers at that address.
for required_bookmark_token in \
  plank-manual-bookmark \
  plank-server-uuid \
  plank-host-layout \
  plank-virtual-mode-1 \
  plank-virtual-mode-2 \
  plank-scaling-mode \
  acceptsServerUuid \
  'Address or hostname' \
  Nickname; do
  rg -Fq "$required_bookmark_token" "$source_dir/app" || {
    echo "offline workstation bookmark invariant is missing: ${required_bookmark_token}" >&2
    exit 1
  }
done
rg -U -q 'addNewHostManually\(addressText\.text\.trim\(\),[[:space:]]*nicknameText\.text\.trim\(\),[[:space:]]*addHostLayout\.currentIndex,[[:space:]]*addVirtualMode1\.currentIndex,[[:space:]]*addVirtualMode2\.currentIndex,[[:space:]]*addScalingChoice\.currentIndex,[[:space:]]*addEncodingProfile\.model\.get\(' \
  "$source_dir/app/gui/main.qml" || {
  echo "manual workstation dialog does not submit address, nickname, host layout, independent virtual modes, scaling, and encoding profile" >&2
  exit 1
}
for required_bookmark_editor_token in \
  'Edit bookmark…' \
  editComputerBookmark \
  editManualBookmark \
  editScalingChoice; do
  rg -Fq "$required_bookmark_editor_token" "$source_dir/app" || {
    echo "workstation bookmark editor invariant is missing: ${required_bookmark_editor_token}" >&2
    exit 1
  }
done
if rg -Fq 'text: qsTr("Display…")' "$source_dir/app/gui/PcView.qml"; then
  echo "standalone workstation display menu must remain inside bookmark editing" >&2
  exit 1
fi
rg -U -q 'id: addPcDialog(.|\n)*width: Math\.min\(640, parent\.width - 40\)(.|\n)*dim: false' \
  "$source_dir/app/gui/main.qml" || {
  echo "connection dialog must remain wide without dimming the launcher" >&2
  exit 1
}
rg -U -q 'id: addPcDialog(.|\n)*ColumnLayout \{\n[[:space:]]+width: parent\.width' \
  "$source_dir/app/gui/main.qml" || {
  echo "connection fields must fill the dialog width" >&2
  exit 1
}
if rg -q 'placeholderText: qsTr\("hardware-test-host(\.plank\.io)?"\)' \
  "$source_dir/app/gui/main.qml"; then
  echo "connection dialog contains misleading workstation example text" >&2
  exit 1
fi
rg -U -q 'case AddressRole:(.|\n)*!computer->manualAddress\.isNull\(\)(.|\n)*!computer->activeAddress\.isNull\(\)(.|\n)*return QString\(\);' \
  "$source_dir/app/gui/computermodel.cpp" || {
  echo "workstation rows can expose a null manual address" >&2
  exit 1
}
echo "client_offline_bookmark_gate=pass"

# Both bookmark dialogs consume the backend's canonical ordered mode list.
# Duplicated QML arrays can silently shift choice indices when a mode is added.
for bookmark_ui in \
  "$source_dir/app/gui/main.qml" \
  "$source_dir/app/gui/PcView.qml"; do
  rg -Fq 'property var virtualModeChoices: ComputerManager.plankVirtualModeChoices()' \
    "$bookmark_ui" || {
    echo "bookmark resolution UI does not use the canonical backend list: ${bookmark_ui}" >&2
    exit 1
  }
done
for required_virtual_mode_token in \
  'Q_INVOKABLE QStringList plankVirtualModeChoices() const;' \
  'QStringList choices = NvOutputTopology::qualifiedVirtualModes();' \
  'int hostLayout = 0, int virtualMode1 = 9' \
  'int virtualMode2 = 1' \
  'addVirtualMode1.currentIndex = 9' \
  'addVirtualMode2.currentIndex = 1' \
  'property int virtualMode1Index: 9' \
  'property int virtualMode2Index: 1' \
  'height: 1200' \
  'minimumHeight: 900'; do
  rg -Fq "$required_virtual_mode_token" \
    "$source_dir/app/backend/computermanager.h" \
    "$source_dir/app/backend/computermanager.cpp" \
    "$source_dir/app/gui/main.qml" \
    "$source_dir/app/gui/PcView.qml" || {
    echo "bookmark resolution-list invariant is missing: ${required_virtual_mode_token}" >&2
    exit 1
  }
done
rg -Fq 'QStringLiteral("5120x2160")' "$source_dir/app/backend/outputtopology.cpp" || {
  echo "5120x2160 is missing from the canonical bookmark mode list" >&2
  exit 1
}
if rg -Fq 'QStringLiteral("1280x720")' "$source_dir/app/backend/outputtopology.cpp" ||
   rg -Fq 'QStringLiteral("1280x1024")' "$source_dir/app/backend/outputtopology.cpp"; then
  echo "the canonical bookmark mode list still contains a removed mode" >&2
  exit 1
fi
echo "client_bookmark_resolution_list_gate=pass"

# Match Client is a client-side bookmark policy that resolves the active SDL3
# monitor inventory into an exact one- or two-output host request. The former
# inherited-host policy is intentionally absent because it made bookmark
# behavior depend on stale host state.
if rg -n 'ConfiguredHostLayout|Use the host.s configured layout' \
  "$source_dir/app" --glob '!**/languages/**'; then
  echo "inherited configured-host bookmark policy is present" >&2
  exit 1
fi
for required_match_client_token in \
  'MatchClientHostLayout' \
  'resolveClientDisplayLayout' \
  'Match client displays'; do
  rg -Fq "$required_match_client_token" "$source_dir/app" || {
    echo "match-client bookmark invariant is missing: ${required_match_client_token}" >&2
    exit 1
  }
done
echo "client_match_client_layout_gate=pass"

# A reachable host publishes its startup layout and explicit allowed layouts.
# Physical-startup hosts retain editable physical and temporary virtual choices;
# headless hosts reject only the physical choice. Offline bookmarks remain fully
# editable and are never silently rewritten when topology arrives.
for required_display_policy_token in \
  'plankHostDisplayPolicy' \
  'displayPolicyKnown' \
  'allowedLayoutKinds' \
  'TemporaryPhysicalLayoutFeature' \
  'This headless workstation does not provide physical displays.' \
  'This workstation does not support the display layout selected by the bookmark.'; do
  rg -Fq "$required_display_policy_token" "$source_dir/app" || {
    echo "host display-policy invariant is missing: ${required_display_policy_token}" >&2
    exit 1
  }
done
if rg -Fq "normalized the bookmark to the host's physical-display policy" \
  "$source_dir/app"; then
  echo "client still silently rewrites bookmark display layouts" >&2
  exit 1
fi
echo "client_host_display_policy_gate=pass"

# Bookmark scaling applies to the complete host desktop. Native preserves a
# 1:1 transport canvas; Scaled-Span uses the qualified
# client-resolution fit. Individual remote-output selection is intentionally
# absent from the headless workflow.
if rg -n 'plank-selected-output|selectedOutputId|plankOutputId|plankDisplayChoices|selectOutput\(|SingleOutputMode|SeparateDisplaysMode|Primary display|specific host monitor|Named host monitors' \
  "$source_dir/app" --glob '!**/languages/**'; then
  echo "remote-monitor selection is present in the PLANK client" >&2
  exit 1
fi
for required_scaling_token in \
  'NativeScalingMode' \
  'plankScalingChoice' \
  'Native (1:1 pixels)' \
  'Scaled-Span' \
  'Native scaling requires a valid host desktop pixel size.'; do
  rg -Fq "$required_scaling_token" "$source_dir/app" || {
    echo "bookmark scaling invariant is missing: ${required_scaling_token}" >&2
    exit 1
  }
done
echo "client_bookmark_scaling_gate=pass"

# Workstation diagnostics belong in the bounded persistent log rather than a
# user-facing context-menu dump of internal addresses and identifiers.
if rg -n 'DetailsRole|showPcDetailsDialog|View Details|Running Game ID|MAC Address:' \
  "$source_dir/app/gui" \
  --glob '!**/languages/**'; then
  echo "legacy workstation details UI is present" >&2
  exit 1
fi
echo "client_workstation_details_absence_gate=pass"

# Wake PC is a narrow request to PLANK Relay. The Client must not regain the
# inherited local MAC persistence, magic-packet generation, port fan-out, or
# automatic wake behavior.
if rg -n 'WakeableRole|wakeComputer|macAddress|SER_MAC|wolPayload|STATIC_WOL_PORTS|DYNAMIC_WOL_PORTS|computer->wake\(\)' \
  "$source_dir/app" \
  --glob '!**/languages/**'; then
  echo "legacy local Wake-on-LAN support is present in PLANK client" >&2
  exit 1
fi
echo "client_legacy_wake_on_lan_absence_gate=pass"
for required_relay_wake_token in \
  'Wake PC' \
  requestRelayWake \
  relayWakePort \
  'connectToHost(m_Address, m_Port)' \
  'manualBookmark &&' \
  'relay_wake_port'; do
  rg -Fq "$required_relay_wake_token" \
    "$source_dir/app" "$repo_dir/packaging/client/linux/config/plank-client.conf" || {
    echo "relay-mediated Wake PC invariant is missing: ${required_relay_wake_token}" >&2
    exit 1
  }
done
if rg -n 'QUdpSocket|writeDatagram|QNetworkDatagram' \
  "$source_dir/app/backend/relaywakeclient."{cpp,h}; then
  echo "Client must not transmit Wake-on-LAN datagrams itself" >&2
  exit 1
fi
echo "client_relay_wake_gate=pass"

# Native KyProto owns media packetization. Keep the retired GameStream packet
# size preference and its misleading UI out of the Client.
# Bundled release notes describe historical changes, not executable policy.
if rg -n 'packet-size|SER_PACKETSIZE|\bpacketSize MEMBER|networkMtu|plank-network-mtu|videoPacketSizeForMtu|Determine network MTU|Physical path MTU|plankpacketsize' \
  "$source_dir/app" \
  --glob '!**/languages/**' --glob '!*.md'; then
  echo "legacy packet-size configuration is present in PLANK client" >&2
  exit 1
fi
for required_mtu_token in \
  'Network Settings' \
  ZeroTierQuicUdpPayloadMtu \
  quicUdpPayloadMtu \
  'Determine QUIC MTU automatically' \
  'Maximum QUIC UDP payload' \
  max_udp_payload_size; do
  rg -Fq "$required_mtu_token" "$source_dir/app" || {
    echo "client native MTU invariant is missing: ${required_mtu_token}" >&2
    exit 1
  }
done
if rg -U -q 'id: networkSettingsGroupBox\n[[:space:]]+parent:' \
  "$source_dir/app/gui/SettingsView.qml"; then
  echo "Network Settings is explicitly reparented outside the right configuration column" >&2
  exit 1
fi
rg -U -q 'id: settingsColumn2(.|\n)*id: networkSettingsGroupBox' \
  "$source_dir/app/gui/SettingsView.qml" || {
  echo "Network Settings is not assigned to the right configuration column" >&2
  exit 1
}
echo "client_network_mtu_gate=pass"
python3 "$repo_dir/tests/packaging/test-client-interface-mtu.py" "$source_dir"

# mDNS discovery is opt-in. Only the root-owned client policy may take
# precedence over the user preference and lock the corresponding UI control.
rg -Fq 'settings.value(SER_MDNS, false)' \
  "$source_dir/app/settings/streamingpreferences.cpp" || {
  echo "client mDNS discovery does not default to disabled" >&2
  exit 1
}
for required_mdns_token in \
  PlankClientPolicy \
  'network/mdns_discovery' \
  '/etc/plank/client.conf' \
  mdnsDiscoveryManaged \
  '!StreamingPreferences.mdnsDiscoveryManaged'; do
  rg -Fq "$required_mdns_token" "$source_dir/app" || {
    echo "client managed mDNS invariant is missing: ${required_mdns_token}" >&2
    exit 1
  }
done
if rg -n 'PLANK_MDNS_DISCOVERY|client\.env' "$source_dir/app"; then
  echo "client retains the deprecated user-controlled mDNS environment policy" >&2
  exit 1
fi
[[ ! -e ${repo_dir}/packaging/client/linux/bin/plank-client ]] || {
  echo "client package still carries an unnecessary launcher wrapper" >&2
  exit 1
}
rg -Fq '\$$ORIGIN/../lib/plank' "$source_dir/app/app.pro" || {
  echo "client build does not define its private relative runtime path" >&2
  exit 1
}
echo "client_direct_runtime_gate=pass"
client_policy="$repo_dir/packaging/client/linux/config/plank-client.conf"
rg -Fxq '[network]' "$client_policy" || {
  echo "client administrator policy is missing its network section" >&2
  exit 1
}
rg -Fxq 'port = 28989' "$client_policy" || {
  echo "client administrator policy does not define the product network port" >&2
  exit 1
}
if rg -q 'relay_wake_(enabled|port)' "$client_policy"; then
  echo "public administrator policy must not advertise optional wake settings" >&2
  exit 1
fi
rg -Fq 'computerModel.relayWakeEnabled && model.manualBookmark' "$source_dir/app/gui/PcView.qml"
rg -Fq 'if (!relayWakeEnabled())' "$source_dir/app/gui/computermodel.cpp"
rg -Fq 'network/relay_wake_enabled' "$source_dir/app/settings/plankclientpolicy.cpp"
for required_port_token in \
  'network/port' \
  'policy.networkPort()' \
  'PlankClientPolicy().networkPort()'; do
  rg -Fq "$required_port_token" "$source_dir/app" || {
    echo "client configured network-port path is missing: ${required_port_token}" >&2
    exit 1
  }
done
for required_wake_port_token in \
  'network/relay_wake_port' \
  'relayWakePort()' \
  'PlankClientPolicy().relayWakePort()'; do
  rg -Fq "$required_wake_port_token" "$source_dir/app" || {
    echo "client configured Relay wake-port path is missing: ${required_wake_port_token}" >&2
    exit 1
  }
done
rg -Fxq '# mdns_discovery = false' "$client_policy" || {
  echo "client administrator policy does not document the optional managed value" >&2
  exit 1
}
if rg -Fq 'Automatically find PCs on the local network (Recommended)' \
  "$source_dir/app/gui/SettingsView.qml"; then
  echo "obsolete mDNS recommendation label remains" >&2
  exit 1
fi
if rg -q '^[[:space:]]*mdns_discovery[[:space:]]*=' "$client_policy"; then
  echo "client administrator policy locks mDNS in the default package" >&2
  exit 1
fi
for policy_test_file in \
  tests/plankclientpolicy/plankclientpolicy.pro \
  tests/plankclientpolicy/test_plankclientpolicy.cpp \
  tests/relaywakeclient/relaywakeclient.pro \
  tests/relaywakeclient/test_relaywakeclient.cpp; do
  [[ -f ${source_dir}/${policy_test_file} ]] || {
    echo "client administrator policy test is missing: ${policy_test_file}" >&2
    exit 1
  }
done
echo "client_mdns_default_off_gate=pass"

# Linux client diagnostics must survive a reboot and remain readable without
# root access. Keep the redacted output in a private XDG state log without
# duplicating routine records into the user journal.
for required_log_token in \
  XDG_STATE_HOME \
  '.local/state' \
  'plank/logs'; do
  rg -Fq "$required_log_token" "$source_dir/app/path.cpp" || {
    echo "client persistent log path invariant is missing: ${required_log_token}" >&2
    exit 1
  }
done
for required_log_token in \
  'plank-client-*.log' \
  'MAX_LOG_SIZE_BYTES (10 * 1024 * 1024)' \
  'QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner' \
  'QFileDevice::ReadOwner | QFileDevice::WriteOwner' \
  's_LoggerFileStream << message' \
  '#if !defined(LOG_TO_FILE)' \
  'toOffsetFromUtc(localTime.offsetFromUtc()).toString(Qt::ISODateWithMs)' \
  'Persistent client log:'; do
  rg -Fq "$required_log_token" "$source_dir/app/main.cpp" || {
    echo "client persistent log invariant is missing: ${required_log_token}" >&2
    exit 1
  }
done
echo "client_persistent_log_source_gate=pass"

policy_test_build=$(mktemp -d --tmpdir plank-client-policy-test.XXXXXX)
cleanup_policy_test() {
  if [[ -d ${policy_test_build} ]]; then
    find "$policy_test_build" -xdev -depth -mindepth 1 -delete
    rmdir "$policy_test_build"
  fi
}
trap cleanup_policy_test EXIT
qmake6 "$source_dir/tests/plankclientpolicy/plankclientpolicy.pro" \
  -o "$policy_test_build/Makefile"
make -C "$policy_test_build" -j"$(nproc)"
QT_QPA_PLATFORM=offscreen "$policy_test_build/plankclientpolicy"
cleanup_policy_test
trap - EXIT
echo "client_administrator_policy_test=pass"

packed_test_build=$(mktemp -d --tmpdir plank-client-packed-test.XXXXXX)
cleanup_packed_test() {
  if [[ -d ${packed_test_build} ]]; then
    find "$packed_test_build" -xdev -depth -mindepth 1 -delete
    rmdir "$packed_test_build"
  fi
}
trap cleanup_packed_test EXIT
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
  "$source_dir/tests/embeddedcursor/main.cpp" -I"$source_dir/app" \
  $(pkg-config --cflags sdl3) -o "$packed_test_build/embedded-cursor"
"$packed_test_build/embedded-cursor"
echo "client_embedded_cursor_lifecycle_gate=pass"
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
  "$repo_dir/tests/video/packed-bt709-policy.cpp" \
  -I"$source_dir/app" -I"$client_common_dir" \
  $(pkg-config --cflags --libs Qt6Gui sdl3) -o "$packed_test_build/policy"
"$packed_test_build/policy"
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
  "$repo_dir/tests/video/packed-bt709-shader.cpp" \
  $(pkg-config --cflags --libs egl glesv2) -o "$packed_test_build/shader"
"$packed_test_build/shader" "$source_dir/app/shaders/egl_opaque.frag"
cleanup_packed_test
trap - EXIT
echo "client_packed_bt709_policy_and_shader_gate=pass"

wake_test_build=$(mktemp -d --tmpdir plank-client-relay-wake-test.XXXXXX)
cleanup_wake_test() {
  if [[ -d ${wake_test_build} ]]; then
    find "$wake_test_build" -xdev -depth -mindepth 1 -delete
    rmdir "$wake_test_build"
  fi
}
trap cleanup_wake_test EXIT
qmake6 "$source_dir/tests/relaywakeclient/relaywakeclient.pro" \
  -o "$wake_test_build/Makefile"
make -C "$wake_test_build" -j"$(nproc)"
QT_QPA_PLATFORM=offscreen "$wake_test_build/relaywakeclient"
cleanup_wake_test
trap - EXIT
echo "client_relay_wake_test=pass"

stage_test_build=$(mktemp -d --tmpdir plank-client-desktop-stage-test.XXXXXX)
cleanup_stage_test() {
  if [[ -d ${stage_test_build} ]]; then
    find "$stage_test_build" -xdev -depth -mindepth 1 -delete
    rmdir "$stage_test_build"
  fi
}
trap cleanup_stage_test EXIT
qmake6 "$source_dir/tests/desktopstage/desktopstage.pro" -o "$stage_test_build/Makefile"
make -C "$stage_test_build" -j"$(nproc)"
QT_QPA_PLATFORM=offscreen "$stage_test_build/desktopstage"
cleanup_stage_test
trap - EXIT
echo "client_authenticated_desktop_stage_test=pass"
python3 "$repo_dir/tests/packaging/test-client-reconnect-status.py" "$source_dir"
echo "client_no_video_reconnect_status_gate=pass"

bookmark_test_build=$(mktemp -d --tmpdir plank-client-bookmark-test.XXXXXX)
cleanup_bookmark_test() {
  if [[ -d ${bookmark_test_build} ]]; then
    find "$bookmark_test_build" -xdev -depth -mindepth 1 -delete
    rmdir "$bookmark_test_build"
  fi
}
trap cleanup_bookmark_test EXIT
for bookmark_test in outputtopology hostchoices planktoolbarlogic changelog authenticationtakeover hosttruststore hosttlsguard; do
  mkdir "$bookmark_test_build/$bookmark_test"
  qmake6 "$source_dir/tests/$bookmark_test/$bookmark_test.pro" \
    -o "$bookmark_test_build/$bookmark_test/Makefile"
  make -C "$bookmark_test_build/$bookmark_test" -j"$(nproc)"
  PLANK_REPO_ROOT="$repo_dir" PLANK_CLIENT_SOURCE="$source_dir" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    "$bookmark_test_build/$bookmark_test/$bookmark_test"
done
mkdir "$bookmark_test_build/persistence"
qmake6 "$repo_dir/tests/protocol/macos-client-discovery.pro" \
  "PLANK_CLIENT_SOURCE=$source_dir" \
  "PLANK_COMMON_SOURCE=$source_dir/moonlight-common-c/moonlight-common-c" \
  -o "$bookmark_test_build/persistence/Makefile"
make -C "$bookmark_test_build/persistence" -j"$(nproc)"
"$bookmark_test_build/persistence/macos-client-discovery" \
  "$repo_dir/tests/protocol/macos-server-information.xml"
mkdir "$bookmark_test_build/tls-launch"
qmake6 "$repo_dir/tests/protocol/macos-client-launch.pro" \
  "PLANK_CLIENT_SOURCE=$source_dir" \
  "PLANK_COMMON_SOURCE=$source_dir/moonlight-common-c/moonlight-common-c" \
  -o "$bookmark_test_build/tls-launch/Makefile"
make -C "$bookmark_test_build/tls-launch" -j"$(nproc)"
python3 "$repo_dir/tests/auth/macos-client-launch.py" \
  --client "$bookmark_test_build/tls-launch/macos-client-launch" \
  --topology "$repo_dir/tests/protocol/macos-output-topology-v13.json" \
  --certificate-config "$repo_dir/probes/macos/https-cert.cnf"
cleanup_bookmark_test
trap - EXIT
echo "client_host_aware_bookmark_test=pass"

export PKG_CONFIG_PATH="${ffmpeg_prefix}/lib/pkgconfig"
export LD_LIBRARY_PATH="${ffmpeg_prefix}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ $(pkg-config --modversion libavcodec) == 63.* ]] || {
  echo "FFmpeg 9 libavcodec pkg-config metadata was not selected" >&2
  exit 1
}

mkdir -p "$build_dir"
(
  cd "$build_dir"
  qmake6 "$source_dir" CONFIG+=release CONFIG+=plank-transport "${frame_flow_qmake[@]}" \
    "PLANK_TRANSPORT_DIR=${plank_transport_dir}" \
    "PLANK_VERSION=${package_version}" \
    "QMAKE_CFLAGS+=$PLANK_C_FILE_FLAGS" \
    "QMAKE_CXXFLAGS+=$PLANK_C_FILE_FLAGS"
  make -j"$(nproc)"
)

client_binary="${build_dir}/app/plank-client"
[[ -x ${client_binary} ]] || {
  echo "PLANK client package binary was not produced" >&2
  exit 1
}
# Validate inclusive coordinates and ordered edge drags through the exact
# queued input library linked into this candidate, without a desktop or host.
mkdir -p "$build_dir/tests"
cc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -DNDEBUG \
  -I"$source_dir/moonlight-common-c/moonlight-common-c/src" \
  -I"$plank_transport_dir/include" \
  "$source_dir/moonlight-common-c/moonlight-common-c/tests/native-input-bounds.c" \
  "$build_dir/moonlight-common-c/libmoonlight-common-c.a" \
  -lcrypto -lpthread -lm -o "$build_dir/tests/native-input-bounds"
"$build_dir/tests/native-input-bounds"
rg -a -Fq 'Packed 4:4:4 requires composed VAAPI layers' \
  "$client_binary" || {
  echo "client binary is missing the exact VAAPI EGL identity frontend" >&2
  exit 1
}
echo "client_vaapi_egl_identity_binary_gate=pass"
rg -a -Fq 'Enabling 10-bit packed BT.709 full-range GPU presentation (Y410/XR30)' \
  "$client_binary" || {
  echo "client binary is missing the VAAPI EGL BT.709 frontend" >&2
  exit 1
}
echo "client_vaapi_egl_bt709_binary_gate=pass"
nm -C "$client_binary" | rg ' [Tt] plank_transport_abi_version$' >/dev/null || {
  echo "client binary does not link the PLANK transport ABI" >&2
  exit 1
}
rg -a -Fq 'PLANK native transport ABI' "$client_binary" || {
  echo "client binary does not report the inactive plank_transport boundary" >&2
  exit 1
}
echo "client_plank_transport_link_gate=pass"
if [[ -e ${build_dir}/app/moonlight ]]; then
  echo "client build still produced the superseded Moonlight runtime name" >&2
  exit 1
fi
rg -a -Fq "$package_version" "$client_binary" || {
  echo "Moonlight does not embed the PLANK package version: ${package_version}" >&2
  exit 1
}
echo "plank_client_version=${package_version}"
echo "client_version_banner_gate=pass"
dynamic_section=$(readelf -d "$client_binary")
for soname in libavcodec.so.63 libavutil.so.61 libswscale.so.10 libswresample.so.7; do
  rg -q "Shared library: \[${soname//./\\.}\]" <<<"$dynamic_section" || {
    echo "Moonlight did not link the required FFmpeg 9 SONAME: ${soname}" >&2
    exit 1
  }
done
"${repo_dir}/scripts/package/audit-package-runtime.sh" \
  "$client_binary" "${ffmpeg_prefix}/lib"

log_runtime_root=$(mktemp -d)
log_runtime_home="${log_runtime_root}/home"
log_runtime_state="${log_runtime_root}/state"
log_runtime_dir="${log_runtime_state}/plank/logs"
log_runtime_config="${log_runtime_root}/config"
log_runtime_cache="${log_runtime_root}/cache"
log_runtime_session="${log_runtime_root}/runtime"
mkdir -p "$log_runtime_home" "$log_runtime_dir" "$log_runtime_config" \
  "$log_runtime_cache" "$log_runtime_session"
chmod 0700 "$log_runtime_home" "$log_runtime_dir" "$log_runtime_config" \
  "$log_runtime_cache" "$log_runtime_session"
for old_log in {01..11}; do
  touch "${log_runtime_dir}/plank-client-20000101-000000-000-${old_log}.log"
done
chmod 0600 "${log_runtime_dir}"/*.log

set +e
log_runtime_output=$(env \
  HOME="$log_runtime_home" \
  QT_QPA_PLATFORM=offscreen \
  XDG_CACHE_HOME="$log_runtime_cache" \
  XDG_CONFIG_HOME="$log_runtime_config" \
  XDG_RUNTIME_DIR="$log_runtime_session" \
  XDG_STATE_HOME="$log_runtime_state" \
  timeout 10s "$client_binary" --version 2>&1)
log_runtime_status=$?
set -e
if [[ $log_runtime_status -ne 0 ]]; then
  printf '%s\n' "$log_runtime_output" >&2
  echo "client persistent log runtime exited with status ${log_runtime_status}" >&2
  exit 1
fi

mapfile -t runtime_logs < <(find "$log_runtime_dir" -maxdepth 1 -type f \
  -name 'plank-client-*.log' -print)
if [[ ${#runtime_logs[@]} -ne 10 ]]; then
  printf '%s\n' "$log_runtime_output" >&2
  echo "client did not retain exactly 10 persistent logs" >&2
  exit 1
fi
runtime_log=$(find "$log_runtime_dir" -maxdepth 1 -type f -size +0c -print -quit)
if [[ -z $runtime_log ]] ||
   [[ $(stat -c '%a' "$log_runtime_dir") != 700 ]] ||
   [[ $(stat -c '%a' "$runtime_log") != 600 ]] ||
   ! rg -Fq 'Persistent client log:' "$runtime_log" ||
   ! rg -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}(Z|[+-][0-9]{2}:[0-9]{2}) - ' "$runtime_log" ||
   rg -Fq 'Persistent client log:' <<<"$log_runtime_output"; then
  printf '%s\n' "$log_runtime_output" >&2
  echo "client persistent log path, permissions, content, or journal isolation is invalid" >&2
  exit 1
fi
rm -rf -- "$log_runtime_root"
echo "client_persistent_log_runtime_gate=pass"

echo "client_binary=${client_binary}"
echo "client_package_binary_gate=pass"
