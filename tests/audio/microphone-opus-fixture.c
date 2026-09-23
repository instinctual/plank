// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic Client-codec input for the native Host decoder. No recordings.
#include <opus/opus.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed line %d\n", __LINE__); exit(1); } } while (0)
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "wbx"); CHECK(file);
    int error = 0;
    OpusEncoder *encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &error); CHECK(encoder && !error);
    CHECK(!opus_encoder_ctl(encoder, OPUS_SET_BITRATE(64000)));
    for (unsigned n = 0; n < 300; n++) {
        float samples[480]; uint8_t bytes[1275];
        for (unsigned i = 0; i < 480; i++) samples[i] = .0625f * sin((n*480 + i) * 6.283185307179586 * 1000 / 48000);
        int size = opus_encode_float(encoder, samples, 480, bytes, sizeof(bytes)); CHECK(size > 0);
        CHECK(opus_packet_get_nb_channels(bytes) == 1 && opus_packet_get_nb_samples(bytes, size, 48000) == 480);
        uint8_t length[] = {size >> 8, size};
        CHECK(fwrite(length, 1, 2, file) == 2 && fwrite(bytes, 1, size, file) == (size_t)size);
    }
    opus_encoder_destroy(encoder); CHECK(!fclose(file));
    puts("microphone_opus_fixture=pass packets=300 mono=1 frames=480");
}
