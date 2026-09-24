// SPDX-License-Identifier: AGPL-3.0-or-later
#include "plank_transport_camera.h"
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

int main(void) {
    const uint8_t vector[] = {0x50,0x4c,0x44,0x31,0,10,0,12, 1,2,3,4,5,6,7,8, 0,0,0,1};
    uint8_t bytes[20]; size_t size = 0; PlankTransportControlPacket packet;
    uint64_t generation = 0; uint32_t value = 0;
    uint32_t words[] = {0x01020304, 0x05060708, 1};
    assert(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_SET_CAMERA, words, 3, bytes, sizeof(bytes), &size));
    assert(size == sizeof(vector) && !memcmp(bytes, vector, size));
    for (unsigned type = 10; type <= 12; type++) {
        for (unsigned state = 0; state < 5; state++) {
            words[2] = state;
            assert(!plank_transport_control_encode(type, words, type == 12 ? 2 : 3, bytes, sizeof(bytes), &size));
            assert(!plank_transport_control_decode(bytes, size, &packet));
            bool valid = type == 12 || (type == 10 ? state <= 1 : state <= 3);
            assert((plank_camera_control_decode(&packet, &generation, &value) == 0) == valid);
            if (valid) assert(generation == UINT64_C(0x0102030405060708) && value == (type == 12 ? 0 : state));
            packet.payload_size--;
            assert(plank_camera_control_decode(&packet, &generation, &value));
        }
    }
    for (unsigned invalid = 0; invalid < 2; invalid++) {
        words[0] = words[1] = invalid ? UINT32_MAX : 0; words[2] = 0;
        assert(!plank_transport_control_encode(10, words, 3, bytes, sizeof(bytes), &size));
        assert(!plank_transport_control_decode(bytes, size, &packet));
        assert(plank_camera_control_decode(&packet, &generation, &value));
    }
    puts("camera control: shared vector, directions, lengths, flags and generations passed");
}
