/* SPDX-License-Identifier: AGPL-3.0-or-later */
#include "plank_transport_camera_encoded.h"
#include <assert.h>
#include <stdio.h>
int main(int argc, char **argv) {
    assert(argc == 2);
    FILE *file = fopen(argv[1], "r"); assert(file);
    uint8_t expected[70], encoded[70]; unsigned value;
    for (unsigned i=0; i<sizeof(expected); ++i) {
        assert(fscanf(file, "%2x", &value) == 1 && value <= 255); expected[i] = (uint8_t)value;
    }
    assert(fscanf(file, "%x", &value) == EOF && !ferror(file)); fclose(file);
    PlankEncodedCameraHeader input = { .generation=2, .capture_time_us=1000000, .codec=PLANK_CAMERA_H264,
        .width=1280, .height=720, .flags=PLANK_CAMERA_KEY_FRAME, .platform=PLANK_CAMERA_MACOS,
        .encoder=PLANK_CAMERA_VIDEOTOOLBOX_HARDWARE, .source_pixel_format=PLANK_CAMERA_NV12,
        .primaries=PLANK_CAMERA_BT709, .transfer=PLANK_CAMERA_BT709, .matrix=PLANK_CAMERA_BT709,
        .range=PLANK_CAMERA_LIMITED_RANGE, .nominal_fps=30 };
    assert(!plank_encoded_camera_header_encode(&input, 6, encoded, sizeof(encoded)));
    memcpy(encoded+64, expected+64, 6); assert(!memcmp(encoded, expected, sizeof(encoded)));
    PlankEncodedCameraHeader decoded;
    assert(!plank_encoded_camera_header_decode(expected, sizeof(expected), &decoded));
    assert(decoded.generation==2 && decoded.sequence==0 && decoded.encoder==PLANK_CAMERA_VIDEOTOOLBOX_HARDWARE && decoded.nominal_fps==30);
    PlankCameraHeader native;
    assert(plank_camera_header_decode(expected, sizeof(expected), &native)==-1);
    for (size_t n=0; n<=PLANK_CAMERA_HEADER_BYTES; ++n) {
        assert(plank_encoded_camera_header_decode(expected, n, &decoded)==-1 && !decoded.generation);
    }
    const unsigned offsets[]={0,4,5,6,7,32,36,38,40,44,48,52,53,54,55,56,57,58,59,60,63};
    for (unsigned i=0; i<sizeof(offsets)/sizeof(offsets[0]); ++i) {
        memcpy(encoded,expected,sizeof(encoded)); encoded[offsets[i]]^=0x80;
        assert(plank_encoded_camera_header_decode(encoded,sizeof(encoded),&decoded)==-1);
    }
    assert(plank_encoded_camera_header_encode(&input,0,encoded,sizeof(encoded))==-1);
    assert(plank_encoded_camera_header_encode(&input,PLANK_CAMERA_MAX_FRAME_BYTES+1,encoded,sizeof(encoded))==-1);
    assert(plank_encoded_camera_header_encode(&input,6,encoded,63)==-1);
    input.generation=0; assert(plank_encoded_camera_header_encode(&input,6,encoded,sizeof(encoded))==-1);
    puts("encoded_camera_client_host_vector_and_v1_isolation=pass");
}
