/**
 * @file tests/session/test-session-policy.cpp
 * @brief Standalone tests for host graphical-session selection policy.
 */
#include "session/session_context.h"

#include <fstream>
#include <iostream>

#include <unistd.h>

namespace session = plank::session;

namespace {
  session::descriptor_t valid_session() {
    return {"c7", 1000, "seat0", "x11", "user", "active", true, false};
  }

  bool rejected(session::descriptor_t descriptor) {
    return !session::eligible_graphical_session(descriptor);
  }

  session::update_t valid_update() {
    return {
      2,
      valid_session(),
      {":0", "/run/user/1000/gdm/Xauthority", "/run/user/1000",
       "unix:path=/run/user/1000/bus", "unix:/run/user/1000/pulse/native",
       "/home/test/.config/pulse/cookie"},
    };
  }
}  // namespace

int main() {
  const auto attached = valid_session();
  auto active = attached;
  if (session::desktop_stage(attached, active) != "user") return 20;
  active.session_class = "greeter";
  if (session::desktop_stage(active, active) != "greeter" ||
      session::desktop_stage(attached, active) != "unknown") return 21;
  active = attached;
  active.id = "replacement";
  if (session::desktop_stage(attached, active) != "unknown") return 22;
  active = attached;
  active.uid++;
  if (session::desktop_stage(attached, active) != "unknown") return 23;
  active = attached;
  active.state = "closing";
  if (session::desktop_stage(attached, active) != "unknown") return 24;
  active = attached;
  active.active = false;
  if (session::desktop_stage(attached, active) != "unknown") return 25;
  active = attached;
  active.remote = true;
  if (session::desktop_stage(attached, active) != "unknown") return 26;
  if (session::confirmed_desktop_stage() != "unknown") return 27;
  auto descriptor = valid_session();
  if (!session::eligible_graphical_session(descriptor)) {
    std::cerr << "active local seat0 X11 user was rejected\n";
    return 1;
  }
  descriptor.session_class = "greeter";
  if (!session::eligible_graphical_session(descriptor)) {
    std::cerr << "active local seat0 X11 greeter was rejected\n";
    return 1;
  }
  const auto update = valid_update();
  const auto message = session::session_update_message(update);
  const auto parsed = session::parse_session_update(message);
  if (!parsed || parsed->generation != update.generation ||
      parsed->session.id != update.session.id ||
      parsed->environment.pulse_cookie != update.environment.pulse_cookie) {
    std::cerr << "session update did not round trip\n";
    return 8;
  }
  if (session::parse_session_update(message.substr(0, message.size() - 1)) ||
      session::parse_session_update(std::string_view {"SC-SESSION-3\0bad", 16})) {
    std::cerr << "malformed session update was accepted\n";
    return 9;
  }
  const session::display_request_t display_request {
    session::display_request_t::action_t::acquire,
    "dual-horizontal", "4096x2160", "1024x2160", 1000
  };
  const auto display_message = session::display_request_message(display_request);
  const auto parsed_display = session::parse_display_request(display_message);
  if (!parsed_display || parsed_display->layout != display_request.layout ||
      parsed_display->mode_1 != display_request.mode_1 ||
      parsed_display->mode_2 != display_request.mode_2 ||
      parsed_display->account_uid != display_request.account_uid) {
    std::cerr << "display request did not round trip\n";
    return 11;
  }
  const session::runtime_display_state_t runtime_state {
    "single", "2560x1600", {}, 1000
  };
  const auto runtime_message = session::runtime_display_state_message(runtime_state);
  const auto parsed_runtime = session::parse_runtime_display_state(runtime_message);
  if (!parsed_runtime || parsed_runtime->layout != runtime_state.layout ||
      parsed_runtime->mode_1 != runtime_state.mode_1 ||
      parsed_runtime->lease_uid != runtime_state.lease_uid) {
    std::cerr << "runtime display state did not round trip\n";
    return 15;
  }
  if (!session::display_request_message({
        session::display_request_t::action_t::acquire,
        "single", "1280x720", {}, 1000
      }).empty() ||
      session::parse_display_request(display_message.substr(0, display_message.size() - 1))) {
    std::cerr << "malformed display request was accepted\n";
    return 12;
  }

  char display_config_path[] = "/tmp/plank-display-policy.XXXXXX";
  const int display_config_descriptor = mkstemp(display_config_path);
  if (display_config_descriptor < 0 || close(display_config_descriptor) != 0) {
    std::cerr << "unable to create display-policy fixture\n";
    return 13;
  }
  const auto write_display_config = [&](std::string_view contents) {
    std::ofstream output {display_config_path, std::ios::trunc};
    output << contents;
    return static_cast<bool>(output);
  };
  if (!write_display_config("[display]\nstartup_layout = physical\n") ||
      session::configured_startup_layout(display_config_path) !=
        session::startup_layout_t::physical ||
      !write_display_config("[display]\nstartup_layout = virtual\n") ||
      session::configured_startup_layout(display_config_path) !=
        session::startup_layout_t::virtual_display ||
      !write_display_config(
        "[display]\nstartup_layout = physical\nstartup_layout = virtual\n"
      ) ||
      session::configured_startup_layout(display_config_path) !=
        session::startup_layout_t::invalid) {
    unlink(display_config_path);
    std::cerr << "administrator display policy was not enforced\n";
    return 14;
  }
  unlink(display_config_path);

  descriptor = valid_session();
  descriptor.active = false;
  if (!rejected(descriptor)) return 2;
  descriptor = valid_session();
  descriptor.remote = true;
  if (!rejected(descriptor)) return 3;
  descriptor = valid_session();
  descriptor.seat = "seat1";
  if (!rejected(descriptor)) return 4;
  descriptor = valid_session();
  descriptor.type = "wayland";
  if (!rejected(descriptor)) return 5;
  descriptor = valid_session();
  descriptor.session_class = "lock-screen";
  if (!rejected(descriptor)) return 6;
  descriptor = valid_session();
  descriptor.state = "closing";
  if (!rejected(descriptor)) return 7;

  auto invalid_update = valid_update();
  invalid_update.session.remote = true;
  if (!session::session_update_message(invalid_update).empty()) return 10;
  return 0;
}
