#!/usr/bin/env bash
# Run on the Ubuntu Client builder. No desktop, tablet, install or stream needed.
set -euo pipefail
source_dir=${1:?Client source required}
build_dir=${2:?test build directory required}
mkdir -p "$build_dir"
flags=(-std=c++17 -O2 -g -DNDEBUG -Wall -Wextra -Werror -pthread)
if [[ ${PLANK_WACOM_SANITIZERS:-0} == 1 ]]; then
  flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
read -r -a client_cflags <<< "$(pkg-config --cflags Qt6Gui sdl3 libinput libudev wayland-client wayland-server)"
read -r -a client_libs <<< "$(pkg-config --libs Qt6Gui sdl3 libinput libudev wayland-client wayland-server)"
"${CXX:-c++}" "${flags[@]}" "$source_dir/tests/linuxrawwacom/test_reportworker.cpp" \
  -o "$build_dir/report-worker"
timeout 30 "$build_dir/report-worker"
"${CXX:-c++}" "${flags[@]}" "$source_dir/tests/linuxrawwacom/test_callbacktarget.cpp" \
  -o "$build_dir/callback-target"
timeout 30 "$build_dir/callback-target"
"${CXX:-c++}" "${flags[@]}" -DHAS_WAYLAND "${client_cflags[@]}" \
  -include "$source_dir/tests/linuxrawwacom/wayland-faults.h" \
  "$source_dir/tests/linuxrawwacom/test_waylandcursor.cpp" \
  "$source_dir/app/streaming/plankwaylandcursor.cpp" \
  "$source_dir/app/streaming/plankwaylandtoolbar.cpp" \
  "${client_libs[@]}" -o "$build_dir/wayland-cursor"
timeout 30 "$build_dir/wayland-cursor"
# Compile the actual hidraw adapter too; the worker model alone would not catch
# ioctl, Qt/SDL API or production-header integration errors.
"${CXX:-c++}" "${flags[@]}" "${client_cflags[@]}" \
  -I"$source_dir/moonlight-common-c/moonlight-common-c/src" \
  -c "$source_dir/app/streaming/input/linuxrawwacom.cpp" \
  -o "$build_dir/linuxrawwacom.o"
"${CXX:-c++}" "${flags[@]}" "${client_cflags[@]}" \
  -I"$source_dir/moonlight-common-c/moonlight-common-c/src" \
  "$source_dir/tests/linuxrawwacom/test_lifecycle.cpp" \
  "$source_dir/app/streaming/input/linuxwacom.cpp" "$build_dir/linuxrawwacom.o" \
  -Wl,--wrap=udev_new "${client_libs[@]}" -o "$build_dir/lifecycle"
timeout 30 "$build_dir/lifecycle"
echo 'linux_wacom_components=pass hardware_acceptance=not-performed'
