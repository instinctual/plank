#include "video/decodepump.h"
#include <cassert>
#include <algorithm>
#include <cstdint>
#include <deque>
#include <vector>
#include <iostream>

#ifdef PLANK_TEST_REAL_FFMPEG
extern "C" {
#include <libavcodec/avcodec.h>
}
#include "video/ffmpeg-testframes.h"
#endif

int main()
{
    constexpr int again = -11, invalid = -22, corrupt = -33, cancelled = -44;
    std::vector<int> events;
    int sends = 0;
    const int packet = 73;
    const int* retryPacket = nullptr;
    auto send = [&] {
        if (retryPacket) assert(retryPacket == &packet);
        retryPacket = &packet;
        events.push_back(1);
        return ++sends == 1 ? again : 0;
    };
    assert(plankSendAndDrain(again, invalid, send,
        [&] { events.push_back(2); return 1; },
        [&] { events.push_back(3); }) == 0);
    assert((events == std::vector<int>{1, 2, 1, 3, 2}));
    for (int drainResult : {0, corrupt, cancelled}) {
        sends = 0;
        const int result = plankSendAndDrain(again, invalid,
            [&] { sends++; return again; }, [&] { return drainResult; },
            [] { assert(false && "unaccepted packet must not attach metadata"); });
        assert(result == (drainResult == 0 ? invalid : drainResult));
        assert(sends == 1);
    }
    sends = 0;
    assert(plankSendAndDrain(again, invalid, [&] { sends++; return again; },
        [] { return 1; }, [] { assert(false); }) == invalid);
    assert(sends == 2); // A broken codec cannot create an unbounded retry loop.
    bool accepted = false;
    assert(plankSendAndDrain(again, invalid, [] { return corrupt; },
        [] { assert(false); return 0; }, [&] { accepted = true; }) == corrupt);
    assert(!accepted);
    assert(plankSendAndDrain(again, invalid, [] { return 0; },
        [] { return corrupt; }, [&] { accepted = true; }) == corrupt);
    assert(accepted); // A receive error occurs after ownership was accepted.

#ifdef PLANK_TEST_REAL_FFMPEG
    const auto checkCodec = [](AVCodecID id, const uint8_t* bytes, int size) {
        const AVCodec* codec = avcodec_find_decoder(id);
        assert(codec);
        AVCodecContext* context = avcodec_alloc_context3(codec);
        context->thread_count = 2;
        context->thread_type = FF_THREAD_SLICE;
        assert(avcodec_open2(context, codec, nullptr) == 0);
        AVPacket* input = av_packet_alloc();
        AVFrame* output = av_frame_alloc();
        assert(input && output && av_new_packet(input, size) == 0);
        std::copy(bytes, bytes + size, input->data);
        std::deque<int> metadata;
        int received = 0;
        auto drain = [&] {
            int count = 0;
            for (;;) {
                const int result = avcodec_receive_frame(context, output);
                if (result == AVERROR(EAGAIN)) return count;
                if (result < 0) return result;
                assert(!metadata.empty() && metadata.front() == received);
                metadata.pop_front();
                assert(output->width > 0 && output->height > 0);
                received++; count++;
                av_frame_unref(output);
            }
        };
        for (int index = 0; index < 5; index++) {
            assert(plankSendAndDrain(AVERROR(EAGAIN), AVERROR_INVALIDDATA,
                [&] { return avcodec_send_packet(context, input); }, drain,
                [&] { metadata.push_back(index); }) == 0);
        }
        assert(received == 5 && metadata.empty());
        av_frame_free(&output);
        av_packet_free(&input);
        avcodec_free_context(&context);
    };
    using namespace PlankDecoderTestFrames;
    checkCodec(AV_CODEC_ID_H264, k_h264High10_444TestFrame, sizeof(k_h264High10_444TestFrame));
    checkCodec(AV_CODEC_ID_HEVC, k_HEVCRExt10_444IdentityGbrTestFrame, sizeof(k_HEVCRExt10_444IdentityGbrTestFrame));
#endif
    std::cout << "decode_pump=pass retry_ownership=pass no_progress_bound=pass\n";
}
