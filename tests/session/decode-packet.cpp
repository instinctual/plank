// Exercise the production packet builder with intact Host parameter sets.
#include "video/decodepacket.h"
#include "video/ffmpeg-testframes.h"
#include <cassert>
#include <iostream>
extern "C" {
#include <libavutil/pixdesc.h>
}

// This fixture isolates the encoded-buffer owner. The common-C suite exercises
// the real assembler/queue owner; FFmpeg here is the pinned product library.
struct _PLANK_VIDEO_BUFFER {
    unsigned references = 1;
    std::vector<uint8_t> bytes;
};
extern "C" void LiRetainVideoBuffer(PLANK_VIDEO_BUFFER* buffer) { ++buffer->references; }
extern "C" void LiReleaseVideoBuffer(PLANK_VIDEO_BUFFER* buffer) {
    assert(buffer->references > 0);
    --buffer->references;
}
extern "C" const unsigned char* LiVideoFrameData(const DECODE_UNIT* unit) {
    return unit->frameBuffer ? unit->frameBuffer->bytes.data() : nullptr;
}

static void checkFrame(const uint8_t* bytes, int size, AVPixelFormat format)
{
    const auto* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    assert(codec);
    auto* context = avcodec_alloc_context3(codec);
    assert(context);
    context->flags |= AV_CODEC_FLAG_LOW_DELAY;
    context->err_recognition = AV_EF_EXPLODE;
    context->thread_count = 2;
    context->thread_type = FF_THREAD_SLICE;
    assert(avcodec_open2(context, codec, nullptr) == 0);
    auto* packet = av_packet_alloc();
    auto* output = av_frame_alloc();
    assert(packet && output);
    PLANK_VIDEO_BUFFER owner;
    owner.bytes.assign(bytes, bytes + size);
    owner.bytes.resize(size + PLANK_VIDEO_BUFFER_PADDING);
    DECODE_UNIT unit{};
    unit.frameBuffer = &owner;
    unit.frameType = FRAME_TYPE_IDR;
    unit.fullLength = size;
    std::vector<uint8_t> assembly;
    unsigned decodedFrames = 0;
    auto validateFrame = [&] {
        assert(output->width == 1280 && output->height == 720);
        assert(output->pts == decodedFrames);
        auto decodedFormat = static_cast<AVPixelFormat>(output->format);
        // FFmpeg's default format picker still exposes the deprecated full-
        // range YUVJ aliases. They have the same planes/depth; range is explicit.
        if (decodedFormat == AV_PIX_FMT_YUVJ420P || decodedFormat == AV_PIX_FMT_YUVJ422P) {
            assert(output->color_range == AVCOL_RANGE_JPEG);
            decodedFormat = decodedFormat == AV_PIX_FMT_YUVJ420P ? AV_PIX_FMT_YUV420P : AV_PIX_FMT_YUV422P;
        }
        if (decodedFormat != format)
            std::cerr << "Decoded " << av_get_pix_fmt_name(decodedFormat)
                      << "; expected " << av_get_pix_fmt_name(format) << std::endl;
        assert(decodedFormat == format);
        if (format == AV_PIX_FMT_GBRP || format == AV_PIX_FMT_GBRP10LE) {
            assert(output->colorspace == AVCOL_SPC_RGB && output->color_range == AVCOL_RANGE_JPEG);
        } else if (format == AV_PIX_FMT_YUV422P || format == AV_PIX_FMT_YUV422P10LE) {
            assert(output->colorspace == AVCOL_SPC_BT709 && output->color_range == AVCOL_RANGE_JPEG);
        }
        av_frame_unref(output);
        ++decodedFrames;
    };
    // Even with low-delay requested, a valid SPS may advertise reorder depth.
    // Exercise the send/drain contract and require every submitted IDR back;
    // neither packet ownership nor SPS integrity depends on immediate output.
    for (int frame = 0; frame < 6; ++frame) {
        assert(plankSetDecodePacket(packet, &unit, assembly));
        assert(packet->data == owner.bytes.data() && assembly.empty());
        assert(packet->size == size && packet->flags == AV_PKT_FLAG_KEY);
        assert(owner.references >= 2 && memcmp(packet->data, bytes, size) == 0);
        packet->pts = packet->dts = frame;
        assert(avcodec_send_packet(context, packet) == 0);
        av_packet_unref(packet);
        int result;
        while ((result = avcodec_receive_frame(context, output)) == 0) validateFrame();
        assert(result == AVERROR(EAGAIN));
    }
    assert(avcodec_send_packet(context, nullptr) == 0);
    int result;
    while ((result = avcodec_receive_frame(context, output)) == 0) validateFrame();
    assert(result == AVERROR_EOF && decodedFrames == 6);
    avcodec_free_context(&context);
    assert(owner.references == 1);

    // The remaining list API copies unchanged bytes, including every SPS/PPS.
    const int split = size / 2;
    std::vector<char> first(bytes, bytes + split), second(bytes + split, bytes + size);
    LENTRY tail{nullptr, second.data(), size - split, BUFFER_TYPE_PICDATA};
    LENTRY head{&tail, first.data(), split, BUFFER_TYPE_SPS};
    unit.frameBuffer = nullptr;
    unit.bufferList = &head;
    assert(plankSetDecodePacket(packet, &unit, assembly));
    assert(packet->data == assembly.data() && packet->size == size);
    assert(memcmp(packet->data, bytes, size) == 0);
    for (int index = 0; index < AV_INPUT_BUFFER_PADDING_SIZE; ++index)
        assert(packet->data[size + index] == 0);
    unit.frameType = FRAME_TYPE_PFRAME;
    assert(plankSetDecodePacket(packet, &unit, assembly) && packet->flags == 0);
    ++tail.length;
    assert(!plankSetDecodePacket(packet, &unit, assembly));
    tail.length = 0;
    assert(!plankSetDecodePacket(packet, &unit, assembly));
    tail.length = size - split;
    tail.data = nullptr;
    assert(!plankSetDecodePacket(packet, &unit, assembly));
    unit.fullLength = 0;
    assert(!plankSetDecodePacket(packet, &unit, assembly));
    assert(!plankSetDecodePacket(packet, nullptr, assembly));
    av_frame_free(&output);
    av_packet_free(&packet);
}

int main()
{
    using namespace PlankDecoderTestFrames;
    checkFrame(k_H264TestFrame, sizeof(k_H264TestFrame), AV_PIX_FMT_YUV420P);
    checkFrame(k_H264High8_422TestFrame, sizeof(k_H264High8_422TestFrame), AV_PIX_FMT_YUV422P);
    checkFrame(k_H264High10_422TestFrame, sizeof(k_H264High10_422TestFrame), AV_PIX_FMT_YUV422P10LE);
    checkFrame(k_h264High_444TestFrame, sizeof(k_h264High_444TestFrame), AV_PIX_FMT_GBRP);
    checkFrame(k_h264High10_444TestFrame, sizeof(k_h264High10_444TestFrame), AV_PIX_FMT_GBRP10LE);
    std::cout << "decode_packet=pass intact_parameter_sets=pass owned_idr=pass\n";
}
