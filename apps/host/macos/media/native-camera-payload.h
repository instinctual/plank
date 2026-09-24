// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "plank_transport_camera.h"
#include <stdbool.h>

// Bounded framing validation before Core Media sees untrusted device output.
// This is not a replacement for the platform's compressed-bitstream decoder.
// The initial camera contract accepts single-scan baseline JPEG and ordinary
// H.264 AVC access units, not JPEG progressive or H.264 SVC/MVC extensions.
enum { PLANKCameraMaxNALs = 64, PLANKCameraMaxParameterBytes = 4096 };
typedef struct { size_t offset, size; unsigned type; } PLANKCameraNAL;
typedef struct {
    PLANKCameraNAL nals[PLANKCameraMaxNALs];
    unsigned count, sps, pps;
    bool independent;
} PLANKCameraPayload;

static inline size_t PLANKCameraStartCode(const uint8_t *bytes, size_t size, size_t at) {
    if (at > size || size - at < 3 || bytes[at] || bytes[at+1]) return 0;
    if (bytes[at+2] == 1) return 3;
    return size - at >= 4 && bytes[at+2] == 0 && bytes[at+3] == 1 ? 4 : 0;
}
static inline bool PLANKCameraParseAVC(const uint8_t *bytes, size_t size, PLANKCameraPayload *result) {
    size_t at = 0, adapted = 0;
    bool dependent = false;
    result->sps = result->pps = PLANKCameraMaxNALs;
    while (at < size) {
        size_t prefix = PLANKCameraStartCode(bytes, size, at);
        if (!prefix || result->count == PLANKCameraMaxNALs) return false;
        size_t begin = at + prefix, end = begin;
        while (end < size && !PLANKCameraStartCode(bytes, size, end)) end++;
        at = end;
        // Annex B trailing_zero_8bits are framing, not part of a NAL unit.
        while (end > begin && bytes[end-1] == 0) end--;
        if (end == begin || (bytes[begin] & 0x80)) return false;
        unsigned type = bytes[begin] & 31;
        if (type != 1 && type != 5 && (type < 6 || type > 12)) return false;
        if ((type == 1 || type == 5 || type == 7 || type == 8) && end - begin < 2) return false;
        if (type == 7 || type == 8) {
            unsigned *index = type == 7 ? &result->sps : &result->pps;
            if (dependent || result->independent || *index != PLANKCameraMaxNALs ||
                end - begin > PLANKCameraMaxParameterBytes) return false;
            *index = result->count;
        }
        if (type == 5) result->independent = true;
        if (type == 1) dependent = true;
        result->nals[result->count++] = (PLANKCameraNAL){begin, end-begin, type};
        adapted += 4 + end - begin;
        if (adapted > PLANK_CAMERA_MAX_FRAME_BYTES) return false;
    }
    // Each recovery access unit must carry its own parameter sets. Never inject
    // parameter bytes or call a dependent picture independent based on metadata.
    return result->count && (dependent != result->independent) &&
        (!result->independent || (result->sps < result->count && result->pps < result->count));
}
static inline bool PLANKCameraParseJPEG(const uint8_t *bytes, size_t size, unsigned width, unsigned height) {
    if (size < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return false;
    size_t at = 2;
    unsigned components = 0, ids[3] = {0}, markers = 0;
    bool scan = false;
    while (at < size) {
        if (++markers > 512 || bytes[at++] != 0xff) return false;
        while (at < size && bytes[at] == 0xff) at++;
        if (at == size) return false;
        unsigned marker = bytes[at++];
        if (marker == 0xd9) return scan && at == size;
        if (scan || marker == 0 || marker == 1 || (marker >= 0xd0 && marker <= 0xd8) || size - at < 2) return false;
        size_t length = (size_t)bytes[at] << 8 | bytes[at+1];
        if (length < 2 || length > size - at) return false;
        const uint8_t *data = bytes + at + 2;
        size_t payload = length - 2;
        if (marker == 0xc0) {
            if (components || payload < 6 || data[0] != 8 ||
                ((unsigned)data[1] << 8 | data[2]) != height ||
                ((unsigned)data[3] << 8 | data[4]) != width) return false;
            components = data[5];
            if ((components != 1 && components != 3) || payload != 6 + 3*components) return false;
            for (unsigned i = 0; i < components; i++) {
                ids[i] = data[6+3*i];
                unsigned sampling = data[7+3*i];
                if (!(sampling >> 4) || (sampling >> 4) > 4 || !(sampling & 15) ||
                    (sampling & 15) > 4 || data[8+3*i] > 3) return false;
                for (unsigned j = 0; j < i; j++) if (ids[i] == ids[j]) return false;
            }
        } else if (marker == 0xda) {
            if (!components || payload != 4 + 2*components || data[0] != components ||
                data[payload-3] != 0 || data[payload-2] != 63 || data[payload-1] != 0) return false;
            unsigned seen = 0;
            for (unsigned i = 0; i < components; i++) {
                unsigned found = components, tables = data[2+2*i];
                for (unsigned j = 0; j < components; j++) if (ids[j] == data[1+2*i]) found = j;
                if (found == components || (seen & (1u << found)) || (tables >> 4) > 3 || (tables & 15) > 3) return false;
                seen |= 1u << found;
            }
            scan = true;
        } else if (marker != 0xc4 && marker != 0xdb && marker != 0xdd && marker != 0xfe &&
                   !(marker >= 0xe0 && marker <= 0xef)) return false;
        at += length;
        if (scan) {
            size_t start = at;
            // Entropy bytes can escape FF as FF00 or use restart markers.
            while (at < size) {
                if (bytes[at] != 0xff) { at++; continue; }
                if (size - at < 2) return false;
                if (bytes[at+1] == 0 || (bytes[at+1] >= 0xd0 && bytes[at+1] <= 0xd7)) { at += 2; continue; }
                break;
            }
            if (at == start) return false;
        }
    }
    return false;
}
static inline bool PLANKCameraParsePayload(const PlankCameraHeader *header, const uint8_t *bytes,
                                           size_t size, PLANKCameraPayload *result) {
    if (!result) return false;
    memset(result, 0, sizeof(*result));
    if (!bytes || !plank_camera_header_valid(header, size)) return false;
    if (header->codec == PLANK_CAMERA_MJPEG) {
        result->independent = true;
        return PLANKCameraParseJPEG(bytes, size, header->width, header->height);
    }
    return PLANKCameraParseAVC(bytes, size, result) &&
        result->independent == !!(header->flags & PLANK_CAMERA_KEY_FRAME);
}
