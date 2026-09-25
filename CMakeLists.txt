cmake_minimum_required(VERSION 3.20)
project(plank VERSION 1.0.0 LANGUAGES NONE)

include(CTest)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(plank_linux_default ON)
else()
  set(plank_linux_default OFF)
endif()
option(PLANK_BUILD_LINUX_QUALIFICATION "Build Linux hardware probes and Host helpers" ${plank_linux_default})

if(BUILD_TESTING)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  add_test(NAME package-build-paths
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-build-paths.py")
  add_test(NAME macos-client-target
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-macos-client-target.py")
  add_test(NAME macos-app-icons
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-macos-app-icons.py")
  add_test(NAME package-collection
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-package-collection.py")
  add_test(NAME repository-layout
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/scripts/test/check-repository-layout.py")
  add_test(NAME bootstrap-inputs
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-bootstrap-inputs.py")
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # Exercise the real Host verifier, which requires Linux's Bash/GNU tools.
    add_test(NAME host-dependency-patches
      COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/packaging/test-host-dependency-patches.py")
  endif()
  add_test(NAME private-information
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/security/test-private-information.py")
endif()

if(PLANK_BUILD_LINUX_QUALIFICATION)
  if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "Linux hardware qualification requires a Linux target")
  endif()
  enable_language(C)
  enable_language(CXX)
  include(cmake/qualification-linux.cmake)
endif()

# Product binaries keep their existing platform build systems. See
# docs/development/build/; configuring the root is not a product package build.
