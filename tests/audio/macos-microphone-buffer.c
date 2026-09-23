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
    float samples[32];
    for (uint64_t frame = 0; frame < 1000000; frame += 32) {
        for (unsigned i = 0; i < 32; i++) samples[i] = sample(frame + i);
        assert(PLANKMicBufferWrite(&buffer, frame, samples, 32));
        atomic_store(&latest, frame);
    }
    atomic_store(&finished, true);
    return NULL;
}
static void *consumer(void *unused) {
    (void)unused;
    float samples[32];
    do {
        uint64_t frame = atomic_load(&latest);
        assert(PLANKMicBufferRead(&buffer, frame, samples, 32));
        for (unsigned i = 0; i < 32; i++)
            assert(samples[i] == 0 || samples[i] == sample(frame + i));
    } while (!atomic_load(&finished));
    return NULL;
}
int main(void) {
    PLANKMicBufferInit(&buffer);
    assert(atomic_is_lock_free(&buffer.samples[0].frame));
    assert(atomic_is_lock_free(&buffer.samples[0].bits));
    float input[] = {0.25f, -0.5f, 2.0f, -2.0f};
    float output[4] = {1, 1, 1, 1};
    assert(PLANKMicBufferRead(&buffer, 0, output, 4));
    for (unsigned i = 0; i < 4; i++) assert(output[i] == 0);
    assert(PLANKMicBufferWrite(&buffer, 8191, input, 4));
    assert(PLANKMicBufferRead(&buffer, 8191, output, 4));
    assert(output[0] == .25f && output[1] == -.5f && output[2] == 1 && output[3] == -1);
    float again[4];
    assert(PLANKMicBufferRead(&buffer, 8191, again, 4));
    assert(!memcmp(output, again, sizeof(output))); // concurrent-app fanout
    assert(PLANKMicBufferRead(&buffer, 8191 + PLANKMicFrames, output, 4));
    for (unsigned i = 0; i < 4; i++) assert(output[i] == 0); // no stale wraparound
    assert(!PLANKMicBufferWrite(&buffer, UINT64_MAX - 1, input, 4));
    assert(!PLANKMicBufferWrite(&buffer, 0, NULL, 4));
    assert(!PLANKMicBufferWrite(&buffer, 0, input, PLANKMicMaxIO + 1));
    assert(!PLANKMicBufferRead(&buffer, 0, output, PLANKMicMaxIO + 1));
    input[2] = NAN;
    assert(!PLANKMicBufferWrite(&buffer, 0, input, 4));
    assert(PLANKMicBufferRead(&buffer, 0, output, 2));
    assert(output[0] == 0 && output[1] == 0); // invalid block was not partly published
    PLANKMicBufferReset(&buffer, 9000);
    assert(PLANKMicBufferRead(&buffer, 8191, output, 4));
    for (unsigned i = 0; i < 4; i++) assert(output[i] == 0);
    input[2] = .5f;
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
    puts("microphone_buffer=pass samples=1000000 readers=2 bounds=1 silence=1 reset=1");
}
