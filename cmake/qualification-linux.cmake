# Included from the root only for Linux hardware qualification/helper builds.
find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
find_package(X11 QUIET)
find_library(XCOMPOSITE_LIBRARY Xcomposite)
pkg_check_modules(LIBDRM REQUIRED IMPORTED_TARGET libdrm)
pkg_check_modules(SYSTEMD REQUIRED IMPORTED_TARGET libsystemd)
pkg_check_modules(EGL REQUIRED IMPORTED_TARGET egl)
pkg_check_modules(GBM QUIET IMPORTED_TARGET gbm)
pkg_check_modules(GLESV2 QUIET IMPORTED_TARGET glesv2)
pkg_check_modules(WAYLAND QUIET IMPORTED_TARGET wayland-client wayland-egl)
pkg_check_modules(GSTREAMER QUIET IMPORTED_TARGET
  gstreamer-1.0
  gstreamer-app-1.0
  gstreamer-video-1.0
  gstreamer-allocators-1.0)
find_path(FFNVCODEC_INCLUDE_DIR ffnvcodec/nvEncodeAPI.h
  HINTS
    "$ENV{PLANK_HOST_FFMPEG_ROOT}/include"
    "$ENV{PLANK_HOST_FFMPEG_BUILD}/usr/local/include"
  REQUIRED)
set(NVFBC_SDK_ROOT "" CACHE PATH "Path to the NVIDIA Capture SDK root")
find_path(NVFBC_INCLUDE_DIR NvFBC.h
  HINTS
    "${NVFBC_SDK_ROOT}"
    "$ENV{NVFBC_SDK_ROOT}"
    "${CMAKE_CURRENT_SOURCE_DIR}/../nvidia/Capture_Linux_v9.0.0/NvFBC"
  PATH_SUFFIXES NvFBC/inc inc)
find_path(PAM_INCLUDE_DIR security/pam_appl.h REQUIRED)
find_library(PAM_LIBRARY pam REQUIRED)
set(X264_ROOT "" CACHE PATH "Path to an x264 installation")
find_path(X264_INCLUDE_DIR x264.h
  HINTS "${X264_ROOT}" "${CMAKE_CURRENT_SOURCE_DIR}/build/third-party/prefix"
  PATH_SUFFIXES include)
find_library(X264_LIBRARY x264
  HINTS "${X264_ROOT}" "${CMAKE_CURRENT_SOURCE_DIR}/build/third-party/prefix"
  PATH_SUFFIXES lib lib64)

if(X11_FOUND AND X11_Xext_FOUND AND XCOMPOSITE_LIBRARY)
  add_executable(plank-probe-x11-native10
    probes/x11/plank-probe-x11-native10.cpp)
  target_compile_features(plank-probe-x11-native10 PRIVATE cxx_std_17)
  target_compile_options(plank-probe-x11-native10 PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank-probe-x11-native10 PRIVATE
    ${X11_INCLUDE_DIR})
  target_link_libraries(plank-probe-x11-native10 PRIVATE
    ${X11_LIBRARIES} ${X11_Xext_LIB} ${XCOMPOSITE_LIBRARY})
endif()

add_executable(plank-probe-kms probes/kms/plank-probe-kms.cpp)
target_compile_features(plank-probe-kms PRIVATE cxx_std_17)
target_compile_options(plank-probe-kms PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_link_libraries(plank-probe-kms PRIVATE PkgConfig::LIBDRM)

add_library(plank-session-context STATIC
  apps/host/linux/src/session/session_context.cpp)
target_compile_features(plank-session-context PRIVATE cxx_std_20)
target_compile_options(plank-session-context PRIVATE
  -Wall -Wextra -Wpedantic -Werror)
target_include_directories(plank-session-context PUBLIC
  apps/host/linux/src)
target_link_libraries(plank-session-context PUBLIC PkgConfig::SYSTEMD)

add_executable(plank-probe-kms-xb30 probes/kms/plank-probe-kms-xb30.cpp)
target_compile_features(plank-probe-kms-xb30 PRIVATE cxx_std_17)
target_compile_options(plank-probe-kms-xb30 PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_link_libraries(plank-probe-kms-xb30 PRIVATE PkgConfig::LIBDRM PkgConfig::EGL)

if(GSTREAMER_FOUND AND GBM_FOUND AND GLESV2_FOUND)
  add_executable(plank-probe-vaapi-dmabuf
    probes/video/plank-probe-vaapi-dmabuf.cpp)
  target_compile_features(plank-probe-vaapi-dmabuf PRIVATE cxx_std_17)
  target_compile_options(plank-probe-vaapi-dmabuf PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_link_libraries(plank-probe-vaapi-dmabuf PRIVATE
    PkgConfig::GSTREAMER PkgConfig::EGL PkgConfig::GBM PkgConfig::GLESV2
    PkgConfig::LIBDRM)
endif()

if(GSTREAMER_FOUND)
  add_executable(plank-probe-client-kms
    probes/video/plank-probe-client-kms.cpp)
  target_compile_features(plank-probe-client-kms PRIVATE cxx_std_17)
  target_compile_options(plank-probe-client-kms PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_link_libraries(plank-probe-client-kms PRIVATE
    PkgConfig::GSTREAMER PkgConfig::LIBDRM)
endif()

find_program(WAYLAND_SCANNER wayland-scanner)
pkg_get_variable(WAYLAND_PROTOCOLS_DATA wayland-protocols pkgdatadir)
set(XDG_SHELL_XML
  "${WAYLAND_PROTOCOLS_DATA}/stable/xdg-shell/xdg-shell.xml")
set(PRESENTATION_TIME_XML
  "${WAYLAND_PROTOCOLS_DATA}/stable/presentation-time/presentation-time.xml")
set(COMMIT_TIMING_XML
  "${WAYLAND_PROTOCOLS_DATA}/staging/commit-timing/commit-timing-v1.xml")
set(FIFO_XML "${WAYLAND_PROTOCOLS_DATA}/staging/fifo/fifo-v1.xml")
if(WAYLAND_FOUND AND GLESV2_FOUND AND WAYLAND_SCANNER AND
   EXISTS "${XDG_SHELL_XML}")
  set(XDG_SHELL_HEADER "${CMAKE_CURRENT_BINARY_DIR}/xdg-shell-client-protocol.h")
  set(XDG_SHELL_CODE "${CMAKE_CURRENT_BINARY_DIR}/xdg-shell-protocol.c")
  add_custom_command(
    OUTPUT "${XDG_SHELL_HEADER}" "${XDG_SHELL_CODE}"
    COMMAND "${WAYLAND_SCANNER}" client-header "${XDG_SHELL_XML}" "${XDG_SHELL_HEADER}"
    COMMAND "${WAYLAND_SCANNER}" private-code "${XDG_SHELL_XML}" "${XDG_SHELL_CODE}"
    DEPENDS "${XDG_SHELL_XML}")
  add_executable(plank-probe-wayland-xr30
    probes/video/plank-probe-wayland-xr30.cpp
    "${XDG_SHELL_CODE}" "${XDG_SHELL_HEADER}")
  target_compile_features(plank-probe-wayland-xr30 PRIVATE cxx_std_17)
  target_compile_options(plank-probe-wayland-xr30 PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank-probe-wayland-xr30 PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}")
  target_link_libraries(plank-probe-wayland-xr30 PRIVATE
    PkgConfig::WAYLAND PkgConfig::EGL PkgConfig::GLESV2 PkgConfig::LIBDRM)

  if(GSTREAMER_FOUND AND EXISTS "${PRESENTATION_TIME_XML}")
    set(PRESENTATION_TIME_HEADER
      "${CMAKE_CURRENT_BINARY_DIR}/presentation-time-client-protocol.h")
    set(PRESENTATION_TIME_CODE
      "${CMAKE_CURRENT_BINARY_DIR}/presentation-time-protocol.c")
    add_custom_command(
      OUTPUT "${PRESENTATION_TIME_HEADER}" "${PRESENTATION_TIME_CODE}"
      COMMAND "${WAYLAND_SCANNER}" client-header "${PRESENTATION_TIME_XML}"
        "${PRESENTATION_TIME_HEADER}"
      COMMAND "${WAYLAND_SCANNER}" private-code "${PRESENTATION_TIME_XML}"
        "${PRESENTATION_TIME_CODE}"
      DEPENDS "${PRESENTATION_TIME_XML}")
    add_executable(plank-probe-client-pipeline
      probes/video/plank-probe-client-pipeline.cpp
      "${XDG_SHELL_CODE}" "${XDG_SHELL_HEADER}"
      "${PRESENTATION_TIME_CODE}" "${PRESENTATION_TIME_HEADER}")
    if(EXISTS "${COMMIT_TIMING_XML}")
      set(COMMIT_TIMING_HEADER
        "${CMAKE_CURRENT_BINARY_DIR}/commit-timing-v1-client-protocol.h")
      set(COMMIT_TIMING_CODE
        "${CMAKE_CURRENT_BINARY_DIR}/commit-timing-v1-protocol.c")
      add_custom_command(
        OUTPUT "${COMMIT_TIMING_HEADER}" "${COMMIT_TIMING_CODE}"
        COMMAND "${WAYLAND_SCANNER}" client-header "${COMMIT_TIMING_XML}"
          "${COMMIT_TIMING_HEADER}"
        COMMAND "${WAYLAND_SCANNER}" private-code "${COMMIT_TIMING_XML}"
          "${COMMIT_TIMING_CODE}"
        DEPENDS "${COMMIT_TIMING_XML}")
      target_sources(plank-probe-client-pipeline PRIVATE
        "${COMMIT_TIMING_CODE}" "${COMMIT_TIMING_HEADER}")
      target_compile_definitions(plank-probe-client-pipeline PRIVATE
        PLANK_HAVE_COMMIT_TIMING=1)
    endif()
    if(EXISTS "${FIFO_XML}")
      set(FIFO_HEADER "${CMAKE_CURRENT_BINARY_DIR}/fifo-v1-client-protocol.h")
      set(FIFO_CODE "${CMAKE_CURRENT_BINARY_DIR}/fifo-v1-protocol.c")
      add_custom_command(
        OUTPUT "${FIFO_HEADER}" "${FIFO_CODE}"
        COMMAND "${WAYLAND_SCANNER}" client-header "${FIFO_XML}"
          "${FIFO_HEADER}"
        COMMAND "${WAYLAND_SCANNER}" private-code "${FIFO_XML}"
          "${FIFO_CODE}"
        DEPENDS "${FIFO_XML}")
      target_sources(plank-probe-client-pipeline PRIVATE
        "${FIFO_CODE}" "${FIFO_HEADER}")
      target_compile_definitions(plank-probe-client-pipeline PRIVATE
        PLANK_HAVE_FIFO=1)
    endif()
    target_compile_features(plank-probe-client-pipeline PRIVATE cxx_std_17)
    target_compile_options(plank-probe-client-pipeline PRIVATE
      -Wall -Wextra -Wpedantic -Werror)
    target_include_directories(plank-probe-client-pipeline PRIVATE
      "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(plank-probe-client-pipeline PRIVATE
      PkgConfig::GSTREAMER PkgConfig::WAYLAND PkgConfig::EGL
      PkgConfig::GLESV2 PkgConfig::LIBDRM Threads::Threads)
  endif()
endif()

add_executable(plank-probe-nvenc probes/nvenc/plank-probe-nvenc.cpp)
target_compile_features(plank-probe-nvenc PRIVATE cxx_std_17)
target_compile_options(plank-probe-nvenc PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_include_directories(plank-probe-nvenc PRIVATE ${FFNVCODEC_INCLUDE_DIR})
target_link_libraries(plank-probe-nvenc PRIVATE ${CMAKE_DL_LIBS})

if(X264_INCLUDE_DIR AND X264_LIBRARY)
  add_executable(plank-benchmark-x264
    probes/video/plank-benchmark-x264.cpp)
  target_compile_features(plank-benchmark-x264 PRIVATE cxx_std_17)
  target_compile_options(plank-benchmark-x264 PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank-benchmark-x264 PRIVATE ${X264_INCLUDE_DIR})
  target_link_libraries(plank-benchmark-x264 PRIVATE
    ${X264_LIBRARY} Threads::Threads ${CMAKE_DL_LIBS} m)
else()
  message(STATUS "x264 not found; plank-benchmark-x264 will not be built")
endif()

if(NVFBC_INCLUDE_DIR)
  add_executable(plank-probe-nvfbc probes/nvfbc/plank-probe-nvfbc.cpp)
  target_compile_features(plank-probe-nvfbc PRIVATE cxx_std_17)
  target_compile_options(plank-probe-nvfbc PRIVATE -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank-probe-nvfbc PRIVATE
    ${NVFBC_INCLUDE_DIR}
    ${FFNVCODEC_INCLUDE_DIR})
  target_link_libraries(plank-probe-nvfbc PRIVATE ${CMAKE_DL_LIBS})

  add_executable(plank-capture-nvfbc-raw
    probes/nvfbc/plank-capture-nvfbc-raw.cpp)
  target_compile_features(plank-capture-nvfbc-raw PRIVATE cxx_std_17)
  target_compile_options(plank-capture-nvfbc-raw PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank-capture-nvfbc-raw PRIVATE
    ${NVFBC_INCLUDE_DIR}
    ${FFNVCODEC_INCLUDE_DIR})
  target_link_libraries(plank-capture-nvfbc-raw PRIVATE ${CMAKE_DL_LIBS})

  add_executable(plank-probe-video-pipeline
    probes/video/plank-probe-video-pipeline.cpp)
  target_compile_features(plank-probe-video-pipeline PRIVATE cxx_std_17)
  target_compile_options(plank-probe-video-pipeline PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank-probe-video-pipeline PRIVATE
    ${NVFBC_INCLUDE_DIR}
    ${FFNVCODEC_INCLUDE_DIR})
  target_link_libraries(plank-probe-video-pipeline PRIVATE
    ${CMAKE_DL_LIBS} Threads::Threads)
else()
  message(STATUS "NvFBC SDK header not found; plank-probe-nvfbc will not be built")
endif()

add_executable(plank-probe-wacom probes/wacom/plank-probe-wacom.cpp)
target_compile_features(plank-probe-wacom PRIVATE cxx_std_17)
target_compile_options(plank-probe-wacom PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(plank-probe-pam probes/auth/plank-probe-pam.cpp)
target_compile_features(plank-probe-pam PRIVATE cxx_std_17)
target_compile_options(plank-probe-pam PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_include_directories(plank-probe-pam PRIVATE ${PAM_INCLUDE_DIR})
target_link_libraries(plank-probe-pam PRIVATE ${PAM_LIBRARY})

add_executable(plank-probe-uhid probes/wacom/plank-probe-uhid.cpp)
target_compile_features(plank-probe-uhid PRIVATE cxx_std_17)
target_compile_options(plank-probe-uhid PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(plank-wacom-raw-bridge
  probes/wacom/plank-wacom-raw-bridge.cpp)
target_compile_features(plank-wacom-raw-bridge PRIVATE cxx_std_17)
target_compile_options(plank-wacom-raw-bridge PRIVATE
  -Wall -Wextra -Wpedantic -Werror)

if(BUILD_TESTING)
  add_executable(macos-account-policy-test tests/auth/macos-account-policy.c)
  target_compile_features(macos-account-policy-test PRIVATE c_std_11)
  target_compile_options(macos-account-policy-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(macos-account-policy-test PRIVATE apps/host/macos/auth)
  add_test(NAME macos-account-policy COMMAND macos-account-policy-test)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  add_test(NAME encoder-probe-order
    COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-encoder-probe-order.py)
  set(PLANK_CLIENT_COMMON_INCLUDE
    "${CMAKE_CURRENT_SOURCE_DIR}/apps/client/moonlight-common-c/moonlight-common-c/src")
  set(PLANK_CLIENT_SOURCE
    "${CMAKE_CURRENT_SOURCE_DIR}/apps/client")
  foreach(required_client_qualification_file IN ITEMS
      "${PLANK_CLIENT_COMMON_INCLUDE}/Limelight.h"
      "${PLANK_CLIENT_COMMON_INCLUDE}/plank.h"
      "${PLANK_CLIENT_SOURCE}/app/streaming/videopacketlosswindow.h")
    if(NOT EXISTS "${required_client_qualification_file}")
      message(FATAL_ERROR
        "Root qualification requires the initialized client source tree; "
        "missing ${required_client_qualification_file}. For a host RPM "
        "candidate, keep its clean worktree host-only and run root "
        "qualification from the complete canonical checkout with a "
        "workstation-local build directory as documented in "
        "docs/development/build/release-build-runbook.md.")
    endif()
  endforeach()

  add_test(NAME packaging-launchers
    COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-launchers.sh)
  add_test(NAME host-supervisor-package
    COMMAND bash
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-host-supervisor-package.sh)
  add_test(NAME host-certificate-profile
    COMMAND bash
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-host-certificate.sh)
  add_test(NAME host-state-profile
    COMMAND bash
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-host-state.sh)
  add_test(NAME display-prepare
    COMMAND bash
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/display/test-display-prepare.sh)
  add_test(NAME av-sync-telemetry-analyzer
    COMMAND bash
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/audio/test-analyze-av-sync-telemetry.sh)
  add_test(NAME host-version-discovery
    COMMAND bash
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/protocol/test-host-version-discovery.sh)
  add_test(NAME occupancy-indicator
    COMMAND bash
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/protocol/test-occupancy-indicator.sh)
  add_test(NAME release-version
    COMMAND bash
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-release-version.sh)

  add_executable(session-policy-test tests/session/test-session-policy.cpp)
  target_compile_features(session-policy-test PRIVATE cxx_std_20)
  target_compile_options(session-policy-test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_link_libraries(session-policy-test PRIVATE plank-session-context)
  add_test(NAME session-policy COMMAND session-policy-test)

  add_executable(pam-broker-channel-test tests/session/test-pam-broker-channel.cpp)
  target_compile_features(pam-broker-channel-test PRIVATE cxx_std_20)
  target_compile_options(pam-broker-channel-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(pam-broker-channel-test PRIVATE apps/host/linux/src)
  target_link_libraries(pam-broker-channel-test PRIVATE Threads::Threads)
  add_test(NAME pam-broker-channel COMMAND pam-broker-channel-test)

  add_executable(worker-control-test tests/session/test-worker-control.cpp)
  target_compile_features(worker-control-test PRIVATE cxx_std_20)
  target_compile_options(worker-control-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(worker-control-test PRIVATE apps/host/linux/src)
  add_test(NAME worker-control COMMAND worker-control-test)

  if(X11_FOUND)
    add_executable(x11-worker-exit-test tests/session/test-x11-worker-exit.cpp)
    target_compile_features(x11-worker-exit-test PRIVATE cxx_std_20)
    target_compile_options(x11-worker-exit-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
    target_include_directories(x11-worker-exit-test PRIVATE apps/host/linux/src ${X11_INCLUDE_DIR})
    target_link_libraries(x11-worker-exit-test PRIVATE Threads::Threads ${X11_LIBRARIES})
    add_test(NAME x11-worker-exit COMMAND x11-worker-exit-test)
  endif()

  add_executable(video-packet-loss-window-test
    tests/protocol/video-packet-loss-window.cpp)
  target_compile_features(video-packet-loss-window-test PRIVATE cxx_std_17)
  target_compile_options(video-packet-loss-window-test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(video-packet-loss-window-test PRIVATE
    "${PLANK_CLIENT_SOURCE}")
  add_test(NAME video-packet-loss-window
    COMMAND video-packet-loss-window-test)

  add_executable(wacom-hid-v2-test tests/protocol/wacom-hid-v2.c)
  target_compile_options(wacom-hid-v2-test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(wacom-hid-v2-test PRIVATE
    "${PLANK_CLIENT_COMMON_INCLUDE}")
  add_test(NAME wacom-hid-v2 COMMAND wacom-hid-v2-test)

  add_executable(local-cursor-v1-test tests/protocol/local-cursor-v1.c)
  target_compile_options(local-cursor-v1-test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(local-cursor-v1-test PRIVATE
    "${PLANK_CLIENT_COMMON_INCLUDE}")
  add_test(NAME local-cursor-v1 COMMAND local-cursor-v1-test)

  add_executable(plank_transport-control-v1-test
    tests/protocol/plank-transport-control-v1.c)
  target_compile_options(plank_transport-control-v1-test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank_transport-control-v1-test PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/protocol/plank-transport/include")
  add_test(NAME plank_transport-control-v1 COMMAND plank_transport-control-v1-test)

  add_executable(plank_transport-input-v1-test
    tests/protocol/plank-transport-input-v1.c)
  target_compile_options(plank_transport-input-v1-test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank_transport-input-v1-test PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/protocol/plank-transport/include")
  target_link_libraries(plank_transport-input-v1-test PRIVATE m)
  add_test(NAME plank_transport-input-v1 COMMAND plank_transport-input-v1-test)

  add_executable(plank_transport-event-v1-test
    tests/protocol/plank-transport-event-v1.c)
  target_compile_options(plank_transport-event-v1-test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank_transport-event-v1-test PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/protocol/plank-transport/include")
  add_test(NAME plank_transport-event-v1 COMMAND plank_transport-event-v1-test)

  add_executable(plank_transport-setup-v1-test
    tests/protocol/plank-transport-setup-v1.c)
  target_compile_options(plank_transport-setup-v1-test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(plank_transport-setup-v1-test PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/protocol/plank-transport/include")
  add_test(NAME plank_transport-setup-v1 COMMAND plank_transport-setup-v1-test)

  add_test(NAME kms-probe-self-test COMMAND plank-probe-kms --self-test)
  if(TARGET plank-probe-nvfbc)
    add_test(NAME nvfbc-probe-self-test COMMAND plank-probe-nvfbc --self-test)
    add_test(NAME video-pipeline-self-test
      COMMAND plank-probe-video-pipeline --self-test)
  endif()
endif()
