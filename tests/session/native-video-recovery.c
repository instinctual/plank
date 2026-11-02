// Exercise the production assembler with synthetic Annex-B framing, no decoder,
// display, network or input devices. Keep recovery requests observable.
#include "Limelight-internal.h"
#include <stdio.h>
static unsigned liveBuffers, allocations;
static void* countedAllocate(size_t size) {
    void* p = malloc(size);
    if (p) { liveBuffers++; allocations++; }
    return p;
}
static void countedFree(void* p) { if (p) { liveBuffers--; free(p); } }
#define malloc countedAllocate
#define free countedFree
#include "VideoFrameAssembler.c"
#undef malloc
#undef free

#define CHECK(x) do { checks++; if (!(x)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static unsigned checks, requests, delivered, keys;
static int decoderResult;
int NegotiatedVideoFormat;
STREAM_CONFIGURATION StreamConfig;
DECODER_RENDERER_CALLBACKS VideoCallbacks;
CONNECTION_LISTENER_CALLBACKS ListenerCallbacks;

static void quietLog(const char* format, ...) { (void)format; }
void LiRequestIdrFrame(void) { requests++; }
void connectionDetectedFrameLoss(uint32_t start, uint32_t end) {
    CHECK(start <= end);
    LiRequestIdrFrame(); // real non-RFI ControlStream behavior
}
void connectionReceivedCompleteFrame(uint32_t frame, bool ltr) { (void)frame; (void)ltr; }
void notifyKeyFrameReceived(void) { keys++; }
bool LiGetCurrentHostDisplayHdrMode(void) { return false; }
static int submit(PDECODE_UNIT unit) {
    CHECK(unit->fullLength > 0);
    CHECK(LiVideoFrameData(unit) == LiVideoBufferData(unit->frameBuffer));
    for (int i = 0; i < PLANK_VIDEO_BUFFER_PADDING; ++i)
        CHECK(LiVideoFrameData(unit)[unit->fullLength + i] == 0);
    delivered++;
    return decoderResult;
}

static const unsigned char h264[] = {
    0,0,0,1,0x67,0xab, 0,0,0,1,0x68,0xab, 0,0,0,1,0x65,0xab
};
static const unsigned char hevc[] = {
    0,0,0,1,0x40,1,0xab, 0,0,0,1,0x42,1,0xab,
    0,0,0,1,0x44,1,0xab, 0,0,0,1,0x26,1,0xab
};
static const unsigned char delta[] = {0,0,0,1,0x02,1,0xab};

static int frame(const unsigned char* data, size_t length, uint32_t number, bool key) {
    PLANK_VIDEO_BUFFER* buffer = LiAllocateVideoBuffer((int)length);
    CHECK(buffer != NULL);
    memcpy(LiVideoBufferData(buffer), data, length);
    int result = LiSubmitPlankVideoFrame(buffer, (int)length, number,
        key ? PLANK_VIDEO_FRAME_FLAG_KEY : 0, number * 1500, 1);
    LiReleaseVideoBuffer(buffer);
    return result;
}

static void exercise(int codec, const unsigned char* key, size_t size, size_t configSize) {
    NegotiatedVideoFormat = codec;
    requests = delivered = keys = 0;
    decoderResult = DR_OK;
    initializeVideoFrameAssembler();
    CHECK(frame(key, size, 1, true) == 0);
    CHECK(delivered == 1 && requests == 0);
    CHECK(frame(delta, sizeof(delta), 2, false) == 0);
    CHECK(delivered == 2);

    // Sender omitted encoded frames awaiting recovery, or transport lost them.
    // The arriving keyframe itself repairs the reference chain.
    CHECK(frame(key, size, 10, true) == 0);
    CHECK(requests == 0 && delivered == 3);
    CHECK(frame(delta, sizeof(delta), 11, false) == 0);
    CHECK(delivered == 4);
    CHECK(frame(key, size, 10, true) == 1); // duplicate/late frame
    CHECK(requests == 0 && delivered == 4);

    // A missing reference followed by a delta still needs recovery.
    CHECK(frame(delta, sizeof(delta), 15, false) == 1);
    CHECK(requests == 1 && delivered == 4);
    CHECK(frame(delta, sizeof(delta), 16, false) == 1);
    CHECK(frame(key, size, 20, true) == 0);
    CHECK(requests == 1 && delivered == 5);
    CHECK(frame(delta, sizeof(delta), 21, false) == 0);

    // A key flag without an actual random-access picture is not recovery.
    CHECK(frame(key, configSize, 25, true) == -1);
    CHECK(delivered == 6);
    CHECK(frame(delta, sizeof(delta), 26, false) == 1);
    CHECK(frame(key, size, 30, true) == 0);
    CHECK(frame(delta, sizeof(delta), 31, false) == 0);

    // Decoder-requested recovery retains its existing authority.
    decoderResult = DR_NEED_IDR;
    unsigned before = requests;
    CHECK(frame(delta, sizeof(delta), 32, false) == 0);
    CHECK(requests == before + 1);
    decoderResult = DR_OK;
    CHECK(frame(delta, sizeof(delta), 33, false) == 1);
    CHECK(frame(key, size, 40, true) == 0);
    CHECK(requests == before + 1);
    CHECK(frame(delta, sizeof(delta), 41, false) == 0);
    const unsigned char garbage[] = {0xff, 0xff, 0xff, 0xff, 0xff};
    CHECK(frame(garbage, sizeof(garbage), 42, true) == -1);
    CHECK(frame(delta, sizeof(delta), 43, false) == 1);
    CHECK(frame(key, size, 50, true) == 0);
    // A picture without its required parameter sets is not a complete keyframe.
    CHECK(frame(key + configSize, size - configSize, 51, true) == -1);
    CHECK(frame(delta, sizeof(delta), 52, false) == 1);
    CHECK(frame(key, size, 60, true) == 0);
    stopVideoFrameAssembler();
    destroyVideoFrameAssembler();
}

static void ownership(void) {
    NegotiatedVideoFormat = VIDEO_FORMAT_H264_HIGH10_444;
    VideoCallbacks.capabilities = CAPABILITY_PULL_RENDERER;
    initializeVideoFrameAssembler();
    CHECK(!LiAllocateVideoBuffer(0));
    CHECK(!LiAllocateVideoBuffer(PLANK_VIDEO_BUFFER_LIMIT + 1));
    unsigned before = allocations;
    CHECK(frame(h264, sizeof(h264), 1, true) == 0);
    CHECK(allocations == before + 1); // Payload, NAL views and queue record.
    VIDEO_FRAME_HANDLE handle;
    PDECODE_UNIT unit;
    CHECK(LiPollNextVideoFrame(&handle, &unit));
    PLANK_VIDEO_BUFFER* retained = unit->frameBuffer;
    LiRetainVideoBuffer(retained); // Models a decoder retaining its AVBufferRef.
    const unsigned char* bytes = LiVideoFrameData(unit);
    CHECK(bytes == retained->data);
    LiCompleteVideoFrame(handle, DR_OK);
    CHECK(liveBuffers == 1 && !memcmp(bytes, h264, sizeof(h264)));
    LiReleaseVideoBuffer(retained);
    CHECK(liveBuffers == 0);
    // A large delta still has one allocation and no NAL/reassembly payload copy.
    const int largeSize = 4 * 1024 * 1024;
    PLANK_VIDEO_BUFFER* large = LiAllocateVideoBuffer(largeSize);
    memset(large->data, 0xab, largeSize);
    memcpy(large->data, delta, sizeof(delta));
    CHECK(LiSubmitPlankVideoFrame(large, largeSize, 2, 0, 3000, 27) == 0);
    CHECK(LiSubmitPlankVideoFrame(large, largeSize, 3, 0, 4500, 27) == -1);
    LiReleaseVideoBuffer(large);
    CHECK(LiPollNextVideoFrame(&handle, &unit));
    CHECK(LiVideoFrameData(unit) == large->data);
    CHECK(unit->fullLength == largeSize && unit->presentationTimeUs == 33333);
    CHECK(unit->frameHostProcessingLatency == 27);
    LiCompleteVideoFrame(handle, DR_OK);
    // Queue overflow retires every unconsumed owner and requests recovery.
    for (unsigned n = 3; n < 19; ++n) CHECK(frame(delta, sizeof(delta), n, false) == 0);
    CHECK(liveBuffers == 0 && LiGetPendingVideoFrames() == 0);
    CHECK(frame(h264, sizeof(h264), 20, true) == 0);
    stopVideoFrameAssembler();
    CHECK(frame(h264, sizeof(h264), 21, true) == 0);
    destroyVideoFrameAssembler();
    CHECK(liveBuffers == 0);
    printf("encoded frame: one allocation, zero NAL/reassembly copies for a %d-byte delta\n", largeSize);
}

static void nalViews(int codec, const unsigned char* key, size_t size, size_t firstNalSize) {
    NegotiatedVideoFormat = codec;
    VideoCallbacks.capabilities = CAPABILITY_PULL_RENDERER;
    initializeVideoFrameAssembler();
    unsigned char input[64];
    const bool hevcCodec = (codec & VIDEO_FORMAT_MASK_H265) != 0;
    const unsigned char aud[] = {0, 0, 0, 1, hevcCodec ? 0x46 : 0x09, 1, 0xab};
    const unsigned char sei[] = {0, 0, 0, 1, hevcCodec ? 0x4e : 0x06, 1, 0xab};
    memcpy(input, aud, sizeof(aud));
    memcpy(input + sizeof(aud), key, size);
    CHECK(frame(input, sizeof(aud) + size, 1, true) == 0);
    VIDEO_FRAME_HANDLE handle;
    PDECODE_UNIT unit;
    CHECK(LiPollNextVideoFrame(&handle, &unit));
    // Skipping a leading AUD still permits zero-copy decoding with an offset.
    CHECK(LiVideoFrameData(unit) == LiVideoBufferData(unit->frameBuffer) + sizeof(aud));
    CHECK(unit->fullLength == (int)size && !memcmp(LiVideoFrameData(unit), key, size));
    for (int i = 0; i < PLANK_VIDEO_BUFFER_PADDING; ++i)
        CHECK(LiVideoFrameData(unit)[size + i] == 0);
    LiCompleteVideoFrame(handle, DR_OK);

    memcpy(input, key, firstNalSize);
    memcpy(input + firstNalSize, sei, sizeof(sei));
    memcpy(input + firstNalSize + sizeof(sei), key + firstNalSize, size - firstNalSize);
    CHECK(frame(input, size + sizeof(sei), 2, true) == 0);
    CHECK(LiPollNextVideoFrame(&handle, &unit));
    // An omitted SEI between parameter sets requires the explicit copy path.
    CHECK(!LiVideoFrameData(unit));
    unsigned char assembled[64];
    size_t offset = 0;
    for (PLENTRY entry = unit->bufferList; entry; entry = entry->next) {
        CHECK(entry->length > 0 && offset + entry->length <= size);
        memcpy(assembled + offset, entry->data, entry->length);
        offset += entry->length;
    }
    CHECK(offset == size && unit->fullLength == (int)size && !memcmp(assembled, key, size));
    LiCompleteVideoFrame(handle, DR_OK);
    stopVideoFrameAssembler();
    destroyVideoFrameAssembler();
    CHECK(liveBuffers == 0);
}

int main(void) {
    ListenerCallbacks.logMessage = quietLog;
    VideoCallbacks.capabilities = CAPABILITY_DIRECT_SUBMIT;
    VideoCallbacks.submitDecodeUnit = submit;
    exercise(VIDEO_FORMAT_H264, h264, sizeof(h264), 12);
    exercise(VIDEO_FORMAT_H265_MAIN10, hevc, sizeof(hevc), 21);
    ownership();
    nalViews(VIDEO_FORMAT_H264, h264, sizeof(h264), 6);
    nalViews(VIDEO_FORMAT_H265_MAIN10, hevc, sizeof(hevc), 7);
    CHECK(liveBuffers == 0);
    printf("native video recovery: %u checks passed\n", checks);
    return 0;
}
