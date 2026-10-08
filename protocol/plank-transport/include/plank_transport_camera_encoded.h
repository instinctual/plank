/* SPDX-License-Identifier: AGPL-3.0-or-later */
#ifndef PLANK_TRANSPORT_CAMERA_ENCODED_H
#define PLANK_TRANSPORT_CAMERA_ENCODED_H
#include "plank_transport_camera.h"

/* PCAM v2 is selected only by authenticated camera-feature-2 agreement.
 * These are PLANK enums, not V4L2/H.273 passthrough. Initial mode is fixed.
 * No device sequence is fabricated. Header validity is NOT codec validity. */
#define PLANK_CAMERA_MACOS 1u
#define PLANK_CAMERA_VIDEOTOOLBOX_HARDWARE 1u
#define PLANK_CAMERA_NV12 1u
#define PLANK_CAMERA_BT709 1u
#define PLANK_CAMERA_LIMITED_RANGE 1u
typedef struct PlankEncodedCameraHeader {
    uint64_t generation, sequence, capture_time_us;
    uint32_t codec, platform, encoder, source_pixel_format;
    uint16_t width, height, nominal_fps;
    uint8_t flags, primaries, transfer, matrix, range;
} PlankEncodedCameraHeader;

static inline int plank_encoded_camera_header_valid(const PlankEncodedCameraHeader *h, size_t payload) {
    return h && payload && payload <= PLANK_CAMERA_MAX_FRAME_BYTES && h->generation &&
        h->sequence != UINT64_MAX && h->capture_time_us && h->capture_time_us <= (uint64_t)INT64_MAX / 1000 &&
        h->codec == PLANK_CAMERA_H264 && h->width == 1280 && h->height == 720 &&
        !(h->flags & ~(PLANK_CAMERA_KEY_FRAME | PLANK_CAMERA_DISCONTINUITY)) &&
        h->platform == PLANK_CAMERA_MACOS && h->encoder == PLANK_CAMERA_VIDEOTOOLBOX_HARDWARE &&
        h->source_pixel_format == PLANK_CAMERA_NV12 && h->primaries == PLANK_CAMERA_BT709 &&
        h->transfer == PLANK_CAMERA_BT709 && h->matrix == PLANK_CAMERA_BT709 &&
        h->range == PLANK_CAMERA_LIMITED_RANGE && h->nominal_fps == 30;
}
static inline int plank_encoded_camera_header_encode(const PlankEncodedCameraHeader *h, size_t payload,
                                                     uint8_t *out, size_t capacity) {
    if (!out || capacity < PLANK_CAMERA_HEADER_BYTES || !plank_encoded_camera_header_valid(h, payload)) return -1;
    memset(out, 0, PLANK_CAMERA_HEADER_BYTES);
    memcpy(out, "PCAM", 4); out[4] = 2; out[5] = h->flags; out[7] = PLANK_CAMERA_HEADER_BYTES;
    plank_camera_write_u64(out+8, h->generation); plank_camera_write_u64(out+16, h->sequence);
    plank_camera_write_u64(out+24, h->capture_time_us);
    plank_transport_control_write_u32(out+32, h->codec);
    plank_transport_control_write_u16(out+36, h->width); plank_transport_control_write_u16(out+38, h->height);
    plank_transport_control_write_u32(out+40, h->platform); plank_transport_control_write_u32(out+44, h->encoder);
    plank_transport_control_write_u32(out+48, h->source_pixel_format);
    out[52] = h->primaries; out[53] = h->transfer; out[54] = h->matrix; out[55] = h->range;
    plank_transport_control_write_u16(out+56, h->nominal_fps);
    return 0;
}
static inline int plank_encoded_camera_header_decode(const uint8_t *record, size_t size, PlankEncodedCameraHeader *header) {
    if (!header) return -1;
    memset(header, 0, sizeof(*header));
    if (!record || size <= PLANK_CAMERA_HEADER_BYTES || size > PLANK_CAMERA_HEADER_BYTES + PLANK_CAMERA_MAX_FRAME_BYTES ||
        memcmp(record, "PCAM", 4) || record[4] != 2 || record[6] || record[7] != PLANK_CAMERA_HEADER_BYTES ||
        plank_transport_control_read_u16(record+58) || plank_transport_control_read_u32(record+60)) return -1;
    PlankEncodedCameraHeader h; memset(&h, 0, sizeof(h));
    h.flags = record[5]; h.generation = plank_camera_read_u64(record+8); h.sequence = plank_camera_read_u64(record+16);
    h.capture_time_us = plank_camera_read_u64(record+24); h.codec = plank_transport_control_read_u32(record+32);
    h.width = plank_transport_control_read_u16(record+36); h.height = plank_transport_control_read_u16(record+38);
    h.platform = plank_transport_control_read_u32(record+40); h.encoder = plank_transport_control_read_u32(record+44);
    h.source_pixel_format = plank_transport_control_read_u32(record+48); h.primaries = record[52]; h.transfer = record[53];
    h.matrix = record[54]; h.range = record[55]; h.nominal_fps = plank_transport_control_read_u16(record+56);
    if (!plank_encoded_camera_header_valid(&h, size - PLANK_CAMERA_HEADER_BYTES)) return -1;
    *header = h; return 0;
}
#endif
