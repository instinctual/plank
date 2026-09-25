// SPDX-License-Identifier: GPL-3.0-or-later
// Behavioral tests of the production Linux discovery policy and private update.
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "session/session_context.h"
#include <cassert>
#include <cstdio>

namespace session = plank::session;

int main() {
  session::update_t attached {
    7, {"test-session", 1000, "seat0", "x11", "user", "active", true, false},
    {":0", "/run/user/1000/test-Xauthority", "/run/user/1000", "", "", ""},
    "example-user@example.test"
  };
  auto active = attached.session;
  auto result = session::desktop_occupancy(attached, active, false);
  assert(result.desktop_owned && !result.account_name);
  result = session::desktop_occupancy(attached, active, true);
  assert(result.desktop_owned && result.account_name == "example-user");
  // A local user remains occupied without any remote stream or NSS lookup.
  for (int i = 0; i < 10000; ++i)
    assert(session::desktop_occupancy(attached, active, true).account_name == "example-user");
  for (const auto &bad : {std::string {}, std::string(65, 'x'), std::string("a<b"),
                          std::string("two words"), std::string("a\0b", 3)}) {
    attached.account_name = bad;
    result = session::desktop_occupancy(attached, active, true);
    assert(result.desktop_owned && !result.account_name);
  }
  attached.account_name = std::string(64, 'x');
  assert(session::desktop_occupancy(attached, active, true).account_name->size() == 64);
  attached.account_name = "example-user@example.test";
  auto wire = session::session_update_message(attached);
  auto decoded = session::parse_session_update(wire);
  assert(decoded && decoded->account_name == "example-user" && decoded->generation == 7);
  assert(!session::parse_session_update(wire.substr(0, wire.size() - 1)));
  auto invalid = wire;
  invalid.replace(invalid.rfind("example-user"), 12, "<script>");
  assert(!session::parse_session_update(invalid));
  invalid = wire;
  invalid.replace(0, std::string_view("SC-SESSION-3").size(), "SC-SESSION-2");
  assert(!session::parse_session_update(invalid));
  active.id = "replacement";
  result = session::desktop_occupancy(attached, active, true);
  assert(!result.desktop_owned && !result.account_name);
  active = attached.session;
  ++active.uid;
  assert(!session::desktop_occupancy(attached, active, true).account_name);
  active = attached.session;
  active.active = false;
  assert(!session::desktop_occupancy(attached, active, true).desktop_owned);
  active = attached.session;
  active.state = "closing";
  assert(!session::desktop_occupancy(attached, active, true).account_name);
  active = attached.session;
  active.session_class = "greeter";
  assert(!session::desktop_occupancy(attached, active, true).account_name);
  attached.session = active;
  result = session::desktop_occupancy(attached, active, true);
  assert(!result.desktop_owned && !result.account_name);
  decoded = session::parse_session_update(session::session_update_message(attached));
  assert(decoded && decoded->account_name.empty());
  assert(!session::confirmed_desktop_occupancy(true).account_name);
  std::puts("occupancy_policy=pass transitions=1 names_bounded=1 default_private=1 cached_identity=1");
}
