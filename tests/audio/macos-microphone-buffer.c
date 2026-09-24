// SPDX-License-Identifier: GPL-3.0-or-later
#include "microphone-buffer.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static PLANKMicBuffer buffer;
static _Atomic bool finished;
static _Atomic uint64_t latest;

static float sample(uint64_t frame) { return (float)(frame % 127) / 128.0f; }
static void *producer(void *unused) {
    (void)unused;
    float samples[32 * PLANKMicChannels];
    for (uint64_t frame = 0; frame < 1000000; frame += 32) {
        for (unsigned i = 0; i < 32; i++) {
            samples[2*i] = sample(frame + i);
            samples[2*i+1] = -samples[2*i];
        }
        assert(PLANKMicBufferWrite(&buffer, frame, samples, 32));
        atomic_store(&latest, frame);
    }
    atomic_store(&finished, true);
    return NULL;
}
static void *consumer(void *unused) {
    (void)unused;
    float samples[32 * PLANKMicChannels];
    do {
        uint64_t frame = atomic_load(&latest);
        assert(PLANKMicBufferRead(&buffer, frame, samples, 32));
        for (unsigned i = 0; i < 32; i++) {
            assert(samples[2*i] == 0 || samples[2*i] == sample(frame + i));
            assert(samples[2*i+1] == -samples[2*i]); // no torn stereo pair
        }
    } while (!atomic_load(&finished));
    return NULL;
}
int main(void) {
    PLANKMicBufferInit(&buffer);
    assert(atomic_is_lock_free(&buffer.samples[0].frame));
    assert(atomic_is_lock_free(&buffer.samples[0].bits));
    float input[] = {0.25f, -0.5f, 2.0f, -2.0f, .5f, -.75f, .125f, -.25f};
    float output[8] = {1, 1, 1, 1, 1, 1, 1, 1};
    assert(PLANKMicBufferRead(&buffer, 0, output, 4));
    for (unsigned i = 0; i < 8; i++) assert(output[i] == 0);
    assert(PLANKMicBufferWrite(&buffer, 8191, input, 4));
    assert(PLANKMicBufferRead(&buffer, 8191, output, 4));
    assert(output[0] == .25f && output[1] == -.5f && output[2] == 1 && output[3] == -1);
    assert(!memcmp(output + 4, input + 4, 4 * sizeof(float)));
    float again[8];
    assert(PLANKMicBufferRead(&buffer, 8191, again, 4));
    assert(!memcmp(output, again, sizeof(output))); // concurrent-app fanout
    assert(PLANKMicBufferRead(&buffer, 8191 + PLANKMicFrames, output, 4));
    for (unsigned i = 0; i < 8; i++) assert(output[i] == 0); // no stale wraparound
    assert(!PLANKMicBufferWrite(&buffer, UINT64_MAX - 1, input, 4));
    assert(!PLANKMicBufferWrite(&buffer, 0, NULL, 4));
    assert(!PLANKMicBufferWrite(&buffer, 0, input, PLANKMicMaxIO + 1));
    assert(!PLANKMicBufferRead(&buffer, 0, output, PLANKMicMaxIO + 1));
    input[7] = NAN;
    assert(!PLANKMicBufferWrite(&buffer, 0, input, 4));
    assert(PLANKMicBufferRead(&buffer, 0, output, 2));
    assert(output[0] == 0 && output[1] == 0); // invalid block was not partly published
    PLANKMicBufferReset(&buffer, 9000);
    assert(PLANKMicBufferRead(&buffer, 8191, output, 4));
    for (unsigned i = 0; i < 8; i++) assert(output[i] == 0);
    input[7] = -.25f;
    assert(!PLANKMicBufferWrite(&buffer, 8999, input, 4));
    assert(PLANKMicBufferWrite(&buffer, 9000, input, 4));
    assert(PLANKMicBufferRead(&buffer, 9000, output, 4));
    assert(output[0] == .25f);
    PLANKMicBufferInit(&buffer);
    pthread_t writer, readers[2];
    assert(!pthread_create(&readers[0], NULL, consumer, NULL));
    assert(!pthread_create(&readers[1], NULL, consumer, NULL));
    assert(!pthread_create(&writer, NULL, producer, NULL));
    assert(!pthread_join(writer, NULL));
    for (unsigned i = 0; i < 2; i++) assert(!pthread_join(readers[i], NULL));
    puts("microphone_buffer=pass frames=1000000 channels=2 readers=2 coherent_pairs=1 bounds=1 silence=1 reset=1");
}
