#include "nvenc/idr_scheduler.h"

#include <cassert>
#include <chrono>
#include <iostream>

using namespace std::chrono_literals;

int main() {
  using scheduler = nvenc::idr_scheduler;
  const auto start = scheduler::clock::time_point {};
  scheduler refresh;
  assert(!refresh.take_request(start));
  refresh.request();
  assert(refresh.take_request(start));
  assert(!refresh.take_request(start + 1ms));

  // A Client's one-second retry can arrive less than one second after the
  // Host encoded its previous IDR. Preserve that request across normal frames.
  refresh.request();
  assert(!refresh.take_request(start + 906ms));
  assert(!refresh.take_request(start + 999ms));
  assert(refresh.take_request(start + 1000ms));
  assert(!refresh.take_request(start + 2000ms));

  // Repeated requests coalesce; they must not keep postponing the deadline.
  refresh.request();
  assert(refresh.take_request(start + 3s));
  for (int ms = 1; ms < 1000; ++ms) {
    refresh.request();
    assert(!refresh.take_request(start + 3s + std::chrono::milliseconds(ms)));
  }
  assert(refresh.take_request(start + 4s));
  assert(!refresh.take_request(start + 5s));

  // No timer or periodic IDR: the next captured frame fulfills a pending
  // request after a pause, and normal frames do not start an IDR loop.
  refresh.request();
  assert(!refresh.take_request(start + 4100ms));
  assert(refresh.take_request(start + 30s));
  assert(!refresh.take_request(start + 60s));

  // Sustained jitter around the rate limit still produces a refresh for each
  // recovery, without requiring the Client to retry an already sent request.
  scheduler jittered;
  auto last = start;
  jittered.request();
  assert(jittered.take_request(last));
  for (int i = 0; i < 100; ++i) {
    jittered.request();
    assert(!jittered.take_request(last + 850ms));
    assert(jittered.take_request(last + 1010ms));
    last += 1010ms;
  }
  std::cout << "nvenc_idr_recovery=pass coalescing=pass rate_limit=pass\n";
}
