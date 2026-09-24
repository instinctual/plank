// SPDX-License-Identifier: GPL-3.0-or-later
// Authorized hardware probe. Counts native buffers only; saves no images/audio.
#include "linuxnativecamera.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <unistd.h>

int main(int argc, char** argv)
{
    using Camera = PlankLinuxNativeCamera;
    if (argc != 3 || (std::strcmp(argv[2], "h264") && std::strcmp(argv[2], "mjpeg"))) {
        std::fprintf(stderr, "Usage: native-camera-capture DEVICE h264|mjpeg\n"); return 2;
    }
    // A process crash closes the descriptor; the ordinary bounded path also
    // restores the prior format. No forced takeover of an existing stream.
    alarm(15);
    const auto codec = !std::strcmp(argv[2], "h264") ? Camera::Codec::H264 : Camera::Codec::Mjpeg;
    Camera camera;
    if (!camera.open(argv[1], codec, 1280, 720)) { std::puts("native_capture_open=failed"); return 1; }
    const auto format = camera.format();
    std::printf("native_capture_open=pass width=%u height=%u colorspace=%u transfer=%u ycbcr=%u quantization=%u\n",
        format.width, format.height, format.colorspace, format.xfer_func, format.ycbcr_enc, format.quantization);
    unsigned frames = 0, dropped = 0, keys = 0, discontinuities = 0, requests = 0, recovered = 0;
    std::uint64_t bytes = 0, first = 0, last = 0;
    auto requestTime = std::chrono::steady_clock::time_point {};
    long long maxRecoveryUs = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    while (frames < 90 && std::chrono::steady_clock::now() < deadline) {
        Camera::Frame frame;
        const auto result = camera.read(frame);
        if (result == Camera::Result::Failed) break;
        if (result == Camera::Result::Dropped) ++dropped;
        if (result != Camera::Result::Frame) continue;
        ++frames; bytes += frame.bytes.size(); keys += frame.independent;
        discontinuities += frame.discontinuity;
        if (!first) first = frame.captureTimeUs;
        last = frame.captureTimeUs;
        if (frame.independent && requestTime != std::chrono::steady_clock::time_point {}) {
            const auto delay = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - requestTime).count();
            if (delay < 1000000) ++recovered;
            if (delay > maxRecoveryUs) maxRecoveryUs = delay;
            requestTime = {};
        }
        if (codec == Camera::Codec::H264 && (frames == 20 || frames == 40 || frames == 60)) {
            if (camera.requestKeyframe()) {
                ++requests; requestTime = std::chrono::steady_clock::now();
            }
        }
    }
    const bool restored = camera.close();
    std::printf("native_capture_frames=%u bytes=%llu keys=%u discontinuities=%u dropped=%u span_us=%llu restored=%d\n",
        frames, (unsigned long long)bytes, keys, discontinuities, dropped, (unsigned long long)(last - first), restored);
    std::printf("native_capture_key_requests=%u recovered_under_1s=%u maximum_recovery_us=%lld\n",
        requests, recovered, maxRecoveryUs);
    return frames != 90 || dropped || !keys || !restored ||
        (codec == Camera::Codec::H264 && (requests != 3 || recovered != 3));
}
