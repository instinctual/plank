// SPDX-License-Identifier: GPL-3.0-or-later
#include <stdio.h>
#include "microphone-decoder.h"
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed line %d\n", __LINE__); exit(1); } } while (0)
int main(int argc, char **argv) {
    if (argc == 1) {
        PLANKMicDecoder decoder; CHECK(PLANKMicDecoderCreate(&decoder));
        const uint8_t silence[] = {0xf0, 0xff, 0xfe}; // RFC 6716 CELT, mono, 10 ms.
        float samples[480];
        CHECK(!PLANKMicDecode(&decoder, NULL, 0, samples));
        uint8_t bad[] = {0xf4, 0xff, 0xfe}; // Stereo is not this endpoint's format.
        CHECK(!PLANKMicDecode(&decoder, bad, sizeof(bad), samples));
        bad[0] = 0xf8; // 20 ms is not a 480-sample packet.
        CHECK(!PLANKMicDecode(&decoder, bad, sizeof(bad), samples));
        for (unsigned i = 0; i < 300; i++) {
            if (i == 150) CHECK(PLANKMicDecoderReset(&decoder));
            CHECK(PLANKMicDecode(&decoder, silence, sizeof(silence), samples));
            for (unsigned j = 0; j < 480; j++) CHECK(isfinite(samples[j]) && fabsf(samples[j]) < .001);
        }
        PLANKMicDecoderDestroy(&decoder); PLANKMicDecoderDestroy(&decoder);
        puts("microphone_native_decode_silence_bounds_reset=pass"); return 0;
    }
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "rb"); CHECK(file);
    PLANKMicDecoder decoder; CHECK(PLANKMicDecoderCreate(&decoder));
    unsigned packets = 0, measured = 0;
    double energy = 0, real = 0, imaginary = 0;
    while (!feof(file)) {
        uint8_t bytes[1275], length[2]; float samples[480];
        size_t got = fread(length, 1, 2, file);
        if (!got) break;
        CHECK(got == 2);
        unsigned size = (unsigned)length[0] << 8 | length[1]; CHECK(size && size <= sizeof(bytes));
        CHECK(fread(bytes, 1, size, file) == size);
        CHECK(PLANKMicDecode(&decoder, bytes, size, samples));
        packets++;
        if (packets < 50) continue;
        for (unsigned i = 0; i < 480; i++) {
            double phase = measured * 6.283185307179586 * 1000 / 48000;
            energy += samples[i]*samples[i]; real += samples[i]*cos(phase); imaginary += samples[i]*sin(phase); measured++;
        }
    }
    CHECK(!ferror(file)); fclose(file); PLANKMicDecoderDestroy(&decoder);
    CHECK(packets == 300 && measured);
    double rms = sqrt(energy/measured), tone = 2*hypot(real, imaginary)/measured;
    printf("microphone_native_decode packets=%u rms=%.6f tone=%.6f\n", packets, rms, tone);
    CHECK(rms > .035 && rms < .055 && tone > .05 && tone < .075);
    puts("microphone_native_decode=pass");
}
