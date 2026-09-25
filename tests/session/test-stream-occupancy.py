#!/usr/bin/env python3
"""Exercise the production stream owner without linking GPU/media workers.

Compile the complete, unchanged private session_server_t class with its real
launch/event/mutex types. Only logging and media stop/join are test doubles.
This keeps discovery's nonblocking contract testable without a media refactor.
"""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
host = root / "apps/host/linux"
source = (host / "src/session_stream.cpp").read_text()
start = "  class session_server_t {"
end = "\n  session_server_t server {};"
assert source.count(start) == source.count(end) == 1, "stream owner boundary changed"
owner = source.split(start, 1)[1].split(end, 1)[0]

fixture = r'''
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <future>
#include <memory>
#include <mutex>
#include <set>
#include <sstream>
#include <thread>
#include "session_stream.h"
#include "sync.h"
#include "thread_safe.h"
using namespace std::literals;
#define BOOST_LOG(level) std::ostringstream()
namespace stream {
  struct session_t { bool stopping {}; };
  namespace session {
    enum class state_e { RUNNING, STOPPING };
    std::mutex join_mutex;
    std::condition_variable join_cv;
    bool joined {}, block_join {}, release_join {};
    state_e state(session_t &s) { return s.stopping ? state_e::STOPPING : state_e::RUNNING; }
    void stop(session_t &s, std::uint32_t = 0) { s.stopping = true; }
    void notify_desktop_handoff(session_t &) {}
    void join(session_t &) {
      std::unique_lock lock {join_mutex};
      joined = true;
      join_cv.notify_all();
      if (block_join) join_cv.wait(lock, [] { return release_join; });
    }
  }
}
namespace session_stream {
''' + start + owner + r'''
}
int main() {
  session_stream::session_server_t owner;
  assert(!owner.has_stream_session());
  auto launch = std::make_shared<session_stream::launch_session_t>();
  launch->id = 1;
  owner.session_raise(launch);
  assert(owner.has_stream_session());
  owner.session_complete(2); // wrong completion cannot clear a reservation
  assert(owner.has_stream_session());
  assert(owner.revoke_launch() == launch);
  assert(!owner.has_stream_session());
  owner.session_raise(launch);
  owner.session_complete(1); // failed setup, no media slot
  assert(!owner.has_stream_session());
  owner.launch_event.pop(0s);
  owner.session_raise(launch);
  auto first = std::make_shared<stream::session_t>();
  auto second = std::make_shared<stream::session_t>();
  owner.insert(first);
  owner.session_complete(1); // successful setup transfers occupancy to slot
  assert(owner.has_stream_session());
  owner.insert(second);
  owner.remove(first);
  assert(owner.has_stream_session());
  owner.remove(second);
  assert(!owner.has_stream_session());
  owner.insert(first);
  first->stopping = false;
  owner.clear(false);
  assert(owner.has_stream_session() && !stream::session::joined);
  first->stopping = true;
  stream::session::block_join = true;
  auto cleanup = std::async(std::launch::async, [&] { owner.clear(false); });
  {
    std::unique_lock lock {stream::session::join_mutex};
    assert(stream::session::join_cv.wait_for(lock, 2s, [] { return stream::session::joined; }));
  }
  // A stuck media join holds the real session mutex. Discovery must not wait.
  auto poll = std::async(std::launch::async, [&] { return owner.has_stream_session(); });
  const bool nonblocking = poll.wait_for(2s) == std::future_status::ready;
  {
    std::lock_guard lock {stream::session::join_mutex};
    stream::session::release_join = true;
  }
  stream::session::join_cv.notify_all();
  cleanup.get();
  assert(nonblocking && poll.get());
  assert(!owner.has_stream_session());
}
'''
with tempfile.TemporaryDirectory(prefix="plank-stream-occupancy-") as temporary:
    executable = str(Path(temporary) / "test")
    subprocess.run([os.environ.get("CXX", "c++"), "-std=c++23", "-Wall", "-Wextra",
                    "-Werror", "-pthread", "-I" + str(host / "src"), "-x", "c++",
                    "-", "-o", executable], input=fixture, text=True, check=True, timeout=60)
    subprocess.run([executable], check=True, timeout=15)
print("stream_occupancy=pass actual_owner=1 pending_setup=1 slot_lifecycle=1 nonblocking_during_join=1")
