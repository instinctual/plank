// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic framing only; the Mac fixture separately exercises native decoding.
#include "native-camera-payload.h"
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "camera_payload_failed line=%d\n", __LINE__); exit(1); } } while (0)
static const uint8_t avc[] = {0,0,0,1,0x67,0x42,0x80, 0,0,1,0x68,0x80, 0,0,1,0x65,0x80};
static const uint8_t jpeg[] = {0xff,0xd8, 0xff,0xc0,0,11,8,2,0xd0,5,0,1,1,0x11,0,
    0xff,0xda,0,8,1,1,0,0,63,0, 0x12,0xff,0,0x56,0xff,0xd0,0x34,0xff,0xd9};
int main(void) {
    PlankCameraHeader header = {.generation=1,.capture_time_us=1,.codec=PLANK_CAMERA_H264,
        .width=1280,.height=720,.flags=PLANK_CAMERA_KEY_FRAME};
    PLANKCameraPayload parsed;
    CHECK(PLANKCameraParsePayload(&header, avc, sizeof(avc), &parsed));
    CHECK(parsed.independent && parsed.count == 3 && parsed.nals[2].offset == 15);
    header.flags = 0; CHECK(!PLANKCameraParsePayload(&header, avc, sizeof(avc), &parsed));
    const uint8_t dependent[] = {0,0,1,0x41,0x80};
    CHECK(PLANKCameraParsePayload(&header, dependent, sizeof(dependent), &parsed));
    header.flags = PLANK_CAMERA_KEY_FRAME;
    CHECK(!PLANKCameraParsePayload(&header, dependent, sizeof(dependent), &parsed));
    const uint8_t missingSets[] = {0,0,1,0x65,0x80};
    CHECK(!PLANKCameraParsePayload(&header, missingSets, sizeof(missingSets), &parsed));
    uint8_t bad[1024]; memcpy(bad, avc, sizeof(avc)); bad[4] |= 0x80;
    CHECK(!PLANKCameraParsePayload(&header, bad, sizeof(avc), &parsed));
    for (size_t n = 0; n < sizeof(avc); n++) CHECK(!PLANKCameraParsePayload(&header, avc, n, &parsed));
    memcpy(bad, avc, sizeof(avc)); memcpy(bad+sizeof(avc), dependent, sizeof(dependent));
    CHECK(!PLANKCameraParsePayload(&header, bad, sizeof(avc)+sizeof(dependent), &parsed));
    memcpy(bad, avc, sizeof(avc)); memcpy(bad+sizeof(avc), avc, sizeof(avc));
    CHECK(!PLANKCameraParsePayload(&header, bad, 2*sizeof(avc), &parsed));
    for (unsigned i = 0; i < 65; i++) memcpy(bad+5*i, dependent, 5);
    header.flags = 0; CHECK(!PLANKCameraParsePayload(&header, bad, 65*5, &parsed));
    header.flags = PLANK_CAMERA_KEY_FRAME; header.codec = PLANK_CAMERA_MJPEG;
    CHECK(PLANKCameraParsePayload(&header, jpeg, sizeof(jpeg), &parsed));
    for (size_t n = 0; n < sizeof(jpeg); n++) CHECK(!PLANKCameraParsePayload(&header, jpeg, n, &parsed));
    memcpy(bad, jpeg, sizeof(jpeg)); bad[3] = 0xc2;
    CHECK(!PLANKCameraParsePayload(&header, bad, sizeof(jpeg), &parsed));
    memcpy(bad, jpeg, sizeof(jpeg)); bad[9] = 4;
    CHECK(!PLANKCameraParsePayload(&header, bad, sizeof(jpeg), &parsed));
    memcpy(bad, jpeg, sizeof(jpeg)); bad[20] = 9;
    CHECK(!PLANKCameraParsePayload(&header, bad, sizeof(jpeg), &parsed));
    memcpy(bad, jpeg, sizeof(jpeg)); bad[5] = 255;
    CHECK(!PLANKCameraParsePayload(&header, bad, sizeof(jpeg), &parsed));
    memcpy(bad, jpeg, sizeof(jpeg)); bad[sizeof(jpeg)] = 0;
    CHECK(!PLANKCameraParsePayload(&header, bad, sizeof(jpeg)+1, &parsed));
    CHECK(!PLANKCameraParsePayload(NULL, jpeg, sizeof(jpeg), &parsed));
    CHECK(!PLANKCameraParsePayload(&header, NULL, 1, &parsed));
    CHECK(!PLANKCameraParsePayload(&header, jpeg, PLANK_CAMERA_MAX_FRAME_BYTES+1, &parsed));
    // Deterministic malformed lengths/markers exercise both parsers under ASan.
    uint32_t random = 0x4056;
    for (unsigned iteration = 0; iteration < 10000; iteration++) {
        for (size_t i = 0; i < sizeof(bad); i++) { random = random * 1664525u + 1013904223u; bad[i] = random >> 24; }
        size_t size = random % sizeof(bad);
        header.codec = iteration & 1 ? PLANK_CAMERA_H264 : PLANK_CAMERA_MJPEG;
        if (PLANKCameraParsePayload(&header, bad, size, &parsed)) {
            for (unsigned i = 0; i < parsed.count; i++)
                CHECK(parsed.nals[i].offset < size && parsed.nals[i].size <= size - parsed.nals[i].offset);
        }
    }
    puts("native_camera_payload=pass bounds=pass dimensions=pass malformed=pass");
    return 0;
}
