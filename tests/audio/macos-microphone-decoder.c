// SPDX-License-Identifier: GPL-3.0-or-later
#include <stdio.h>
#include "microphone-decoder.h"
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed line %d\n", __LINE__); exit(1); } } while (0)
int main(int argc, char **argv) {
    if (argc == 1) {
        PLANKMicDecoder decoder; CHECK(PLANKMicDecoderCreate(&decoder));
        const uint8_t silence[] = {0xf4, 0xff, 0xfe}; // RFC 6716 CELT, stereo, 10 ms.
        float samples[960];
        CHECK(!PLANKMicDecode(&decoder, NULL, 0, samples));
        uint8_t bad[] = {0xf0, 0xff, 0xfe}; // Old mono packets must not enter the stereo decoder.
        CHECK(!PLANKMicDecode(&decoder, bad, sizeof(bad), samples));
        bad[0] = 0xfc; // 20 ms is not a 480-sample packet.
        CHECK(!PLANKMicDecode(&decoder, bad, sizeof(bad), samples));
        for (unsigned i = 0; i < 300; i++) {
            if (i == 150) CHECK(PLANKMicDecoderReset(&decoder));
            CHECK(PLANKMicDecode(&decoder, silence, sizeof(silence), samples));
            for (unsigned j = 0; j < 960; j++) CHECK(isfinite(samples[j]) && fabsf(samples[j]) < .001);
        }
        PLANKMicDecoderDestroy(&decoder); PLANKMicDecoderDestroy(&decoder);
        puts("microphone_native_decode_silence_bounds_reset=pass"); return 0;
    }
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "rb"); CHECK(file);
    PLANKMicDecoder decoder; CHECK(PLANKMicDecoderCreate(&decoder));
    unsigned packets = 0, measured = 0;
    double energy[2] = {0}, real[2][2] = {{0}}, imaginary[2][2] = {{0}};
    const double frequencies[2] = {1000, 1500};
    while (!feof(file)) {
        uint8_t bytes[1275], length[2]; float samples[960];
        size_t got = fread(length, 1, 2, file);
        if (!got) break;
        CHECK(got == 2);
        unsigned size = (unsigned)length[0] << 8 | length[1]; CHECK(size && size <= sizeof(bytes));
        CHECK(fread(bytes, 1, size, file) == size);
        CHECK(PLANKMicDecode(&decoder, bytes, size, samples));
        packets++;
        if (packets < 50) continue;
        for (unsigned i = 0; i < 480; i++) {
            for (unsigned channel = 0; channel < 2; channel++) {
                double value = samples[2*i+channel]; energy[channel] += value*value;
                for (unsigned tone = 0; tone < 2; tone++) {
                    double phase = measured * 6.283185307179586 * frequencies[tone] / 48000;
                    real[channel][tone] += value*cos(phase);
                    imaginary[channel][tone] += value*sin(phase);
                }
            }
            measured++;
        }
    }
    CHECK(!ferror(file)); fclose(file); PLANKMicDecoderDestroy(&decoder);
    CHECK(packets == 300 && measured);
    for (unsigned channel = 0; channel < 2; channel++) {
        double rms = sqrt(energy[channel]/measured);
        double tone = 2*hypot(real[channel][channel], imaginary[channel][channel])/measured;
        double cross = 2*hypot(real[channel][1-channel], imaginary[channel][1-channel])/measured;
        double amplitude = channel ? .03125 : .0625;
        printf("microphone_native_decode packets=%u channel=%u rms=%.6f tone=%.6f crosstalk=%.6f\n",
            packets, channel, rms, tone, cross);
        CHECK(rms > amplitude*.56 && rms < amplitude*.88);
        CHECK(tone > amplitude*.8 && tone < amplitude*1.2 && cross < amplitude*.08);
    }
    puts("microphone_native_decode_stereo_separation=pass");
}
