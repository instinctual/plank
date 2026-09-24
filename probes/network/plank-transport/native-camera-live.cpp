// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone authorized hardware qualification, never a product authentication
// path. Uses an ephemeral certificate pin and a random token supplied via the
// environment. Receiver records are PRIVATE camera captures, not CI artifacts.
#include "plank_transport.h"
#include "plank_transport_camera.h"
#include <cstdint>
#ifdef __linux__
#include "linuxnativecamera.h"
#include "microphone.h"
#include <QCoreApplication>
#include <openssl/sha.h>
#else
#include <CommonCrypto/CommonDigest.h>
extern "C" {
void* plank_probe_audio_create(void);
void plank_probe_audio_destroy(void*);
bool plank_probe_audio_reset(void*);
bool plank_probe_audio_consume(void*, std::uint64_t, const std::uint8_t*, size_t);
bool plank_probe_audio_finish(void*);
}
#endif
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <stdexcept>
#include <thread>
#include <unistd.h>
#include <vector>

using Clock = std::chrono::steady_clock;
static void require(bool okay) { if (!okay) throw std::runtime_error("camera probe gate failed"); }
struct Endpoint {
    PlankTransportNativeEndpoint* value = nullptr;
    ~Endpoint() { if (value) plank_transport_native_endpoint_destroy(value); }
};
struct File {
    FILE* value = nullptr;
    ~File() { if (value) fclose(value); }
};
enum Command : std::uint8_t { Start = 1, Key = 2, Done = 3, Ack = 4 };
static void send(Endpoint& endpoint, Command command)
{
    const auto end = Clock::now() + std::chrono::seconds(2);
    const auto byte = std::uint8_t(command);
    while (Clock::now() < end) {
        const auto status = plank_transport_native_data_send(endpoint.value, &byte, 1);
        if (status == PLANK_TRANSPORT_OK) return;
        require(status == PLANK_TRANSPORT_TIMEOUT);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    require(false);
}
struct Audio {
    Endpoint& endpoint;
#ifdef __linux__
    std::atomic<bool> requested {true};
    std::unique_ptr<PlankMicrophone> microphone;
    bool sawMute = false, sawReopen = false;
    unsigned phase = 0;
    explicit Audio(Endpoint& value) : endpoint(value),
        microphone(std::make_unique<PlankMicrophone>(value.value, requested, false)) {}
    void control(const PlankTransportControlPacket& packet) {
        require(packet.type == PLANK_TRANSPORT_CONTROL_MICROPHONE_APPLIED && packet.payload_size == 12);
        microphone->acknowledge(plank_camera_read_u64(packet.payload), plank_transport_control_read_u32(packet.payload+8));
    }
    void drain() {
        if (!microphone) return;
        const auto state = microphone->state();
        require(state != PlankMicrophone::State::Unavailable);
        if (phase == 1 && state == PlankMicrophone::State::Off) sawMute = true;
        if (phase == 2 && state == PlankMicrophone::State::Active) sawReopen = true;
    }
    void step(unsigned frames) {
        if (frames == 30) { requested = false; phase = 1; }
        if (frames == 60) { require(sawMute); requested = true; phase = 2; }
    }
    void finish() {
        drain(); require(sawMute && sawReopen);
        microphone.reset();
        std::puts("physical_audio_capture=pass actual_client_module=1 mute=pass reopen=pass");
    }
#else
    void* decoder = nullptr;
    std::uint64_t generation = 0, command = 0;
    unsigned activations = 0, mutes = 0;
    explicit Audio(Endpoint& value) : endpoint(value), decoder(plank_probe_audio_create()) { require(decoder != nullptr); }
    ~Audio() { plank_probe_audio_destroy(decoder); }
    void control(const PlankTransportControlPacket& packet) {
        require(packet.type == PLANK_TRANSPORT_CONTROL_SET_MICROPHONE && packet.payload_size == 12);
        const auto next = plank_camera_read_u64(packet.payload);
        const auto flags = plank_transport_control_read_u32(packet.payload+8);
        require(next > command && !(flags & ~PLANK_TRANSPORT_MICROPHONE_ENABLED));
        generation = flags ? next : 0; command = next;
        require(plank_transport_native_microphone_activate(endpoint.value, generation) == PLANK_TRANSPORT_OK);
        require(plank_probe_audio_reset(decoder));
        if (flags) ++activations; else ++mutes;
        const std::uint32_t words[] = {std::uint32_t(command >> 32), std::uint32_t(command),
            flags ? PLANK_TRANSPORT_MICROPHONE_ACTIVE : PLANK_TRANSPORT_MICROPHONE_OFF};
        std::uint8_t bytes[20]; size_t size = 0;
        require(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_MICROPHONE_APPLIED,
            words, 3, bytes, sizeof(bytes), &size));
        require(plank_transport_native_data_send(endpoint.value, bytes, size) == PLANK_TRANSPORT_OK);
    }
    void drain() {
        for (unsigned i = 0; i < 16; ++i) {
            std::uint8_t bytes[1275]; size_t size = 0;
            std::uint64_t activation = 0, sample = 0;
            const auto status = plank_transport_native_microphone_receive(endpoint.value, &activation, &sample, bytes, sizeof(bytes), &size);
            if (status == PLANK_TRANSPORT_TIMEOUT) break;
            require(status == PLANK_TRANSPORT_OK && generation && activation == generation);
            require(plank_probe_audio_consume(decoder, sample, bytes, size));
        }
    }
    void finish() {
        const bool decoded = plank_probe_audio_finish(decoder);
        require(activations == 2 && mutes == 1 && decoded);
        std::puts("physical_audio_receive=pass activations=2 mute=pass native_mac_decoder=1");
    }
#endif
};
static unsigned receive(Endpoint& endpoint, Audio& audio)
{
    audio.drain();
    std::uint8_t bytes[20] {}; size_t size = 0;
    const auto status = plank_transport_native_data_receive(endpoint.value, bytes, sizeof(bytes), &size, 0);
    if (status == PLANK_TRANSPORT_TIMEOUT) return 0;
    require(status == PLANK_TRANSPORT_OK);
    if (size == 1) { require(bytes[0] >= Start && bytes[0] <= Ack); return bytes[0]; }
    PlankTransportControlPacket packet {};
    require(!plank_transport_control_decode(bytes, size, &packet));
    audio.control(packet); return 0;
}
static void digest(const char* side, std::uint64_t index, const std::uint8_t* bytes, size_t size)
{
    unsigned char hash[32];
#ifdef __linux__
    require(SHA256(bytes, size, hash) != nullptr);
#else
    require(CC_SHA256(bytes, CC_LONG(size), hash) != nullptr);
#endif
    std::printf("camera_%s sequence=%llu bytes=%zu sha256=", side, (unsigned long long)index, size);
    for (const auto byte : hash) std::printf("%02x", byte);
    std::putchar('\n');
}

int main(int argc, char** argv)
{
#ifdef __linux__
    QCoreApplication application(argc, argv);
#endif
    if (argc != 6 || (std::strcmp(argv[1], "server") && std::strcmp(argv[1], "client"))) {
        std::fprintf(stderr, "Usage: native-camera-live server BIND CERT KEY PRIVATE_RECORDS\n"
            "       native-camera-live client REMOTE CERT_SHA256 DEVICE h264|mjpeg\n"); return 2;
    }
    Endpoint endpoint;
    try {
        const bool server = !std::strcmp(argv[1], "server");
#ifdef __linux__
        require(!server);
#else
        require(server);
#endif
        const char* token = std::getenv("PLANK_CAMERA_PROBE_TOKEN");
        require(token && std::strlen(token) == 64);
        PlankTransportConfig config {};
        config.struct_size = sizeof(config); config.abi_version = PLANK_TRANSPORT_ABI_VERSION;
        config.mode = server ? PLANK_TRANSPORT_MODE_SERVER : PLANK_TRANSPORT_MODE_CLIENT;
        config.handshake_timeout_ms = 5000; config.idle_timeout_ms = 10000;
        config.keep_alive_interval_ms = 1000; config.session_token = token;
        if (server) {
            config.bind_address = argv[2]; config.certificate_path = argv[3]; config.private_key_path = argv[4];
        } else {
            config.remote_address = argv[2]; config.server_name = "localhost"; config.certificate_sha256 = argv[3];
        }
        require(plank_transport_native_endpoint_create(&config, &endpoint.value) == PLANK_TRANSPORT_OK);
        require(plank_transport_native_endpoint_start(endpoint.value) == PLANK_TRANSPORT_OK);
        require(plank_transport_native_endpoint_wait_ready(endpoint.value, 7000) == PLANK_TRANSPORT_OK);
        require(plank_transport_native_microphone_enable(endpoint.value) == PLANK_TRANSPORT_OK);
        require(plank_transport_native_camera_enable(endpoint.value, 1) == PLANK_TRANSPORT_OK);
        const auto ready = Clock::now() + std::chrono::seconds(4);
        while ((plank_transport_native_camera_state(endpoint.value) == 1 ||
                plank_transport_native_microphone_state(endpoint.value) == 1) && Clock::now() < ready)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        require(plank_transport_native_camera_state(endpoint.value) == 2);
        require(plank_transport_native_microphone_state(endpoint.value) == 2);
        require(plank_transport_native_camera_activate(endpoint.value, 1) == PLANK_TRANSPORT_OK);
        Audio audio(endpoint);
        const auto end = Clock::now() + std::chrono::seconds(20);
        if (server) {
            const int fd = open(argv[5], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
            require(fd >= 0);
            File file; file.value = fdopen(fd, "wb");
            if (!file.value) { close(fd); require(false); }
            std::vector<std::uint8_t> record(PLANK_CAMERA_HEADER_BYTES + PLANK_CAMERA_MAX_FRAME_BYTES);
            unsigned frames = 0;
            bool done = false;
            auto lastData = Clock::now(), lastKey = Clock::now();
            send(endpoint, Start);
            while (Clock::now() < end) {
                const auto command = receive(endpoint, audio);
                require(!command || command == Done);
                if (command == Done) { done = true; lastData = Clock::now(); }
                size_t size = 0;
                const auto status = plank_transport_native_camera_receive(endpoint.value, record.data(), record.size(), &size);
                require(status == PLANK_TRANSPORT_OK || status == PLANK_TRANSPORT_TIMEOUT);
                if (status == PLANK_TRANSPORT_OK) {
                    PlankCameraHeader header {};
                    require(!plank_camera_header_decode(record.data(), size, &header) && header.generation == 1 && ++frames <= 90);
                    const auto payload = record.data() + PLANK_CAMERA_HEADER_BYTES;
                    const auto length = size - PLANK_CAMERA_HEADER_BYTES;
                    digest("received", header.sequence, payload, length);
                    std::uint8_t prefix[4]; plank_transport_control_write_u32(prefix, std::uint32_t(length));
                    require(fwrite(prefix, 1, 4, file.value) == 4 && fwrite(payload, 1, length, file.value) == length);
                    lastData = Clock::now();
                }
                if (done && Clock::now() - lastData > std::chrono::milliseconds(500)) break;
                if (!done && plank_transport_native_camera_keyframe_needed(endpoint.value) &&
                    Clock::now() - lastKey > std::chrono::milliseconds(500)) {
                    send(endpoint, Key); lastKey = Clock::now();
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            require(done && frames > 60 && !fflush(file.value));
            audio.finish();
            send(endpoint, Ack);
            // Let the reliable acknowledgement leave before cancelling QUIC.
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
            std::printf("camera_network_receive=pass frames=%u\n", frames);
        } else {
#ifdef __linux__
            unsigned command = 0;
            while (!(command = receive(endpoint, audio)) && Clock::now() < end)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            require(command == Start);
            using Camera = PlankLinuxNativeCamera;
            const bool h264 = !std::strcmp(argv[5], "h264");
            require(h264 || !std::strcmp(argv[5], "mjpeg"));
            Camera camera;
            require(camera.open(argv[4], h264 ? Camera::Codec::H264 : Camera::Codec::Mjpeg, 1280, 720));
            unsigned frames = 0, drops = 0, requests = 0;
            const auto format = camera.format();
            auto lastKey = Clock::now() - std::chrono::seconds(1);
            while (frames < 90 && Clock::now() < end) {
                command = receive(endpoint, audio); require(!command || command == Key);
                if (h264 && frames && (command == Key || plank_transport_native_camera_keyframe_needed(endpoint.value)) &&
                    Clock::now() - lastKey > std::chrono::milliseconds(500)) {
                    if (camera.requestKeyframe()) ++requests;
                    lastKey = Clock::now();
                }
                Camera::Frame frame;
                const auto result = camera.read(frame);
                require(result != Camera::Result::Failed);
                if (result != Camera::Result::Frame) continue;
                PlankCameraHeader header {};
                header.generation = 1; header.sequence = frames++; header.capture_time_us = frame.captureTimeUs;
                header.codec = h264 ? PLANK_CAMERA_H264 : PLANK_CAMERA_MJPEG;
                header.width = format.width; header.height = format.height;
                header.colorspace = format.colorspace; header.transfer = format.xfer_func;
                header.ycbcr = format.ycbcr_enc; header.quantization = format.quantization;
                header.driver_sequence = frame.driverSequence;
                header.flags = (frame.independent ? PLANK_CAMERA_KEY_FRAME : 0) |
                    (frame.discontinuity ? PLANK_CAMERA_DISCONTINUITY : 0);
                std::vector<std::uint8_t> record(PLANK_CAMERA_HEADER_BYTES + frame.bytes.size());
                require(!plank_camera_header_encode(&header, frame.bytes.size(), record.data(), record.size()));
                std::memcpy(record.data() + PLANK_CAMERA_HEADER_BYTES, frame.bytes.data(), frame.bytes.size());
                digest("sent", header.sequence, frame.bytes.data(), frame.bytes.size());
                const auto status = plank_transport_native_camera_send(endpoint.value, record.data(), record.size());
                require(status == PLANK_TRANSPORT_OK || status == PLANK_TRANSPORT_DROPPED);
                drops += status == PLANK_TRANSPORT_DROPPED;
                audio.step(frames);
            }
            require(camera.close() && frames == 90);
            audio.finish();
            send(endpoint, Done);
            bool acknowledged = false;
            while (!acknowledged && Clock::now() < end) {
                command = receive(endpoint, audio); require(!command || command == Key || command == Ack);
                acknowledged = command == Ack;
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            require(acknowledged);
            std::printf("camera_network_send=pass frames=%u source_drops=%u key_requests=%u\n", frames, drops, requests);
#else
            require(false);
#endif
        }
        require(plank_transport_native_camera_activate(endpoint.value, 0) == PLANK_TRANSPORT_OK);
        return 0;
    } catch (const std::exception& error) {
        char detail[512] = {};
        if (endpoint.value) plank_transport_native_endpoint_last_error(endpoint.value, detail, sizeof(detail));
        std::fprintf(stderr, "%s transport=%s\n", error.what(), detail);
        return 1;
    }
}
