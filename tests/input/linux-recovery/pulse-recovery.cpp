// Exercise production PulseAudio capture/control against an isolated daemon.
#include "src/config.h"
#include "src/platform/common.h"
#include <gtest/gtest.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

namespace config { audio_t audio {}; }
using namespace std::chrono_literals;

TEST(PulseRecovery, SilentServerDoesNotBlockCaptureCancellationOrTeardown) {
  char directory[] = "/tmp/plank-pulse-test.XXXXXX";
  ASSERT_NE(mkdtemp(directory), nullptr);
  const auto socket = std::string(directory) + "/native";
  const auto module = "module-native-protocol-unix socket=" + socket + " auth-anonymous=1 auth-cookie=" + std::string(directory) + "/cookie";
  const pid_t child = fork();
  ASSERT_GE(child, 0);
  if (!child) {
    // Hosted containers may inherit a home directory owned by another UID.
    // Isolate daemon state without changing HOME or touching a user's audio.
    setenv("PULSE_RUNTIME_PATH", (std::string(directory) + "/runtime").c_str(), 1);
    setenv("PULSE_STATE_PATH", (std::string(directory) + "/state").c_str(), 1);
    setenv("PULSE_COOKIE", (std::string(directory) + "/cookie").c_str(), 1);
    execlp("pulseaudio", "pulseaudio", "-n", "--daemonize=no", "--use-pid-file=no", "--disable-shm=yes",
           "--exit-idle-time=-1", "--log-target=stderr", "-L", module.c_str(), "-L",
           "module-null-sink sink_name=plank-test rate=48000 channels=2", "-L",
           "module-sine sink=plank-test frequency=440", nullptr);
    _exit(127);
  }
  struct Cleanup {
    pid_t child; const char *directory;
    ~Cleanup() { kill(child, SIGCONT); kill(child, SIGTERM); waitpid(child, nullptr, 0); std::filesystem::remove_all(directory); }
  } cleanup {child, directory};
  setenv("PULSE_SERVER", ("unix:" + socket).c_str(), 1);
  for (unsigned i = 0; i < 200 && !std::filesystem::exists(socket); ++i) std::this_thread::sleep_for(10ms);
  ASSERT_TRUE(std::filesystem::exists(socket));
  auto control = platf::audio_control();
  ASSERT_NE(control, nullptr);
  ASSERT_TRUE(control->sink_info().has_value());
  const std::uint8_t mapping[] {0, 1};
  auto capture = control->microphone(mapping, 2, 48000, 240, false, false);
  ASSERT_NE(capture, nullptr);
  std::vector<float> samples(480);
  // A newly activated null sink can need more than one bounded sample call.
  // Startup is separate from the strict cancellation/teardown limits below.
  const auto receive_pcm = [&] {
    const auto deadline = std::chrono::steady_clock::now() + 3s;
    auto result = platf::capture_e::timeout;
    while (result == platf::capture_e::timeout && std::chrono::steady_clock::now() < deadline)
      result = capture->sample(samples, [&] { return std::chrono::steady_clock::now() >= deadline; });
    return result;
  };
  ASSERT_EQ(receive_pcm(), platf::capture_e::ok);
  EXPECT_TRUE(std::any_of(samples.begin(), samples.end(), [](float sample) {
    return std::isfinite(sample) && std::abs(sample) > 0.0001f;
  }));
  ASSERT_EQ(kill(child, SIGSTOP), 0);
  const auto began = std::chrono::steady_clock::now();
  auto status = platf::capture_e::ok;
  while (status == platf::capture_e::ok) {
    status = capture->sample(samples, [&] { return std::chrono::steady_clock::now() - began > 100ms; });
  }
  EXPECT_EQ(status, platf::capture_e::interrupted);
  EXPECT_LT(std::chrono::steady_clock::now() - began, 500ms);
  capture.reset();
  const auto cleanup_started = std::chrono::steady_clock::now();
  control.reset();
  EXPECT_LT(std::chrono::steady_clock::now() - cleanup_started, 1s);
  ASSERT_EQ(kill(child, SIGCONT), 0);
  control = platf::audio_control();
  ASSERT_NE(control, nullptr);
  capture = control->microphone(mapping, 2, 48000, 240, false, false);
  ASSERT_NE(capture, nullptr);
  EXPECT_EQ(receive_pcm(), platf::capture_e::ok);
}
