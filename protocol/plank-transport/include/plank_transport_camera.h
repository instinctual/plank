/* SPDX-License-Identifier: AGPL-3.0-or-later */
#ifndef PLANK_TRANSPORT_CAMERA_H
#define PLANK_TRANSPORT_CAMERA_H
#include "plank_transport_control.h"
#include <string.h>

#define PLANK_CAMERA_HEADER_BYTES 64u
#define PLANK_CAMERA_MAX_FRAME_BYTES (4u * 1024u * 1024u)
#define PLANK_CAMERA_H264 0x48323634u
#define PLANK_CAMERA_MJPEG 0x4d4a5047u
#define PLANK_CAMERA_KEY_FRAME 1u
#define PLANK_CAMERA_DISCONTINUITY 2u

/* PCAM v1 has a fixed 30 fps nominal rate and preserves actual monotonic
 * capture timestamps. Payload bytes belong to the device's H264/MJPG buffer.
 * This header validates transport bounds, never compressed codec contents. */
typedef struct PlankCameraHeader {
    uint64_t generation, sequence, capture_time_us;
    uint32_t codec, colorspace, transfer, ycbcr, quantization, driver_sequence;
    uint16_t width, height;
    uint8_t flags;
} PlankCameraHeader;

static inline int plank_camera_header_valid(const PlankCameraHeader *header, size_t payload_size) {
    return header && payload_size && payload_size <= PLANK_CAMERA_MAX_FRAME_BYTES &&
        header->generation && header->sequence != UINT64_MAX &&
        header->capture_time_us && header->capture_time_us <= (uint64_t)INT64_MAX / 1000 &&
        (header->codec == PLANK_CAMERA_H264 || header->codec == PLANK_CAMERA_MJPEG) &&
        ((header->width == 1280 && header->height == 720) || (header->width == 1920 && header->height == 1080)) &&
        !(header->flags & ~(PLANK_CAMERA_KEY_FRAME | PLANK_CAMERA_DISCONTINUITY)) &&
        (header->codec != PLANK_CAMERA_MJPEG || (header->flags & PLANK_CAMERA_KEY_FRAME)) &&
        header->colorspace <= 12 && header->transfer <= 7 && header->ycbcr <= 8 && header->quantization <= 2;
}
static inline uint64_t plank_camera_read_u64(const uint8_t *bytes) {
    return (uint64_t)plank_transport_control_read_u32(bytes) << 32 | plank_transport_control_read_u32(bytes+4);
}
static inline void plank_camera_write_u64(uint8_t *bytes, uint64_t value) {
    plank_transport_control_write_u32(bytes, (uint32_t)(value >> 32));
    plank_transport_control_write_u32(bytes+4, (uint32_t)value);
}
/* Strict, shared camera control validation. KEYFRAME carries only a u64
 * generation; SET/APPLIED add one flags/state word. Schema-6 capability only. */
static inline int plank_camera_control_decode(const PlankTransportControlPacket *packet,
                                              uint64_t *generation, uint32_t *value) {
    if (!packet || !generation || !value || !packet->payload) return -1;
    *generation = 0; *value = 0;
    if ((packet->type != PLANK_TRANSPORT_CONTROL_SET_CAMERA &&
         packet->type != PLANK_TRANSPORT_CONTROL_CAMERA_APPLIED &&
         packet->type != PLANK_TRANSPORT_CONTROL_CAMERA_KEYFRAME) ||
        packet->payload_size != (packet->type == PLANK_TRANSPORT_CONTROL_CAMERA_KEYFRAME ? 8 : 12)) return -1;
    uint64_t command = plank_camera_read_u64(packet->payload);
    uint32_t state = packet->payload_size == 12 ? plank_transport_control_read_u32(packet->payload + 8) : 0;
    if (!command || command == UINT64_MAX ||
        (packet->type == PLANK_TRANSPORT_CONTROL_SET_CAMERA && state > PLANK_TRANSPORT_CAMERA_ENABLED) ||
        (packet->type == PLANK_TRANSPORT_CONTROL_CAMERA_APPLIED && state > PLANK_TRANSPORT_CAMERA_UNAVAILABLE)) return -1;
    *generation = command; *value = state; return 0;
}
/* Writes only the header; caller appends the native payload unchanged. */
static inline int plank_camera_header_encode(const PlankCameraHeader *header, size_t payload_size,
                                             uint8_t *output, size_t capacity) {
    if (!output || capacity < PLANK_CAMERA_HEADER_BYTES || !plank_camera_header_valid(header, payload_size)) return -1;
    memset(output, 0, PLANK_CAMERA_HEADER_BYTES);
    memcpy(output, "PCAM", 4); output[4] = 1; output[5] = header->flags; output[7] = PLANK_CAMERA_HEADER_BYTES;
    plank_camera_write_u64(output+8, header->generation);
    plank_camera_write_u64(output+16, header->sequence);
    plank_camera_write_u64(output+24, header->capture_time_us);
    plank_transport_control_write_u32(output+32, header->codec);
    plank_transport_control_write_u16(output+36, header->width);
    plank_transport_control_write_u16(output+38, header->height);
    plank_transport_control_write_u32(output+40, header->colorspace);
    plank_transport_control_write_u32(output+44, header->transfer);
    plank_transport_control_write_u32(output+48, header->ycbcr);
    plank_transport_control_write_u32(output+52, header->quantization);
    plank_transport_control_write_u32(output+56, header->driver_sequence);
    return 0;
}
static inline int plank_camera_header_decode(const uint8_t *record, size_t size, PlankCameraHeader *header) {
    if (!header) return -1;
    memset(header, 0, sizeof(*header));
    if (!record || size <= PLANK_CAMERA_HEADER_BYTES || size > PLANK_CAMERA_HEADER_BYTES + PLANK_CAMERA_MAX_FRAME_BYTES ||
        memcmp(record, "PCAM", 4) || record[4] != 1 || record[6] != 0 || record[7] != PLANK_CAMERA_HEADER_BYTES ||
        plank_transport_control_read_u32(record+60)) return -1;
    PlankCameraHeader value;
    memset(&value, 0, sizeof(value));
    value.flags = record[5];
    value.generation = plank_camera_read_u64(record+8);
    value.sequence = plank_camera_read_u64(record+16);
    value.capture_time_us = plank_camera_read_u64(record+24);
    value.codec = plank_transport_control_read_u32(record+32);
    value.width = plank_transport_control_read_u16(record+36);
    value.height = plank_transport_control_read_u16(record+38);
    value.colorspace = plank_transport_control_read_u32(record+40);
    value.transfer = plank_transport_control_read_u32(record+44);
    value.ycbcr = plank_transport_control_read_u32(record+48);
    value.quantization = plank_transport_control_read_u32(record+52);
    value.driver_sequence = plank_transport_control_read_u32(record+56);
    if (!plank_camera_header_valid(&value, size - PLANK_CAMERA_HEADER_BYTES)) return -1;
    *header = value; return 0;
}
#endif
