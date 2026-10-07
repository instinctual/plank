// Link-wrapped Linux UHID boundary. The production tablet state machine and
// poll thread run unchanged; no real device or desktop is touched.
#include <gtest/gtest.h>
#include <linux/uhid.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdarg>
#include <algorithm>
#include <cstring>
#include <condition_variable>
#include <map>
#include <thread>
#include "src/raw_hid_tablet.h"
#include <moonlight-common-c/src/plank.h>

using namespace std::chrono_literals;
extern "C" int __real_open(const char *, int, ...);
extern "C" int __real_close(int);
extern "C" ssize_t __real_write(int, const void *, size_t);

namespace {
  struct Endpoint {
    int peer;
    std::vector<uhid_event> replies;
  };
  std::mutex io_mutex;
  std::condition_variable changed;
  std::map<int, Endpoint> endpoints;
  bool auto_start = true;

  std::vector<std::uint8_t> frame(std::uint16_t type, std::uint16_t generation,
                                const void *payload = nullptr, std::size_t size = 0) {
    PLANK_RAW_HID_WIRE_HEADER header {};
    header.magic = util::endian::little<std::uint32_t>(PLANK_RAW_HID_WIRE_MAGIC);
    header.version = util::endian::little<std::uint16_t>(PLANK_RAW_HID_WIRE_VERSION);
    header.type = util::endian::little(type);
    header.generation = util::endian::little(generation);
    header.payloadLength = util::endian::little<std::uint32_t>(size);
    std::vector<std::uint8_t> bytes(sizeof(header) + size);
    std::memcpy(bytes.data(), &header, sizeof(header));
    if (size) std::memcpy(bytes.data() + sizeof(header), payload, size);
    return bytes;
  }

  void attach(raw_hid::tablet_t &tablet, std::uint16_t generation) {
    PLANK_RAW_HID_DEVICE_MESSAGE device {};
    device.interfaceCount = util::endian::little<std::uint16_t>(1);
    device.bus = util::endian::little<std::uint16_t>(3);
    device.vendor = util::endian::little<std::uint32_t>(0x056a);
    device.product = util::endian::little<std::uint32_t>(0x0358);
    const std::uint8_t descriptor[] {0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0xc0};
    ASSERT_TRUE(tablet.handle(frame(PLANK_RAW_HID_DEVICE, generation, &device, sizeof(device))));
    ASSERT_TRUE(tablet.handle(frame(PLANK_RAW_HID_DESCRIPTOR, generation, descriptor, sizeof(descriptor))));
  }

  void inject(const uhid_event &event) {
    std::lock_guard lock(io_mutex);
    ASSERT_EQ(endpoints.size(), 1);
    EXPECT_EQ(__real_write(endpoints.begin()->second.peer, &event, sizeof(event)), sizeof(event));
  }

  std::optional<uhid_event> reply(std::uint32_t type) {
    std::unique_lock lock(io_mutex);
    if (!changed.wait_for(lock, 1s, [&] {
      if (endpoints.empty()) return false;
      return std::ranges::any_of(endpoints.begin()->second.replies, [=](auto &event) { return event.type == type; });
    })) return std::nullopt;
    for (auto &event : endpoints.begin()->second.replies) if (event.type == type) return event;
    return std::nullopt;
  }

  class RawHidLifecycle : public ::testing::Test {
    void SetUp() override { std::lock_guard lock(io_mutex); auto_start = false; }
    void TearDown() override { std::lock_guard lock(io_mutex); auto_start = true; EXPECT_TRUE(endpoints.empty()); }
  };
}

extern "C" int __wrap_open(const char *path, int flags, ...) {
  if (std::strcmp(path, "/dev/uhid") != 0) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
      va_list ap; va_start(ap, flags); mode = va_arg(ap, unsigned int); va_end(ap);
    }
    return __real_open(path, flags, mode);
  }
  int sockets[2];
  if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, sockets) != 0) return -1;
  std::lock_guard lock(io_mutex);
  endpoints.emplace(sockets[0], Endpoint {sockets[1], {}});
  return sockets[0];
}

extern "C" int __wrap_close(int fd) {
  std::lock_guard lock(io_mutex);
  auto found = endpoints.find(fd);
  if (found != endpoints.end()) {
    __real_close(found->second.peer);
    endpoints.erase(found);
  }
  return __real_close(fd);
}

extern "C" ssize_t __wrap_write(int fd, const void *data, size_t size) {
  std::lock_guard lock(io_mutex);
  auto found = endpoints.find(fd);
  if (found == endpoints.end()) return __real_write(fd, data, size);
  if (size != sizeof(uhid_event)) { errno = EINVAL; return -1; }
  uhid_event event;
  std::memcpy(&event, data, sizeof(event));
  found->second.replies.push_back(event);
  if (event.type == UHID_CREATE2 && auto_start) {
    uhid_event start {}; start.type = UHID_START;
    if (__real_write(found->second.peer, &start, sizeof(start)) != sizeof(start)) return -1;
  }
  changed.notify_all();
  return size;
}

TEST_F(RawHidLifecycle, LateStartWhileSuspendedCanBeReusedAndRequestsComplete) {
  auto queue = std::make_shared<raw_hid::feedback_queue_t::element_type>(std::make_shared<safe::mail_raw_t>());
  raw_hid::tablet_t tablet {queue};
  attach(tablet, 1);
  auto epoch = tablet.endpoint_epoch();
  ASSERT_TRUE(tablet.handle(frame(PLANK_RAW_HID_SUSPEND, 1)));
  uhid_event event {}; event.type = UHID_START;
  inject(event);
  event.type = UHID_GET_REPORT; event.u.get_report.id = 123;
  inject(event);
  auto get = reply(UHID_GET_REPORT_REPLY);
  ASSERT_TRUE(get);
  EXPECT_EQ(get->u.get_report_reply.id, 123);
  EXPECT_EQ(get->u.get_report_reply.err, ENOTCONN);
  event = {}; event.type = UHID_SET_REPORT; event.u.set_report.id = 124;
  inject(event);
  auto set = reply(UHID_SET_REPORT_REPLY);
  ASSERT_TRUE(set);
  EXPECT_EQ(set->u.set_report_reply.id, 124);
  EXPECT_EQ(set->u.set_report_reply.err, ENOTCONN);
  EXPECT_FALSE(queue->peek());
  attach(tablet, 2);
  EXPECT_EQ(tablet.endpoint_epoch(), epoch);
  ASSERT_TRUE(queue->pop(1s));
}

TEST_F(RawHidLifecycle, InterruptedProbeIsNotFalselyAcknowledgedAsReady) {
  auto queue = std::make_shared<raw_hid::feedback_queue_t::element_type>(std::make_shared<safe::mail_raw_t>());
  raw_hid::tablet_t tablet {queue};
  attach(tablet, 1);
  auto epoch = tablet.endpoint_epoch();
  tablet.suspend();
  tablet.rebind(queue);
  attach(tablet, 2);
  EXPECT_GT(tablet.endpoint_epoch(), epoch);
  EXPECT_FALSE(queue->peek());
  uhid_event event {}; event.type = UHID_START;
  inject(event);
  ASSERT_TRUE(queue->pop(1s));
}

TEST_F(RawHidLifecycle, FeedbackOverflowFailsClosedInsteadOfDroppingRequests) {
  auto queue = std::make_shared<raw_hid::feedback_queue_t::element_type>(std::make_shared<safe::mail_raw_t>(), 1);
  raw_hid::tablet_t tablet {queue};
  attach(tablet, 1);
  uhid_event event {}; event.type = UHID_START;
  inject(event);
  event.type = UHID_OPEN;
  inject(event);
  auto deadline = std::chrono::steady_clock::now() + 1s;
  while (queue->running() && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(1ms);
  EXPECT_FALSE(queue->running());
}

TEST_F(RawHidLifecycle, SuspendCancelsRequestsAlreadySentToTheClient) {
  auto queue = std::make_shared<raw_hid::feedback_queue_t::element_type>(std::make_shared<safe::mail_raw_t>());
  raw_hid::tablet_t tablet {queue};
  attach(tablet, 1);
  uhid_event event {}; event.type = UHID_START;
  inject(event);
  ASSERT_TRUE(queue->pop(1s));
  event.type = UHID_GET_REPORT; event.u.get_report.id = 125;
  inject(event);
  ASSERT_TRUE(queue->pop(1s)); // Request is in flight; Client has not answered.
  event = {}; event.type = UHID_SET_REPORT; event.u.set_report.id = 126;
  inject(event);
  ASSERT_TRUE(queue->pop(1s));
  ASSERT_TRUE(tablet.handle(frame(PLANK_RAW_HID_SUSPEND, 1)));
  auto get = reply(UHID_GET_REPORT_REPLY);
  auto set = reply(UHID_SET_REPORT_REPLY);
  ASSERT_TRUE(get && set);
  EXPECT_EQ(get->u.get_report_reply.id, 125);
  EXPECT_EQ(get->u.get_report_reply.err, ENOTCONN);
  EXPECT_EQ(set->u.set_report_reply.id, 126);
  EXPECT_EQ(set->u.set_report_reply.err, ENOTCONN);
}
