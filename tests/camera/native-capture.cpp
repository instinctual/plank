// SPDX-License-Identifier: GPL-3.0-or-later
// Kernel-boundary fixture: exact copies, busy/emulated/coerced-mode rejection,
// buffer faults and restoration on partial setup. Never opens a real camera.
#include "linuxnativecamera.h"
#include "nativecameraframe.h"
#include "uvch264control.h"
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <poll.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>

#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "camera_test_failed line=%d\n", __LINE__); std::exit(1); } } while (0)
namespace {
constexpr int Device = 444;
const std::vector<std::uint8_t> H264 {0,0,0,1,0x67,0x42,0x80, 0,0,1,0x68,0x80, 0,0,1,0x65,0x80};
const std::vector<std::uint8_t> JPEG {0xff,0xd8, 0xff,0xc0,0,11,8,2,0xd0,5,0,1,1,0x11,0,
    0xff,0xda,0,8,1,1,0,0,63,0, 0x12,0xff,0,0x56,0xff,0xd0,0x34,0xff,0xd9};
struct Fixture {
    bool emulated = false, busy = false, wrongMode = false, wrongRate = false, streaming = false;
    bool malformed = false, badIndex = false, badTimestamp = false, error = false;
    unsigned maps = 0, unmaps = 0, closed = 0, restores = 0, parameterRestores = 0;
    unsigned dequeues = 0, queues = 0, sequence = 0, failMapping = 99, failQueue = 99;
    bool allocated = false;
    v4l2_format format {};
    std::vector<std::uint8_t> data;
} fixture;
void reset() { fixture = {}; fixture.failMapping = fixture.failQueue = 99; }
}
extern "C" int __wrap_open(const char*, int, ...) { return Device; }
extern "C" int __wrap_fstat(int fd, struct stat* result)
{ CHECK(fd == Device); *result = {}; result->st_mode = S_IFCHR; return 0; }
extern "C" int __wrap_close(int fd) { CHECK(fd == Device); ++fixture.closed; return 0; }
extern "C" void* __wrap_mmap(void*, size_t, int, int, int fd, off_t)
{
    CHECK(fd == Device);
    if (fixture.maps == fixture.failMapping) { errno = ENOMEM; return MAP_FAILED; }
    ++fixture.maps; return fixture.data.data();
}
extern "C" int __wrap_munmap(void*, size_t) { ++fixture.unmaps; return 0; }
extern "C" int __wrap_poll(pollfd* fd, nfds_t count, int wait)
{ CHECK(count == 1 && fd->fd == Device && wait <= 50); fd->revents = POLLIN; return 1; }
extern "C" int __wrap_ioctl(int fd, unsigned long request, void* pointer)
{
    CHECK(fd == Device);
    switch (request) {
    case VIDIOC_QUERYCAP: {
        auto* p = static_cast<v4l2_capability*>(pointer);
        p->capabilities = V4L2_CAP_DEVICE_CAPS;
        p->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING; return 0;
    }
    case VIDIOC_ENUM_FMT: {
        auto* p = static_cast<v4l2_fmtdesc*>(pointer);
        if (p->index > 1) { errno = EINVAL; return -1; }
        p->pixelformat = p->index ? V4L2_PIX_FMT_MJPEG : V4L2_PIX_FMT_H264;
        p->flags = V4L2_FMT_FLAG_COMPRESSED | (fixture.emulated ? V4L2_FMT_FLAG_EMULATED : 0); return 0;
    }
    case VIDIOC_G_FMT: *static_cast<v4l2_format*>(pointer) = fixture.format; return 0;
    case VIDIOC_S_FMT: {
        if (fixture.busy) { errno = EBUSY; return -1; }
        fixture.format = *static_cast<v4l2_format*>(pointer);
        if (!fixture.format.fmt.pix.width) { ++fixture.restores; return 0; }
        fixture.format.fmt.pix.sizeimage = 4096;
        if (fixture.wrongMode) fixture.format.fmt.pix.width = 640;
        fixture.data = fixture.format.fmt.pix.pixelformat == V4L2_PIX_FMT_H264 ? H264 : JPEG;
        return 0;
    }
    case VIDIOC_S_PARM: {
        auto* p = static_cast<v4l2_streamparm*>(pointer);
        if (!p->parm.capture.timeperframe.numerator) ++fixture.parameterRestores;
        return 0;
    }
    case VIDIOC_G_PARM: {
        auto* p = static_cast<v4l2_streamparm*>(pointer);
        if (fixture.format.fmt.pix.width) p->parm.capture.timeperframe = {1, fixture.wrongRate ? 15u : 30u};
        return 0;
    }
    case VIDIOC_REQBUFS: fixture.allocated = static_cast<v4l2_requestbuffers*>(pointer)->count != 0; return 0;
    case VIDIOC_QUERYBUF: static_cast<v4l2_buffer*>(pointer)->length = 4096; return 0;
    case VIDIOC_QBUF:
        if (fixture.queues++ == fixture.failQueue) { errno = EIO; return -1; }
        return 0;
    case VIDIOC_STREAMON: fixture.streaming = true; return 0;
    case VIDIOC_STREAMOFF: fixture.streaming = false; return 0;
    case VIDIOC_DQBUF: {
        auto* p = static_cast<v4l2_buffer*>(pointer);
        timespec now {}; CHECK(!clock_gettime(CLOCK_MONOTONIC, &now));
        p->index = fixture.badIndex ? 12 : 0;
        p->bytesused = fixture.data.size();
        p->flags = fixture.badTimestamp ? 0 : V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;
        if (fixture.error) p->flags |= V4L2_BUF_FLAG_ERROR;
        p->sequence = fixture.sequence++;
        p->timestamp = {now.tv_sec, now.tv_nsec / 1000};
        if (fixture.malformed) fixture.data[0] = 0x55;
        ++fixture.dequeues; return 0;
    }
    default: errno = EINVAL; return -1;
    }
}
int main()
{
    using Camera = PlankLinuxNativeCamera;
    using namespace PlankNativeCameraFrame;
    const std::vector<std::uint8_t> descriptors {9,2,45,0,1,1,0,0x80,50,
        9,4,0,0,0,14,1,0,0,
        27,0x24,6,7,0x41,0x76,0x9e,0xa2,0x04,0xde,0xe3,0x47,0x8b,0x2b,0xf4,0x34,0x1a,0xff,0,0x3b,
        15,1,2,2,0xff,1,0};
    CHECK(plankUvcH264Unit(descriptors.data(), descriptors.size(), 1, 0) == 7);
    CHECK(!plankUvcH264Unit(descriptors.data(), descriptors.size(), 2, 0));
    CHECK(!plankUvcH264Unit(descriptors.data(), descriptors.size(), 1, 1));
    for (size_t length = 0; length < descriptors.size(); ++length)
        CHECK(!plankUvcH264Unit(descriptors.data(), length, 1, 0));
    auto invalidDescriptor = descriptors; invalidDescriptor[39] = 250;
    CHECK(!plankUvcH264Unit(invalidDescriptor.data(), invalidDescriptor.size(), 1, 0));
    invalidDescriptor = descriptors; invalidDescriptor[22] ^= 1;
    CHECK(!plankUvcH264Unit(invalidDescriptor.data(), invalidDescriptor.size(), 1, 0));
    bool independent = false;
    CHECK(h264(H264.data(), H264.size(), independent) && independent);
    CHECK(mjpeg(JPEG.data(), JPEG.size(), 1280, 720));
    CHECK(!mjpeg(JPEG.data(), JPEG.size(), 1920, 1080));
    for (size_t length = 0; length < JPEG.size(); ++length) CHECK(!mjpeg(JPEG.data(), length, 1280, 720));
    for (size_t length = 0; length < H264.size(); ++length) {
        bool key = true; h264(H264.data(), length, key);
        CHECK(!key);
    }
    auto bad = H264; bad[4] |= 0x80; CHECK(!h264(bad.data(), bad.size(), independent));
    bad = JPEG; bad[5] = 0xff; CHECK(!mjpeg(bad.data(), bad.size(), 1280, 720));
    for (auto codec : {Camera::Codec::H264, Camera::Codec::Mjpeg}) {
        reset(); Camera camera; Camera::Frame frame;
        CHECK(camera.open("fixture", codec, 1280, 720));
        CHECK(camera.read(frame, 1000) == Camera::Result::Frame);
        CHECK(frame.bytes == (codec == Camera::Codec::H264 ? H264 : JPEG));
        CHECK(frame.independent && frame.discontinuity && frame.captureTimeUs);
        CHECK(camera.requestKeyframe() == (codec == Camera::Codec::Mjpeg));
        CHECK(camera.close());
        CHECK(fixture.maps == 4 && fixture.unmaps == 4 && fixture.closed == 1);
        CHECK(!fixture.streaming && !fixture.allocated && fixture.restores == 1 && fixture.parameterRestores == 1);
    }
    for (unsigned failure = 0; failure < 6; ++failure) {
        reset();
        fixture.emulated = failure == 0; fixture.busy = failure == 1;
        fixture.wrongMode = failure == 2; fixture.wrongRate = failure == 3;
        fixture.failMapping = failure == 4 ? 2 : 99; fixture.failQueue = failure == 5 ? 2 : 99;
        Camera camera; CHECK(!camera.open("fixture", Camera::Codec::H264, 1280, 720));
        CHECK(!fixture.streaming && !fixture.allocated && fixture.maps == fixture.unmaps && fixture.closed == 1);
        CHECK(fixture.restores == (failure >= 2 ? 1u : 0u));
    }
    for (unsigned failure = 0; failure < 4; ++failure) {
        reset(); Camera camera; Camera::Frame frame;
        CHECK(camera.open("fixture", Camera::Codec::H264, 1280, 720));
        fixture.badIndex = failure == 0; fixture.badTimestamp = failure == 1;
        fixture.malformed = failure == 2; fixture.error = failure == 3;
        CHECK(camera.read(frame) == (failure < 2 ? Camera::Result::Failed : Camera::Result::Dropped));
        CHECK(frame.bytes.empty());
        CHECK(camera.close()); CHECK(fixture.maps == fixture.unmaps && fixture.closed == 1);
    }
    std::puts("native_camera_capture=pass payload_copy=exact partial_cleanup=pass malformed=reject native_mode=required");
}
