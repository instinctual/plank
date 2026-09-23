// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic SDL dummy input, mocked authenticated transport. Never opens a
// real device. Encrypted endpoint delivery is independently exercised in Rust.
#include "microphone.h"
#include <plank_transport.h>
#include <plank_transport_control.h>
#include <SDL3/SDL.h>
#include <opus.h>
#include <atomic>
#include <cstdlib>
#include <cstdio>
#include <functional>

#ifdef __APPLE__
// The SDL dummy backend is mandatory here. Never request real TCC permission
// or touch a physical recording device on a build worker.
int plankMacMicrophonePermission(bool) { return 1; }
#endif

#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "check failed line %d\n", __LINE__); std::exit(1); } } while (0)
struct PlankTransportNativeEndpoint {
    std::mutex mutex;
    std::uint64_t command = 0, activation = 0;
    std::uint32_t flags = 0;
    std::atomic<unsigned> packets {0};
    std::atomic<bool> blocked {false};
    std::atomic<unsigned> laneState {2};
};
extern "C" int32_t plank_transport_native_data_send(PlankTransportNativeEndpoint* endpoint,
                                                    const uint8_t* bytes, size_t size)
{
    if (endpoint->blocked.load()) return PLANK_TRANSPORT_TIMEOUT;
    PlankTransportControlPacket packet {};
    CHECK(!plank_transport_control_decode(bytes, size, &packet));
    CHECK(packet.type == PLANK_TRANSPORT_CONTROL_SET_MICROPHONE && packet.payload_size == 12);
    std::lock_guard<std::mutex> lock(endpoint->mutex);
    const auto command = uint64_t(plank_transport_control_read_u32(packet.payload)) << 32 |
            plank_transport_control_read_u32(packet.payload + 4);
    CHECK(command > endpoint->command);
    endpoint->command = command;
    endpoint->flags = plank_transport_control_read_u32(packet.payload + 8);
    return PLANK_TRANSPORT_OK;
}
extern "C" uint32_t plank_transport_native_microphone_state(const PlankTransportNativeEndpoint* endpoint)
{ return endpoint->laneState.load(); }
extern "C" int32_t plank_transport_native_microphone_activate(PlankTransportNativeEndpoint* endpoint, uint64_t generation)
{
    std::lock_guard<std::mutex> lock(endpoint->mutex); endpoint->activation = generation; return 0;
}
extern "C" int32_t plank_transport_native_microphone_send(PlankTransportNativeEndpoint* endpoint,
    uint64_t generation, uint64_t sampleTime, const uint8_t* bytes, size_t size)
{
    std::lock_guard<std::mutex> lock(endpoint->mutex);
    CHECK(generation && generation == endpoint->activation && generation == endpoint->command);
    CHECK(endpoint->flags & PLANK_TRANSPORT_MICROPHONE_ENABLED);
    CHECK(sampleTime % 480 == 0 && size <= 1275 && size);
    CHECK(opus_packet_get_nb_samples(bytes, int(size), 48000) == 480);
    CHECK(opus_packet_get_nb_channels(bytes) == 1);
    return endpoint->packets.fetch_add(1) % 3 == 0 ? PLANK_TRANSPORT_DROPPED : PLANK_TRANSPORT_OK;
}
int main()
{
    CHECK(SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "dummy"));
    PlankTransportNativeEndpoint endpoint;
    std::atomic<bool> requested {false};
    {
        PlankMicrophone microphone(&endpoint, requested, true);
        const auto wait = [&](const std::function<bool()>& predicate) {
            for (unsigned i = 0; i < 400; ++i) {
                {
                    std::lock_guard<std::mutex> lock(endpoint.mutex);
                    if (endpoint.command) microphone.acknowledge(endpoint.command,
                        endpoint.flags & PLANK_TRANSPORT_MICROPHONE_ENABLED ?
                        PLANK_TRANSPORT_MICROPHONE_ACTIVE : PLANK_TRANSPORT_MICROPHONE_OFF);
                }
                if (predicate()) return true;
                SDL_Delay(5);
            }
            return false;
        };
        CHECK(wait([&] { std::lock_guard<std::mutex> guard(endpoint.mutex); return endpoint.command != 0; }));
        CHECK(wait([&] { return microphone.state() == PlankMicrophone::State::Off; }));
        CHECK(!endpoint.packets && !SDL_WasInit(SDL_INIT_AUDIO));
        requested = true;
        CHECK(wait([&] { return endpoint.packets >= 20 && microphone.state() == PlankMicrophone::State::Active; }));
        endpoint.blocked = true; requested = false;
        CHECK(wait([&] { return !SDL_WasInit(SDL_INIT_AUDIO); }));
        unsigned before = endpoint.packets; SDL_Delay(50); CHECK(endpoint.packets == before);
        endpoint.blocked = false;
        CHECK(wait([&] { return microphone.state() == PlankMicrophone::State::Off; }));
        requested = true;
        CHECK(wait([&] { return endpoint.packets > before + 10; }));
        endpoint.laneState = 3;
        CHECK(wait([&] { return microphone.state() == PlankMicrophone::State::Unavailable && !SDL_WasInit(SDL_INIT_AUDIO); }));
    }
    CHECK(!SDL_WasInit(SDL_INIT_AUDIO));
    {
        std::lock_guard<std::mutex> guard(endpoint.mutex); CHECK(endpoint.activation == 0);
    }
    puts("client_microphone_dummy_capture_mute_pressure_reopen_failure_cleanup=pass");
}
