// SPDX-License-Identifier: GPL-3.0-or-later
#include "camera-link.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static PLANKCameraLink *link;
static _Atomic bool finished;
static void *writer(void *unused) {
    (void)unused; uint64_t serial = 0; uint8_t bytes[5003];
    for (unsigned i = 1; i <= 5000; i++) {
        memset(bytes, (uint8_t)i, sizeof(bytes));
        assert(PLANKCameraLinkWrite(link, &serial, bytes, sizeof(bytes), 100));
    }
    atomic_store(&finished, true); return NULL;
}
int main(void) {
    link = malloc(sizeof(*link)); assert(link); PLANKCameraLinkInit(link);
    uint8_t *input = malloc(PLANKCameraRecordBytes), *output = malloc(PLANKCameraRecordBytes);
    assert(input && output); memset(input, 0x81, PLANKCameraRecordBytes);
    uint64_t serial = 0, cursor = 0, time = 0; size_t size = 0;
    assert(!PLANKCameraLinkWrite(link, &serial, input, PLANK_CAMERA_HEADER_BYTES, 100));
    assert(!PLANKCameraLinkWrite(link, &serial, input, PLANKCameraRecordBytes + 1, 100));
    assert(PLANKCameraLinkRead(link, &cursor, output, PLANKCameraRecordBytes, &size, &time, 100) == 0);
    assert(PLANKCameraLinkWrite(link, &serial, input, PLANKCameraRecordBytes, 100));
    assert(PLANKCameraLinkRead(link, &cursor, output, PLANKCameraRecordBytes, &size, &time, 100) == 1);
    assert(size == PLANKCameraRecordBytes && time == 100 && !memcmp(input, output, size));
    for (unsigned i = 0; i < 4; i++) assert(PLANKCameraLinkWrite(link, &serial, input, 67, 100));
    assert(PLANKCameraLinkRead(link, &cursor, output, PLANKCameraRecordBytes, &size, &time, 100) == -1);
    assert(PLANKCameraLinkRead(link, &cursor, output, PLANKCameraRecordBytes, &size, &time, 100) == 1 && size == 67);
    assert(PLANKCameraLinkWrite(link, &serial, input, 67, 100));
    assert(PLANKCameraLinkRead(link, &cursor, output, PLANKCameraRecordBytes, &size, &time, 99) == -1);
    assert(PLANKCameraLinkWrite(link, &serial, input, 67, 100));
    assert(PLANKCameraLinkRead(link, &cursor, output, PLANKCameraRecordBytes, &size, &time, 101 + PLANK_CAMERA_MAX_AGE_NS) == -1);
    assert(PLANKCameraLinkWrite(link, &serial, input, 67, 100));
    atomic_store(&link->slots[(serial - 1) % PLANKCameraSlots].size, UINT64_MAX);
    assert(PLANKCameraLinkRead(link, &cursor, output, PLANKCameraRecordBytes, &size, &time, 100) == -1);
    // Future presentation time cannot keep an old received frame alive.
    uint64_t arrived = 0;
    assert(PLANKCameraLinkWriteTimed(link, &serial, input, 67, 200000000, 100000000));
    assert(PLANKCameraLinkReadTimed(link, &cursor, output, PLANKCameraRecordBytes,
        &size, &time, &arrived, 100000000) == 1 && time == 200000000 && arrived == 100000000);
    assert(PLANKCameraLinkWriteTimed(link, &serial, input, 67, 200000000, 100000000));
    assert(PLANKCameraLinkReadTimed(link, &cursor, output, PLANKCameraRecordBytes,
        &size, &time, &arrived, 250000001) == -1);
    atomic_store(&link->published, UINT64_MAX);
    assert(PLANKCameraLinkRead(link, &cursor, output, PLANKCameraRecordBytes, &size, &time, 100) == -1);
    PLANKCameraLinkInit(link); cursor = 0; pthread_t thread;
    assert(!pthread_create(&thread, NULL, writer, NULL));
    unsigned reads = 0;
    do {
        int result = PLANKCameraLinkRead(link, &cursor, output, PLANKCameraRecordBytes, &size, &time, 100);
        if (result == 1) {
            assert(size == 5003);
            for (size_t i = 1; i < size; i++) assert(output[i] == output[0]);
            reads++;
        }
    } while (!atomic_load(&finished));
    assert(!pthread_join(thread, NULL)); assert(reads);
    free(output); free(input); free(link);
    puts("camera shared link: bounds, age, overflow and concurrent snapshots passed");
    return 0;
}
