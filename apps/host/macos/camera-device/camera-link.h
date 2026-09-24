// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "plank_transport_camera.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define PLANK_CAMERA_EXTENSION_ID "la.instinctual.PLANK.Host.Camera"
#define PLANK_CAMERA_EXTENSION_SERVICE "la.instinctual.PLANK.Host.camera-extension"
#define PLANK_CAMERA_PRODUCER_SERVICE "la.instinctual.PLANK.Host.camera-producer"
enum { PLANKCameraLinkVersion = 2, PLANKCameraSlots = 3,
    PLANKCameraRecordBytes = PLANK_CAMERA_HEADER_BYTES + PLANK_CAMERA_MAX_FRAME_BYTES,
    PLANKCameraRecordWords = (PLANKCameraRecordBytes + 7) / 8 };
#define PLANK_CAMERA_MAX_AGE_NS UINT64_C(150000000)
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Shared camera words must be lock free");

// One fresh mapping per lease. No remote sizes, pointers or indices are used.
// All fields touched after publication are atomic, including payload words:
// an overlapping writer cannot create a C data race during a rejected copy.
// Sequential consistency makes each slot's seqlock snapshot well-defined.
typedef struct {
    _Atomic uint64_t stamp, size, hostTime, arrived;
    _Atomic uint64_t words[PLANKCameraRecordWords];
} PLANKCameraSlot;
typedef struct {
    _Atomic uint64_t version, published, keyRequest;
    PLANKCameraSlot slots[PLANKCameraSlots];
} PLANKCameraLink;

static inline size_t PLANKCameraLinkBytes(size_t page) {
    return page && page <= SIZE_MAX - sizeof(PLANKCameraLink) ?
        (sizeof(PLANKCameraLink) + page - 1) / page * page : 0;
}
static inline void PLANKCameraLinkInit(PLANKCameraLink *link) {
    atomic_init(&link->version, PLANKCameraLinkVersion);
    atomic_init(&link->published, 0); atomic_init(&link->keyRequest, 0);
    for (unsigned s = 0; s < PLANKCameraSlots; s++) {
        atomic_init(&link->slots[s].stamp, 0); atomic_init(&link->slots[s].size, 0);
        atomic_init(&link->slots[s].hostTime, 0); atomic_init(&link->slots[s].arrived, 0);
        for (unsigned w = 0; w < PLANKCameraRecordWords; w++) atomic_init(&link->slots[s].words[w], 0);
    }
}
// Serial producer owns serial privately; never derive it from shared memory.
static inline bool PLANKCameraLinkWriteTimed(PLANKCameraLink *link, uint64_t *serial,
                                        const uint8_t *record, size_t size, uint64_t hostTime, uint64_t arrived) {
    if (!link || !serial || !record || size <= PLANK_CAMERA_HEADER_BYTES ||
        size > PLANKCameraRecordBytes || !hostTime || !arrived || *serial >= UINT64_MAX / 2 - 1) return false;
    uint64_t next = ++*serial;
    PLANKCameraSlot *slot = &link->slots[(next - 1) % PLANKCameraSlots];
    atomic_store(&slot->stamp, (next << 1) | 1);
    atomic_store(&slot->size, size); atomic_store(&slot->hostTime, hostTime); atomic_store(&slot->arrived, arrived);
    for (size_t offset = 0; offset < size; offset += 8) {
        uint64_t word = 0; size_t bytes = size - offset < 8 ? size - offset : 8;
        memcpy(&word, record + offset, bytes); atomic_store(&slot->words[offset / 8], word);
    }
    atomic_store(&slot->stamp, next << 1); atomic_store(&link->published, next);
    return true;
}
static inline bool PLANKCameraLinkWrite(PLANKCameraLink *link, uint64_t *serial,
        const uint8_t *record, size_t size, uint64_t hostTime) {
    return PLANKCameraLinkWriteTimed(link, serial, record, size, hostTime, hostTime);
}
// Copies into private storage before any parser/decoder sees bytes. Bounded to
// one snapshot attempt per tick. A failed snapshot is dropped, never spun on.
// Return 1=frame, 0=empty, -1=gap/malformed/stale (caller requests a keyframe).
static inline int PLANKCameraLinkReadTimed(PLANKCameraLink *link, uint64_t *cursor,
                                      uint8_t *record, size_t capacity, size_t *size,
                                      uint64_t *hostTime, uint64_t *arrivalTime, uint64_t now) {
    if (!link || !cursor || !record || !size || !hostTime) return -1;
    *size = 0; *hostTime = 0;
    uint64_t published = atomic_load(&link->published);
    if (published == *cursor) return 0;
    if (published < *cursor || published >= UINT64_MAX / 2) return -1;
    if (published - *cursor > PLANKCameraSlots) { *cursor = published - 1; return -1; }
    uint64_t next = ++*cursor;
    PLANKCameraSlot *slot = &link->slots[(next - 1) % PLANKCameraSlots];
    if (atomic_load(&slot->stamp) != next << 1) return -1;
    uint64_t count = atomic_load(&slot->size), time = atomic_load(&slot->hostTime), arrived = atomic_load(&slot->arrived);
    if (count <= PLANK_CAMERA_HEADER_BYTES || count > PLANKCameraRecordBytes || count > capacity ||
        !time || time > INT64_MAX || !arrived || arrived > now || now - arrived > PLANK_CAMERA_MAX_AGE_NS ||
        (time > now ? time - now > UINT64_C(100000000) : now - time > PLANK_CAMERA_MAX_AGE_NS)) return -1;
    for (size_t offset = 0; offset < count; offset += 8) {
        uint64_t word = atomic_load(&slot->words[offset / 8]);
        size_t bytes = count - offset < 8 ? count - offset : 8;
        memcpy(record + offset, &word, bytes);
    }
    if (atomic_load(&slot->stamp) != next << 1) return -1;
    *size = (size_t)count; *hostTime = time; if (arrivalTime) *arrivalTime = arrived; return 1;
}

static inline int PLANKCameraLinkRead(PLANKCameraLink *link, uint64_t *cursor,
        uint8_t *record, size_t capacity, size_t *size, uint64_t *hostTime, uint64_t now) {
    return PLANKCameraLinkReadTimed(link, cursor, record, capacity, size, hostTime, NULL, now);
}
