cmake_minimum_required(VERSION 3.24)
project(plank_linux_input_recovery LANGUAGES CXX)

# Component tests only: no media encoder, GPU, service or installed package.
# Dependency sources must already exist at the Host's pinned revisions.
get_filename_component(PLANK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(HOST "${PLANK_ROOT}/apps/host/linux")
set(PLANK_LIBVIRTUALHID_SOURCE "${HOST}/third-party/libvirtualhid" CACHE PATH "Pinned libvirtualhid source")
set(PLANK_GTEST_SOURCE "${HOST}/third-party/googletest" CACHE PATH "Pinned GoogleTest source")
set(PLANK_FFMPEG_INCLUDE "" CACHE PATH "Prepared FFmpeg include directory")
find_package(Git REQUIRED)
foreach(dependency libvirtualhid googletest)
  if(dependency STREQUAL "libvirtualhid")
    set(dependency_source "${PLANK_LIBVIRTUALHID_SOURCE}")
  else()
    set(dependency_source "${PLANK_GTEST_SOURCE}")
  endif()
  execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${HOST}" rev-parse "HEAD:third-party/${dependency}"
    OUTPUT_VARIABLE expected OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${dependency_source}" rev-parse HEAD
    OUTPUT_VARIABLE actual OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "${dependency} source does not match the Host gitlink")
  endif()
  execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${dependency_source}" diff --quiet HEAD
    COMMAND_ERROR_IS_FATAL ANY)
endforeach()
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LIBVIRTUALHID_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LIBVIRTUALHID_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory("${PLANK_LIBVIRTUALHID_SOURCE}" virtualhid EXCLUDE_FROM_ALL)
add_subdirectory("${PLANK_GTEST_SOURCE}" googletest EXCLUDE_FROM_ALL)
find_package(Boost REQUIRED COMPONENTS log thread filesystem)
find_package(Threads REQUIRED)
enable_testing()
add_executable(input-recovery
  logging.cpp
  uhid-fixture.cpp
  "${HOST}/src/platform/virtualhid_input.cpp"
  "${HOST}/src/raw_hid_tablet.cpp"
  "${HOST}/src/raw_hid_contact.cpp"
  "${HOST}/tests/unit/test_raw_hid_tablet.cpp"
  "${HOST}/tests/unit/test_raw_hid_contact.cpp"
  "${HOST}/tests/unit/test_virtualhid_pen.cpp"
  "${HOST}/tests/unit/test_reliable_queue.cpp")
target_include_directories(input-recovery PRIVATE
  "${HOST}" "${HOST}/third-party" "${PLANK_FFMPEG_INCLUDE}" "${PLANK_ROOT}/protocol/plank-transport/include")
target_compile_definitions(input-recovery PRIVATE SUNSHINE_TESTS BOOST_LOG_DYN_LINK)
target_link_options(input-recovery PRIVATE -Wl,--wrap=open -Wl,--wrap=write -Wl,--wrap=close)
target_link_libraries(input-recovery PRIVATE libvirtualhid::libvirtualhid gtest_main Boost::log Boost::thread Boost::filesystem Threads::Threads)
add_test(NAME input-recovery COMMAND input-recovery)
set_tests_properties(input-recovery PROPERTIES TIMEOUT 30)
