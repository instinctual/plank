/* SPDX-License-Identifier: AGPL-3.0-or-later */
#include "plank_transport_camera.h"
#include <assert.h>
#include <stdio.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    FILE *file = fopen(argv[1], "r"); assert(file);
    uint8_t expected[70], encoded[70]; unsigned value;
    for (unsigned i = 0; i < sizeof(expected); i++) {
        assert(fscanf(file, "%2x", &value) == 1 && value <= 255); expected[i] = (uint8_t)value;
    }
    assert(fscanf(file, "%x", &value) == EOF && !ferror(file)); fclose(file);
    PlankCameraHeader input = { .generation=2, .capture_time_us=1000000, .codec=PLANK_CAMERA_H264,
        .width=1280, .height=720, .colorspace=8, .flags=PLANK_CAMERA_KEY_FRAME };
    assert(!plank_camera_header_encode(&input, 6, encoded, sizeof(encoded)));
    memcpy(encoded+64, expected+64, 6); assert(!memcmp(encoded, expected, sizeof(encoded)));
    PlankCameraHeader decoded;
    assert(!plank_camera_header_decode(expected, sizeof(expected), &decoded));
    assert(decoded.generation == 2 && decoded.sequence == 0 && decoded.capture_time_us == 1000000 &&
        decoded.codec == PLANK_CAMERA_H264 && decoded.width == 1280 && decoded.height == 720 &&
        decoded.flags == PLANK_CAMERA_KEY_FRAME && decoded.colorspace == 8);
    for (size_t size = 0; size <= PLANK_CAMERA_HEADER_BYTES; size++) {
        assert(plank_camera_header_decode(expected, size, &decoded) == -1);
        assert(decoded.generation == 0);
    }
    const unsigned offsets[] = {0, 4, 5, 6, 7, 32, 36, 38, 40, 44, 48, 52, 60};
    for (unsigned i = 0; i < sizeof(offsets)/sizeof(offsets[0]); i++) {
        memcpy(encoded, expected, sizeof(encoded)); encoded[offsets[i]] ^= 0x80;
        assert(plank_camera_header_decode(encoded, sizeof(encoded), &decoded) == -1);
    }
    assert(plank_camera_header_encode(&input, 0, encoded, sizeof(encoded)) == -1);
    assert(plank_camera_header_encode(&input, PLANK_CAMERA_MAX_FRAME_BYTES+1, encoded, sizeof(encoded)) == -1);
    input.codec = PLANK_CAMERA_MJPEG; input.flags = 0;
    assert(plank_camera_header_encode(&input, 6, encoded, sizeof(encoded)) == -1);
    input.flags = PLANK_CAMERA_KEY_FRAME;
    assert(!plank_camera_header_encode(&input, 6, encoded, sizeof(encoded)));
    puts("camera_wire_client_host_vector_bounds=pass");
}
