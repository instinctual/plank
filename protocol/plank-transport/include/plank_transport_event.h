/* SPDX-License-Identifier: AGPL-3.0-or-later */

#ifndef PLANK_TRANSPORT_EVENT_H
#define PLANK_TRANSPORT_EVENT_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ASCII "PLE1": PLANK native Host-to-Client event protocol. */
#define PLANK_TRANSPORT_EVENT_MAGIC 0x504c4531u
#define PLANK_TRANSPORT_EVENT_HEADER_SIZE 8u
#define PLANK_TRANSPORT_EVENT_MAX_PACKET_SIZE 65535u
#define PLANK_TRANSPORT_EVENT_HDR_MODE_SIZE 28u

typedef enum PlankTransportEventType {
    PLANK_TRANSPORT_EVENT_HDR_MODE = 1,
    PLANK_TRANSPORT_EVENT_RAW_HID_WACOM = 2,
    PLANK_TRANSPORT_EVENT_CURSOR_SHAPE = 3,
    PLANK_TRANSPORT_EVENT_CURSOR_POSITION = 4,
    PLANK_TRANSPORT_EVENT_CLIPBOARD_OFFER = 5,
} PlankTransportEventType;

typedef struct PlankTransportEventPacket {
    uint16_t type;
    const uint8_t *payload;
    uint16_t payload_size;
} PlankTransportEventPacket;

static inline void plank_transport_event_write_u16(uint8_t *output,
                                                 uint16_t value) {
    output[0] = (uint8_t)(value >> 8);
    output[1] = (uint8_t)value;
}

static inline void plank_transport_event_write_u32(uint8_t *output,
                                                 uint32_t value) {
    output[0] = (uint8_t)(value >> 24);
    output[1] = (uint8_t)(value >> 16);
    output[2] = (uint8_t)(value >> 8);
    output[3] = (uint8_t)value;
}

static inline uint16_t plank_transport_event_read_u16(const uint8_t *input) {
    return (uint16_t)(((uint16_t)input[0] << 8) | input[1]);
}

static inline uint32_t plank_transport_event_read_u32(const uint8_t *input) {
    return ((uint32_t)input[0] << 24) |
           ((uint32_t)input[1] << 16) |
           ((uint32_t)input[2] << 8) |
           (uint32_t)input[3];
}

static inline int plank_transport_event_encode(
        uint16_t type, const uint8_t *payload, size_t payload_size,
        uint8_t *output, size_t output_capacity, size_t *output_size) {
    const size_t packet_size = PLANK_TRANSPORT_EVENT_HEADER_SIZE + payload_size;
    if (output == NULL || output_size == NULL ||
            (payload_size != 0 && payload == NULL) ||
            payload_size > UINT16_MAX || output_capacity < packet_size) {
        return -1;
    }
    plank_transport_event_write_u32(output, PLANK_TRANSPORT_EVENT_MAGIC);
    plank_transport_event_write_u16(output + 4, type);
    plank_transport_event_write_u16(output + 6, (uint16_t)payload_size);
    if (payload_size != 0) {
        memcpy(output + PLANK_TRANSPORT_EVENT_HEADER_SIZE, payload, payload_size);
    }
    *output_size = packet_size;
    return 0;
}

static inline int plank_transport_event_decode(
        const uint8_t *packet, size_t packet_size,
        PlankTransportEventPacket *decoded) {
    uint16_t payload_size;
    if (packet == NULL || decoded == NULL ||
            packet_size < PLANK_TRANSPORT_EVENT_HEADER_SIZE ||
            plank_transport_event_read_u32(packet) != PLANK_TRANSPORT_EVENT_MAGIC) {
        return -1;
    }
    payload_size = plank_transport_event_read_u16(packet + 6);
    if (packet_size != PLANK_TRANSPORT_EVENT_HEADER_SIZE + payload_size) {
        return -1;
    }
    decoded->type = plank_transport_event_read_u16(packet + 4);
    decoded->payload = packet + PLANK_TRANSPORT_EVENT_HEADER_SIZE;
    decoded->payload_size = payload_size;
    return 0;
}

#ifdef __cplusplus
}
#endif

#endif
