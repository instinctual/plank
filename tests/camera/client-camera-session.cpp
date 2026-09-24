// SPDX-License-Identifier: GPL-3.0-or-later
#include "streaming/camera/camera.h"
#include "plank_transport.h"
#include "plank_transport_camera.h"
#include <QCoreApplication>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <vector>

static std::mutex controlMutex;
static std::vector<std::pair<uint64_t, uint32_t>> commands;
static std::atomic<unsigned> frames {0}, activations {0};
extern "C" int32_t plank_transport_native_camera_activate(PlankTransportNativeEndpoint*, uint64_t generation) {
    if (generation) activations++;
    return PLANK_TRANSPORT_OK;
}
extern "C" uint32_t plank_transport_native_camera_state(const PlankTransportNativeEndpoint*) { return 2; }
extern "C" uint64_t plank_transport_native_camera_keyframe_needed(const PlankTransportNativeEndpoint*) { return 0; }
extern "C" int32_t plank_transport_native_camera_send(PlankTransportNativeEndpoint*, const uint8_t*, size_t) { frames++; return PLANK_TRANSPORT_OK; }
extern "C" int32_t plank_transport_native_data_send(PlankTransportNativeEndpoint*, const uint8_t* bytes, size_t size) {
    PlankTransportControlPacket packet{}; uint64_t generation = 0; uint32_t flags = 0;
    assert(!plank_transport_control_decode(bytes, size, &packet));
    assert(packet.type == PLANK_TRANSPORT_CONTROL_SET_CAMERA);
    assert(!plank_camera_control_decode(&packet, &generation, &flags));
    std::lock_guard<std::mutex> guard(controlMutex); commands.emplace_back(generation, flags);
    return PLANK_TRANSPORT_OK;
}
template<class Predicate> static void wait(Predicate predicate) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!predicate()) {
        assert(std::chrono::steady_clock::now() < deadline);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}
static std::pair<uint64_t,uint32_t> command(unsigned count) {
    wait([&] { std::lock_guard<std::mutex> guard(controlMutex); return commands.size() >= count; });
    std::lock_guard<std::mutex> guard(controlMutex); return commands[count - 1];
}
int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    std::atomic<bool> requested {false};
    {
        // An explicit nonexistent selection must fail, never open an unrelated
        // camera. No successful capture or real transport is needed here.
        PlankCamera camera(reinterpret_cast<PlankTransportNativeEndpoint*>(uintptr_t(1)), requested,
            QStringLiteral("/dev/plank-test-camera-does-not-exist"));
        auto off = command(1); assert(off.second == 0);
        camera.acknowledge(off.first, PLANK_TRANSPORT_CAMERA_OFF);
        wait([&] { return camera.state() == PlankCamera::State::Off; });
        requested = true;
        auto on = command(2); assert(on.first > off.first && on.second == 1);
        camera.acknowledge(off.first, PLANK_TRANSPORT_CAMERA_ACTIVE);
        camera.requestKeyframe(off.first);
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
        assert(camera.state() == PlankCamera::State::Pending && !frames && !activations);
        camera.acknowledge(on.first, PLANK_TRANSPORT_CAMERA_PENDING);
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
        assert(camera.state() == PlankCamera::State::Pending && !frames && !activations);
        // Cancel before admission. A delayed ON cannot reactivate capture.
        requested = false;
        auto cancelled = command(3); assert(cancelled.first > on.first && cancelled.second == 0);
        camera.acknowledge(on.first, PLANK_TRANSPORT_CAMERA_ACTIVE);
        camera.acknowledge(cancelled.first, PLANK_TRANSPORT_CAMERA_OFF);
        wait([&] { return camera.state() == PlankCamera::State::Off; });
        assert(!frames && !activations);
        requested = true;
        auto retry = command(4); assert(retry.second == 1);
        camera.acknowledge(retry.first, PLANK_TRANSPORT_CAMERA_ACTIVE);
        wait([&] { return camera.state() == PlankCamera::State::Unavailable; });
        auto failed = command(5); assert(failed.first > retry.first && failed.second == 0);
        assert(!frames && !activations);
    }
    puts("camera actor: off by default, ACK gating, stale ACK, cancellation and missing device passed");
}
