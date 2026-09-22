cmake_minimum_required(VERSION 3.20)
project(plank_pam_hardening_tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
get_filename_component(PLANK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(HOST "${PLANK_ROOT}/apps/host/linux")
find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)
if(NOT EXISTS "${PLANK_BOOST_SOURCE_DIR}/libs/config/include/boost/version.hpp")
  message(FATAL_ERROR "Pass the retained Boost 1.89.0 source via PLANK_BOOST_SOURCE_DIR")
endif()
file(STRINGS "${PLANK_BOOST_SOURCE_DIR}/libs/config/include/boost/version.hpp"
  BOOST_VERSION_LINE REGEX "^#define BOOST_VERSION 108900$")
if(NOT BOOST_VERSION_LINE)
  message(FATAL_ERROR "PAM HTTPS qualification requires Boost 1.89.0")
endif()
file(GLOB BOOST_HEADERS "${PLANK_BOOST_SOURCE_DIR}/libs/*/include")
add_subdirectory("${HOST}/third-party/googletest" googletest EXCLUDE_FROM_ALL)
enable_testing()
add_executable(pam-hardening
  "${HOST}/src/auth/web_auth.cpp"
  "${HOST}/src/auth/pam_client.cpp"
  "${HOST}/src/session/session_context.cpp"
  "${HOST}/tests/unit/test_web_auth.cpp"
  "${HOST}/tests/unit/test_pam_broker_protocol.cpp"
  "${HOST}/tests/unit/test_auth_concurrency.cpp"
  "${HOST}/tests/unit/test_pam_deadlines.cpp")
target_include_directories(pam-hardening PRIVATE "${HOST}")
target_compile_definitions(pam-hardening PRIVATE SUNSHINE_TESTS)
target_compile_options(pam-hardening PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_link_libraries(pam-hardening PRIVATE GTest::gtest_main OpenSSL::Crypto Threads::Threads systemd)
add_test(NAME pam-hardening COMMAND pam-hardening)
set_tests_properties(pam-hardening PROPERTIES TIMEOUT 30)
add_executable(pam-broker-compile "${HOST}/src/auth/pam_broker.cpp")
target_compile_options(pam-broker-compile PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_link_libraries(pam-broker-compile PRIVATE pam Threads::Threads)
add_executable(pam-delegation "${PLANK_ROOT}/tests/session/test-pam-broker-channel.cpp")
target_include_directories(pam-delegation PRIVATE "${HOST}/src")
target_compile_options(pam-delegation PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_link_libraries(pam-delegation PRIVATE Threads::Threads)
add_test(NAME pam-delegation COMMAND pam-delegation)
set_tests_properties(pam-delegation PROPERTIES TIMEOUT 15)
add_executable(pam-https "${HOST}/tests/unit/test_auth_https.cpp"
  "${HOST}/src/auth/web_auth.cpp" "${HOST}/src/auth/pam_client.cpp"
  "${HOST}/src/session/session_context.cpp")
target_include_directories(pam-https PRIVATE "${HOST}")
target_include_directories(pam-https SYSTEM PRIVATE "${HOST}/third-party" ${BOOST_HEADERS})
target_compile_options(pam-https PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_link_libraries(pam-https PRIVATE GTest::gtest_main OpenSSL::SSL OpenSSL::Crypto Threads::Threads systemd)
add_test(NAME pam-https COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/run-https.sh" $<TARGET_FILE:pam-https>)
set_tests_properties(pam-https PROPERTIES TIMEOUT 15)
