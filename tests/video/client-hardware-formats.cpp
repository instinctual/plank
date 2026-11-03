// Decode real selected-profile fixtures with the packaged FFmpeg. Observe the
// formats offered before choosing software, so this gate needs no physical GPU.
// Installed hardware decoding/import/color qualification remains mandatory.
#include "video/ffmpeg-testframes.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/pixdesc.h>
}

#include <algorithm>
#include <cstdlib>
#include <iostream>

#if defined(__APPLE__)
constexpr AVPixelFormat hardwareFormat = AV_PIX_FMT_VIDEOTOOLBOX;
#elif defined(__linux__)
constexpr AVPixelFormat hardwareFormat = AV_PIX_FMT_VAAPI;
#else
#error Unsupported Client platform
#endif

static void require(bool condition, const char* message)
{
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(1);
    }
}

struct OfferedFormats {
    AVPixelFormat software;
    bool hardwareSeen = false;
    bool softwareSeen = false;
};

static AVPixelFormat selectSoftware(AVCodecContext* context, const AVPixelFormat* formats)
{
    auto& offered = *static_cast<OfferedFormats*>(context->opaque);
    for (auto* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        offered.hardwareSeen |= *format == hardwareFormat;
        offered.softwareSeen |= *format == offered.software;
    }
    return offered.softwareSeen ? offered.software : AV_PIX_FMT_NONE;
}

template<size_t Size>
static void check(const char* name, const uint8_t (&bytes)[Size], AVPixelFormat software,
                  int depth, bool identity)
{
    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    require(codec, "HEVC decoder unavailable");
    AVCodecContext* context = avcodec_alloc_context3(codec);
    AVPacket* packet = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();
    require(context && packet && frame, "FFmpeg allocation failed");
    OfferedFormats offered {software};
    context->opaque = &offered;
    context->get_format = selectSoftware;
    context->thread_count = 1;
    context->flags |= AV_CODEC_FLAG_LOW_DELAY;
    require(avcodec_open2(context, codec, nullptr) == 0, "HEVC decoder open failed");
    require(av_new_packet(packet, Size) == 0, "Packet allocation failed");
    std::copy(bytes, bytes + Size, packet->data);
    require(avcodec_send_packet(context, packet) == 0, "Fixture submission failed");
    require(avcodec_receive_frame(context, frame) == 0, "Fixture decoding failed");
    std::cout << name << " hardware_offered=" << offered.hardwareSeen
              << " software=" << av_get_pix_fmt_name(software) << std::endl;
    require(offered.hardwareSeen, "Selected HEVC profile was not offered to hardware decoding");
    require(offered.softwareSeen && frame->format == software, "Software fallback changed format");
    const auto* description = av_pix_fmt_desc_get(software);
    require(description && description->comp[0].depth == depth, "Decoded precision changed");
    if (identity) {
        require(frame->colorspace == AVCOL_SPC_RGB && frame->color_range == AVCOL_RANGE_JPEG,
                "Identity fixture lost its RGB mapping or full range");
        require(description->log2_chroma_w == 0 && description->log2_chroma_h == 0,
                "Identity fixture lost 4:4:4 sampling");
    }
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
}

int main()
{
    using namespace PlankDecoderTestFrames;
    check("HEVC Main10", k_HEVCMain10TestFrame, AV_PIX_FMT_YUV420P10, 10, false);
    check("HEVC identity 8-bit", k_HEVCRExt8_444IdentityGbrTestFrame, AV_PIX_FMT_GBRP, 8, true);
    check("HEVC identity 10-bit", k_HEVCRExt10_444IdentityGbrTestFrame, AV_PIX_FMT_GBRP10, 10, true);
    std::cout << "client_hevc_hardware_format_offers=pass\n";
}
