// SPDX-License-Identifier: GPL-3.0-or-later
// Real native Mac decoder; aggregate counters only, never recorded audio.
#include "microphone-decoder.h"
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
typedef struct {
    PLANKMicDecoder decoder;
    uint64_t packets, frames, next, gaps, different, missing, maximumGap;
    double energy[2], peak[2];
    bool hasSample;
} AudioStats;
void *plank_probe_audio_create(void) {
    AudioStats *stats = calloc(1, sizeof(*stats));
    if (stats && !PLANKMicDecoderCreate(&stats->decoder)) { free(stats); return NULL; }
    return stats;
}
void plank_probe_audio_destroy(void *pointer) {
    AudioStats *stats = pointer;
    if (stats) { PLANKMicDecoderDestroy(&stats->decoder); free(stats); }
}
bool plank_probe_audio_reset(void *pointer) {
    AudioStats *stats = pointer;
    stats->hasSample = false;
    return PLANKMicDecoderReset(&stats->decoder);
}
bool plank_probe_audio_consume(void *pointer, uint64_t sampleTime, const uint8_t *bytes, size_t size) {
    AudioStats *stats = pointer;
    if (stats->hasSample && stats->next != sampleTime) {
        stats->gaps++;
        if (sampleTime > stats->next) {
            uint64_t missing = sampleTime - stats->next;
            stats->missing += missing;
            if (missing > stats->maximumGap) stats->maximumGap = missing;
        }
        if (!PLANKMicDecoderReset(&stats->decoder)) return false;
    }
    float samples[480 * 2];
    if (!PLANKMicDecode(&stats->decoder, bytes, size, samples)) return false;
    for (unsigned frame = 0; frame < 480; ++frame) {
        stats->different += samples[frame*2] != samples[frame*2+1];
        for (unsigned channel = 0; channel < 2; ++channel) {
            double value = samples[frame*2+channel];
            stats->energy[channel] += value * value;
            if (fabs(value) > stats->peak[channel]) stats->peak[channel] = fabs(value);
        }
    }
    stats->packets++; stats->frames += 480;
    stats->hasSample = true; stats->next = sampleTime + 480;
    return true;
}
bool plank_probe_audio_finish(void *pointer) {
    AudioStats *stats = pointer;
    printf("physical_audio_decode packets=%llu frames=%llu channels=2 gaps=%llu missing_frames=%llu maximum_gap_frames=%llu different_frames=%llu left_rms=%.8f right_rms=%.8f left_peak=%.8f right_peak=%.8f\n",
        (unsigned long long)stats->packets, (unsigned long long)stats->frames,
        (unsigned long long)stats->gaps, (unsigned long long)stats->missing,
        (unsigned long long)stats->maximumGap, (unsigned long long)stats->different,
        stats->frames ? sqrt(stats->energy[0]/stats->frames) : 0,
        stats->frames ? sqrt(stats->energy[1]/stats->frames) : 0,
        stats->peak[0], stats->peak[1]);
    return stats->packets >= 100;
}
