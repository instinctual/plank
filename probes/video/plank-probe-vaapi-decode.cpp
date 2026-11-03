// Isolate the shipped FFmpeg/VA-API decoder from Qt, networking and presentation.
// Input is a bounded, locally supplied HEVC Annex B clip with access-unit delimiters.
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include <unistd.h>
#include "vaapi-sampling.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/pixdesc.h>
#include <va/va_drmcommon.h>
}

namespace {
using Clock = std::chrono::steady_clock;
using Unit = std::pair<size_t, size_t>;
constexpr size_t MaxClip = 256U * 1024U * 1024U;
constexpr uint64_t MaxRecording = 4ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr uint32_t MaxPacket = 16U * 1024U * 1024U;
constexpr size_t MaxUnits = 1000000;

void require(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}

void checked(int status, const char* operation)
{
    if (status >= 0) return;
    char message[AV_ERROR_MAX_STRING_SIZE] {};
    av_strerror(status, message, sizeof(message));
    throw std::runtime_error(std::string(operation) + ": " + message);
}

std::vector<Unit> accessUnits(const std::vector<uint8_t>& bytes)
{
    std::vector<size_t> starts;
    for (size_t i = 0; i + 4 < bytes.size();) {
        size_t prefix = 0;
        if (bytes[i] == 0 && bytes[i + 1] == 0) {
            if (bytes[i + 2] == 1) prefix = 3;
            else if (bytes[i + 2] == 0 && bytes[i + 3] == 1) prefix = 4;
        }
        if (prefix && i + prefix + 1 < bytes.size()) {
            if (((bytes[i + prefix] >> 1) & 63) == 35) {
                require(starts.size() < MaxUnits, "Too many access units");
                starts.push_back(i);
            }
            i += prefix + 2;
        } else ++i;
    }
    require(!starts.empty(), "Clip requires HEVC access-unit delimiters (AUD)");
    starts.front() = 0; // Include any leading parameter sets in the first packet.
    starts.push_back(bytes.size());
    std::vector<Unit> units;
    for (size_t i = 1; i < starts.size(); ++i)
        units.emplace_back(starts[i - 1], starts[i] - starts[i - 1]);
    return units;
}

uint32_t littleEndian(const uint8_t* data)
{
    return uint32_t(data[0]) | (uint32_t(data[1]) << 8) |
           (uint32_t(data[2]) << 16) | (uint32_t(data[3]) << 24);
}

class Clip {
public:
    explicit Clip(const std::string& path) : file(path, std::ios::binary | std::ios::ate)
    {
        require(bool(file), "Could not open private clip");
        const auto size = file.tellg();
        require(size >= 8 && uint64_t(size) <= MaxRecording, "Clip has an invalid size");
        file.seekg(0);
        char magic[8];
        require(bool(file.read(magic, sizeof(magic))), "Could not read clip header");
        recording = std::memcmp(magic, "PLANKV1\n", sizeof(magic)) == 0;
        if (!recording) {
            require(uint64_t(size) <= MaxClip, "Annex B control exceeds 256 MiB");
            bytes.resize(size_t(size));
            file.seekg(0);
            require(bool(file.read(reinterpret_cast<char*>(bytes.data()), size)), "Could not read control clip");
            units = accessUnits(bytes);
            flags.resize(units.size(), 0);
            return;
        }
        // Only index headers. The full recording never enters process memory.
        uint64_t offset = 8;
        while (offset < uint64_t(size)) {
            require(uint64_t(size) - offset >= 8, "Truncated recording header");
            uint8_t header[8];
            require(bool(file.read(reinterpret_cast<char*>(header), sizeof(header))), "Could not read packet header");
            const uint32_t length = littleEndian(header);
            offset += sizeof(header);
            require(length > 0 && length <= MaxPacket && uint64_t(size) - offset >= length,
                    "Invalid or truncated recorded packet");
            require(units.size() < MaxUnits, "Too many recorded packets");
            units.emplace_back(size_t(offset), length);
            flags.push_back(littleEndian(header + 4));
            offset += length;
            file.seekg(std::streamoff(offset));
            require(bool(file), "Could not index recorded packet");
        }
        require(!units.empty(), "Recording has no packets");
    }

    size_t count() const { return units.size(); }
    bool isRecording() const { return recording; }
    void packet(size_t index, AVPacket* packet)
    {
        index %= units.size();
        const auto unit = units[index];
        checked(av_new_packet(packet, int(unit.second)), "Packet allocation");
        packet->flags = int(flags[index]);
        if (recording) {
            file.seekg(std::streamoff(unit.first));
            require(bool(file.read(reinterpret_cast<char*>(packet->data), std::streamsize(unit.second))),
                    "Could not read recorded packet");
        } else std::memcpy(packet->data, bytes.data() + unit.first, unit.second);
    }
private:
    std::ifstream file;
    bool recording = false;
    std::vector<uint8_t> bytes;
    std::vector<Unit> units;
    std::vector<uint32_t> flags;
};

void selfTest()
{
    // Mixed start-code lengths, leading parameter sets, escaped start-code
    // bytes and a truncated trailing prefix must not split an access unit.
    const std::vector<uint8_t> clip {0,0,1,0x40,1,0,0,0,1,0x46,1,0x20,
        0,0,3,1,0x46,1,0,0,1,0x46,1,0x30,0,0,1};
    const auto units = accessUnits(clip);
    require(units.size() == 2 && units[0] == Unit(0,18) &&
            units[1] == Unit(18,9), "Access-unit splitter regression");
    bool rejected = false;
    try { accessUnits({0,0,1,0x40,1}); }
    catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "Missing AUD was accepted");
    const uint8_t encoded[] = {0x78, 0x56, 0x34, 0x12};
    require(littleEndian(encoded) == 0x12345678, "Recording endianness regression");
    std::cout << "vaapi_probe_parser=pass\n";
}

struct Decoder {
    AVCodecContext* context = nullptr;
    AVFrame* frame = nullptr;
    AVPacket* packet = nullptr;
    ~Decoder() {
        av_packet_free(&packet);
        av_frame_free(&frame);
        avcodec_free_context(&context);
    }
};

struct Export {
    AVFrame* lease = nullptr;
    VADRMPRIMESurfaceDescriptor descriptor {};
    bool valid = false;
    ~Export() {
        if (valid) {
            for (unsigned i = 0; i < std::min(descriptor.num_objects, 4U); ++i)
                if (descriptor.objects[i].fd >= 0) close(descriptor.objects[i].fd);
        }
        av_frame_free(&lease);
    }
};

int number(const char* text, int maximum)
{
    size_t used = 0;
    const int value = std::stoi(text, &used);
    require(used == std::strlen(text) && value > 0 && value <= maximum,
            "Invalid numeric argument");
    return value;
}
}

int main(int argc, char** argv)
try {
    if (argc == 2 && std::string(argv[1]) == "--self-test") {
        selfTest();
        return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--version") {
        std::cout << "ffmpeg=" << av_version_info() << " avcodec=" << avcodec_version()
                  << " avutil=" << avutil_version() << '\n';
        return 0;
    }
    if (argc == 3 && std::string(argv[1]) == "--inspect") {
        const Clip clip(argv[2]);
        std::cout << "recording=" << clip.isRecording() << " packets=" << clip.count() << '\n';
        return 0;
    }
    std::string input, device = "/dev/dri/renderD128", mode = "decode";
    int seconds = 600, fps = 60, width = 5120, height = 2160;
    for (int i = 1; i < argc; i += 2) {
        require(i + 1 < argc, "Arguments require values");
        const std::string key = argv[i];
        if (key == "--input") input = argv[i + 1];
        else if (key == "--device") device = argv[i + 1];
        else if (key == "--mode") mode = argv[i + 1];
        else if (key == "--seconds") seconds = number(argv[i + 1], 3600);
        else if (key == "--fps") fps = number(argv[i + 1], 240);
        else if (key == "--width") width = number(argv[i + 1], 16384);
        else if (key == "--height") height = number(argv[i + 1], 16384);
        else throw std::runtime_error("Unknown argument");
    }
    require(!input.empty() && (mode == "decode" || mode == "export" || mode == "sample"),
            "Use --input FILE [--mode decode|export|sample] [--seconds N] [--fps N] [--width N] [--height N] [--device PATH]");
    Clip clip(input);
    Decoder decoder;
    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    require(codec != nullptr, "HEVC decoder unavailable");
    decoder.context = avcodec_alloc_context3(codec);
    decoder.frame = av_frame_alloc();
    decoder.packet = av_packet_alloc();
    require(decoder.context && decoder.frame && decoder.packet, "Could not allocate decoder");
    auto* context = decoder.context;
    // Match the Client's hardware decoder policy; never fall back to software.
    context->thread_count = 1;
    context->extra_hw_frames = 8;
    context->width = width;
    context->height = height;
    context->pix_fmt = AV_PIX_FMT_VAAPI;
    context->flags |= AV_CODEC_FLAG_LOW_DELAY | AV_CODEC_FLAG_OUTPUT_CORRUPT;
    context->flags2 |= AV_CODEC_FLAG2_SHOW_ALL;
    context->err_recognition = AV_EF_EXPLODE;
    context->get_format = [](AVCodecContext*, const AVPixelFormat* formats) {
        for (; *formats != AV_PIX_FMT_NONE; ++formats)
            if (*formats == AV_PIX_FMT_VAAPI) return *formats;
        return AV_PIX_FMT_NONE;
    };
    checked(av_hwdevice_ctx_create(&context->hw_device_ctx, AV_HWDEVICE_TYPE_VAAPI,
                                  device.c_str(), nullptr, 0), "VA-API device");
    checked(avcodec_open2(context, codec, nullptr), "Decoder open");
    std::deque<std::unique_ptr<Export>> exports;
    std::unique_ptr<VaapiSampling> sampling;
    if (mode == "sample") {
        sampling = std::make_unique<VaapiSampling>();
        sampling->initialize(device, width, height);
    }
    const auto started = Clock::now();
    uint64_t decoded = 0;
    double maxSyncMs = 0;
    auto nextReport = started + std::chrono::seconds(15);
    std::cout << "start mode=" << mode << " ffmpeg=" << av_version_info()
              << " units=" << clip.count() << " frames=" << seconds * fps
              << " recording=" << clip.isRecording()
              << " qt=false presentation=false sync_timeout_ms=100" << std::endl;
    const auto receive = [&] {
        while (true) {
            const int status = avcodec_receive_frame(context, decoder.frame);
            if (status == AVERROR(EAGAIN) || status == AVERROR_EOF) return;
            checked(status, "Receive frame");
            const auto* frame = decoder.frame;
            require(frame->format == AV_PIX_FMT_VAAPI && frame->hw_frames_ctx &&
                    frame->width == width && frame->height == height &&
                    frame->colorspace == AVCOL_SPC_RGB && frame->color_range == AVCOL_RANGE_JPEG,
                    "Decoded frame changed requested format, dimensions or identity mapping");
            const auto* frames = reinterpret_cast<AVHWFramesContext*>(frame->hw_frames_ctx->data);
            require(frames->sw_format == AV_PIX_FMT_XV30LE && frames->device_ctx && frames->device_ctx->hwctx,
                    "Expected packed 10-bit 4:4:4 Y410 storage");
            const auto* va = reinterpret_cast<AVVAAPIDeviceContext*>(frames->device_ctx->hwctx);
            const auto surface = VASurfaceID(uintptr_t(frame->data[3]));
            const auto before = Clock::now();
            const VAStatus synced = vaSyncSurface2(va->display, surface, 100000000ULL);
            const double syncMs = std::chrono::duration<double, std::milli>(Clock::now() - before).count();
            maxSyncMs = std::max(maxSyncMs, syncMs);
            if (synced != VA_STATUS_SUCCESS) {
                std::cerr << "surface_error frame=" << decoded << " status=" << synced
                          << " elapsed_ms=" << syncMs << std::endl;
                throw std::runtime_error("VA-API surface synchronization failed");
            }
            if (mode == "export" || sampling) {
                auto item = std::make_unique<Export>();
                item->lease = av_frame_clone(frame);
                require(item->lease, "Could not retain surface");
                const VAStatus exported = vaExportSurfaceHandle(va->display, surface,
                    VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                    VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_COMPOSED_LAYERS, &item->descriptor);
                require(exported == VA_STATUS_SUCCESS, "DMA-BUF export failed");
                item->valid = true;
                require(item->descriptor.fourcc == VA_FOURCC_Y410 && item->descriptor.num_objects <= 4,
                        "Export changed the expected Y410 format");
                if (sampling) sampling->submit(item->descriptor, frame);
                else {
                    exports.push_back(std::move(item));
                    if (exports.size() > 4) exports.pop_front();
                }
            }
            ++decoded;
            av_frame_unref(decoder.frame);
            if (Clock::now() >= nextReport) {
                std::cout << "progress frames=" << decoded << " seconds="
                          << std::chrono::duration<double>(Clock::now() - started).count()
                          << " max_sync_ms=" << maxSyncMs << std::endl;
                nextReport += std::chrono::seconds(15);
            }
        }
    };
    for (int i = 0; i < seconds * fps; ++i) {
        std::this_thread::sleep_until(started + std::chrono::nanoseconds(int64_t(i) * 1000000000 / fps));
        clip.packet(size_t(i), decoder.packet);
        checked(avcodec_send_packet(context, decoder.packet), "Send packet");
        av_packet_unref(decoder.packet);
        receive();
    }
    checked(avcodec_send_packet(context, nullptr), "Flush decoder");
    receive();
    require(decoded == uint64_t(seconds) * fps, "Decoded frame count differs from submitted count");
    exports.clear();
    if (sampling) {
        std::cout << "sampling_result sampled=" << sampling->sampled << " skipped=" << sampling->skipped << std::endl;
        require(sampling->sampled == decoded && sampling->skipped == 0,
                "GPU sampling did not keep up with every decoded frame");
    }
    sampling.reset();
    std::cout << "result=pass mode=" << mode << " frames=" << decoded << " seconds="
              << std::chrono::duration<double>(Clock::now() - started).count()
              << " max_sync_ms=" << maxSyncMs << std::endl;
    return 0;
} catch (const std::exception& error) {
    std::cerr << "result=fail error=" << error.what() << std::endl;
    return 1;
}
