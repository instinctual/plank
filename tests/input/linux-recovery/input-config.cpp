// Component-fixture settings only. The full Host suite links config.cpp and
// validates actual product defaults; this harness does not parse host.conf.
#include "src/config.h"

namespace config {
input_t input {
  {{0x10, 0xA0}, {0x11, 0xA2}, {0x12, 0xA4}},
  std::chrono::milliseconds {500}, std::chrono::duration<double> {1 / 24.9},
  true, false, true, true, true
};
}
