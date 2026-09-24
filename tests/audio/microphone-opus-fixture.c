// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic Client-codec input for the native Host decoder. No recordings.
#include "../../apps/client/app/streaming/audio/microphoneopus.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed line %d\n", __LINE__); exit(1); } } while (0)
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "wbx"); CHECK(file);
    OpusEncoder *encoder = plankMicrophoneCreateEncoder(); CHECK(encoder);
    opus_int32 value = 0;
    CHECK(!opus_encoder_ctl(encoder, OPUS_GET_BITRATE(&value)) && value == 192000);
    CHECK(!opus_encoder_ctl(encoder, OPUS_GET_VBR(&value)) && value == 1);
    CHECK(!opus_encoder_ctl(encoder, OPUS_GET_VBR_CONSTRAINT(&value)) && value == 1);
    CHECK(!opus_encoder_ctl(encoder, OPUS_GET_APPLICATION(&value)) && value == OPUS_APPLICATION_AUDIO);
    CHECK(!opus_encoder_ctl(encoder, OPUS_GET_FORCE_CHANNELS(&value)) && value == 2);
    unsigned totalBytes = 0, minimum = 1275, maximum = 0;
    for (unsigned n = 0; n < 300; n++) {
        float samples[960]; uint8_t bytes[1275];
        for (unsigned i = 0; i < 480; i++) {
            samples[2*i] = .0625f * sin((n*480 + i) * 6.283185307179586 * 1000 / 48000);
            samples[2*i+1] = .03125f * sin((n*480 + i) * 6.283185307179586 * 1500 / 48000);
        }
        int size = opus_encode_float(encoder, samples, 480, bytes, sizeof(bytes)); CHECK(size > 0);
        CHECK(opus_packet_get_nb_channels(bytes) == 2 && opus_packet_get_nb_samples(bytes, size, 48000) == 480);
        totalBytes += (unsigned)size;
        if ((unsigned)size < minimum) minimum = (unsigned)size;
        if ((unsigned)size > maximum) maximum = (unsigned)size;
        uint8_t length[] = {size >> 8, size};
        CHECK(fwrite(length, 1, 2, file) == 2 && fwrite(bytes, 1, size, file) == (size_t)size);
    }
    opus_encoder_destroy(encoder); CHECK(!fclose(file));
    printf("microphone_opus_fixture=pass packets=300 channels=2 frames=480 target_bps=192000 constrained_vbr=1 payload_bps=%.0f minimum_bytes=%u maximum_bytes=%u\n",
        totalBytes*8.0/3, minimum, maximum);
}
