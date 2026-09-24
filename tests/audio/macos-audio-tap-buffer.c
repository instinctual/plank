// SPDX-License-Identifier: GPL-3.0-or-later
#include "audio-tap-buffer.h"
#include "audio-tap-policy.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <stdio.h>

static void *produce(void *context) {
    PLANKTapBuffer *buffer = context;
    for (unsigned i = 1; i <= 100000; i++) {
        while ((uint32_t)(atomic_load(&buffer->writeIndex) - atomic_load(&buffer->readIndex)) == PLANKTapSlots) sched_yield();
        float samples[] = {(float)i, -(float)i};
        assert(PLANKTapPush(buffer, samples, NULL, 1, i, i * 2.0, i + 1));
    }
    return NULL;
}
int main(void) {
    assert(PLANKTapProcessOwned(502, 100, 101, 502, 502));
    assert(!PLANKTapProcessOwned(502, 100, 100, 502, 502));
    assert(!PLANKTapProcessOwned(502, 100, 0, 502, 502));
    assert(!PLANKTapProcessOwned(502, 100, -1, 502, 502));
    assert(!PLANKTapProcessOwned(0, 100, 101, 0, 0));
    assert(!PLANKTapProcessOwned(502, 100, 101, 0, 502));
    assert(!PLANKTapProcessOwned(502, 100, 101, 502, 0));
    assert(!PLANKTapProcessOwned(502, 100, 101, 501, 501));
    PLANKTapBuffer *buffer = calloc(1, sizeof(*buffer)); assert(buffer);
    PLANKTapBufferInit(buffer);
    assert(atomic_is_lock_free(&buffer->readIndex));
    assert(atomic_is_lock_free(&buffer->writeIndex));
    assert(!PLANKTapPeek(buffer));
    float stereo[] = {1, -1, 0.5, -0.5}, left[] = {1, 0.5}, right[] = {-1, -0.5};
    assert(PLANKTapPush(buffer, left, right, 2, 42, NAN, 7));
    PLANKTapBlock *block = PLANKTapPeek(buffer);
    assert(block && block->frames == 2 && block->hostTime == 42);
    assert(isnan(block->sampleTime) && block->callbackTime == 7);
    assert(!memcmp(block->samples, stereo, sizeof(stereo)));
    PLANKTapPop(buffer); assert(!PLANKTapPeek(buffer));
    for (unsigned i = 0; i < PLANKTapSlots; i++) assert(PLANKTapPush(buffer, stereo, NULL, 2, 1, NAN, 7));
    assert(!PLANKTapPush(buffer, stereo, NULL, 2, 1, NAN, 7)); assert(!atomic_load(&buffer->failed));
    assert(PLANKTapDiscardOverrun(buffer) == 1); assert(!PLANKTapPeek(buffer));
    assert(!PLANKTapDiscardOverrun(buffer));
    assert(PLANKTapPush(buffer, stereo, NULL, 2, 900, NAN, 7));
    assert(PLANKTapPeek(buffer)->hostTime == 900); PLANKTapPop(buffer);
    PLANKTapBufferInit(buffer);
    assert(!PLANKTapPush(buffer, NULL, NULL, 1, 1, NAN, 7)); assert(atomic_load(&buffer->failed) == 1);
    assert(!PLANKTapPush(buffer, stereo, NULL, 0, 1, NAN, 7));
    assert(!PLANKTapPush(buffer, stereo, NULL, PLANKTapMaxFrames + 1, 1, NAN, 7));
    assert(!PLANKTapPush(buffer, stereo, NULL, 2, 0, NAN, 7));
    stereo[0] = NAN; assert(!PLANKTapPush(buffer, stereo, NULL, 2, 1, NAN, 7));
    PLANKTapBufferInit(buffer); atomic_store(&buffer->stopped, true);
    assert(!PLANKTapPush(buffer, left, right, 2, 1, NAN, 7)); assert(!PLANKTapPeek(buffer));
    PLANKTapBufferInit(buffer);
    atomic_store(&buffer->readIndex, UINT32_MAX - 10); atomic_store(&buffer->writeIndex, UINT32_MAX - 10);
    pthread_t producer; assert(!pthread_create(&producer, NULL, produce, buffer));
    for (unsigned i = 1; i <= 100000; i++) {
        while (!(block = PLANKTapPeek(buffer))) sched_yield();
        assert(block->frames == 1 && block->hostTime == i);
        assert(block->sampleTime == i * 2.0 && block->callbackTime == i + 1);
        assert(block->samples[0] == i && block->samples[1] == -(float)i);
        PLANKTapPop(buffer);
    }
    assert(!pthread_join(producer, NULL)); assert(!atomic_load(&buffer->failed));
    assert(!PLANKTapPeek(buffer)); free(buffer);
    puts("audio_tap_buffer_pass blocks=100000 wrap=1 bounds=1 stop=1 owner_policy=1");
}
