/* SPDX-License-Identifier: AGPL-3.0-or-later */

#ifndef PLANK_TRANSPORT_SETUP_H
#define PLANK_TRANSPORT_SETUP_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ASCII "PLS1": PLANK authenticated launch protocol version 1. */
#define PLANK_TRANSPORT_SETUP_MAGIC 0x504c5331u
#define PLANK_TRANSPORT_SETUP_VERSION 1u
#define PLANK_TRANSPORT_SETUP_HEADER_SIZE 20u
#define PLANK_TRANSPORT_SETUP_MAX_PACKET_SIZE 65536u
#define PLANK_TRANSPORT_SETUP_MAX_PAYLOAD_SIZE \
    (PLANK_TRANSPORT_SETUP_MAX_PACKET_SIZE - PLANK_TRANSPORT_SETUP_HEADER_SIZE)

typedef enum PlankTransportSetupType {
    PLANK_TRANSPORT_SETUP_LAUNCH_REQUEST = 9,
    PLANK_TRANSPORT_SETUP_LAUNCH_RESPONSE = 10,
    PLANK_TRANSPORT_SETUP_ERROR = 12,
} PlankTransportSetupType;

typedef enum PlankTransportSetupFlags {
    PLANK_TRANSPORT_SETUP_FLAG_RESPONSE = 0x0001u,
} PlankTransportSetupFlags;

typedef enum PlankTransportSetupStatus {
    PLANK_TRANSPORT_SETUP_STATUS_OK = 0,
    PLANK_TRANSPORT_SETUP_STATUS_INVALID_REQUEST = 2,
    PLANK_TRANSPORT_SETUP_STATUS_BUSY = 5,
    PLANK_TRANSPORT_SETUP_STATUS_UNSUPPORTED = 6,
    PLANK_TRANSPORT_SETUP_STATUS_INTERNAL_ERROR = 7,
} PlankTransportSetupStatus;

typedef struct PlankTransportSetupPacket {
    uint16_t type;
    uint16_t flags;
    uint16_t status;
    uint32_t request_id;
    const uint8_t *payload;
    uint32_t payload_size;
} PlankTransportSetupPacket;

static inline void plank_transport_setup_write_u16(uint8_t *output,
                                                 uint16_t value) {
    output[0] = (uint8_t)(value >> 8);
    output[1] = (uint8_t)value;
}

static inline void plank_transport_setup_write_u32(uint8_t *output,
                                                 uint32_t value) {
    output[0] = (uint8_t)(value >> 24);
    output[1] = (uint8_t)(value >> 16);
    output[2] = (uint8_t)(value >> 8);
    output[3] = (uint8_t)value;
}

static inline uint16_t plank_transport_setup_read_u16(const uint8_t *input) {
    return (uint16_t)(((uint16_t)input[0] << 8) | input[1]);
}

static inline uint32_t plank_transport_setup_read_u32(const uint8_t *input) {
    return ((uint32_t)input[0] << 24) |
           ((uint32_t)input[1] << 16) |
           ((uint32_t)input[2] << 8) |
           (uint32_t)input[3];
}

static inline int plank_transport_setup_encode(
        uint16_t type, uint16_t flags, uint16_t status, uint32_t request_id,
        const uint8_t *payload, size_t payload_size,
        uint8_t *output, size_t output_capacity, size_t *output_size) {
    const size_t packet_size = PLANK_TRANSPORT_SETUP_HEADER_SIZE + payload_size;

    if ((type != PLANK_TRANSPORT_SETUP_LAUNCH_REQUEST && type != PLANK_TRANSPORT_SETUP_LAUNCH_RESPONSE && type != PLANK_TRANSPORT_SETUP_ERROR) || request_id == 0 || output == NULL || output_size == NULL ||
            (flags & ~PLANK_TRANSPORT_SETUP_FLAG_RESPONSE) != 0 ||
            (payload_size != 0 && payload == NULL) ||
            payload_size > PLANK_TRANSPORT_SETUP_MAX_PAYLOAD_SIZE ||
            output_capacity < packet_size) {
        return -1;
    }

    plank_transport_setup_write_u32(output, PLANK_TRANSPORT_SETUP_MAGIC);
    plank_transport_setup_write_u16(output + 4, PLANK_TRANSPORT_SETUP_VERSION);
    plank_transport_setup_write_u16(output + 6, type);
    plank_transport_setup_write_u16(output + 8, flags);
    plank_transport_setup_write_u16(output + 10, status);
    plank_transport_setup_write_u32(output + 12, request_id);
    plank_transport_setup_write_u32(output + 16, (uint32_t)payload_size);
    if (payload_size != 0) {
        memcpy(output + PLANK_TRANSPORT_SETUP_HEADER_SIZE, payload, payload_size);
    }
    *output_size = packet_size;
    return 0;
}

static inline int plank_transport_setup_decode(
        const uint8_t *packet, size_t packet_size,
        PlankTransportSetupPacket *decoded) {
    uint16_t flags;
    uint32_t payload_size;

    if (packet == NULL || decoded == NULL ||
            packet_size < PLANK_TRANSPORT_SETUP_HEADER_SIZE ||
            packet_size > PLANK_TRANSPORT_SETUP_MAX_PACKET_SIZE ||
            plank_transport_setup_read_u32(packet) != PLANK_TRANSPORT_SETUP_MAGIC ||
            plank_transport_setup_read_u16(packet + 4) !=
                PLANK_TRANSPORT_SETUP_VERSION ||
            (plank_transport_setup_read_u16(packet + 6) != PLANK_TRANSPORT_SETUP_LAUNCH_REQUEST &&
             plank_transport_setup_read_u16(packet + 6) != PLANK_TRANSPORT_SETUP_LAUNCH_RESPONSE &&
             plank_transport_setup_read_u16(packet + 6) != PLANK_TRANSPORT_SETUP_ERROR) ||
            plank_transport_setup_read_u32(packet + 12) == 0) {
        return -1;
    }

    flags = plank_transport_setup_read_u16(packet + 8);
    if ((flags & ~PLANK_TRANSPORT_SETUP_FLAG_RESPONSE) != 0) {
        return -1;
    }
    payload_size = plank_transport_setup_read_u32(packet + 16);
    if (payload_size > PLANK_TRANSPORT_SETUP_MAX_PAYLOAD_SIZE ||
            packet_size != PLANK_TRANSPORT_SETUP_HEADER_SIZE + payload_size) {
        return -1;
    }

    decoded->type = plank_transport_setup_read_u16(packet + 6);
    decoded->flags = flags;
    decoded->status = plank_transport_setup_read_u16(packet + 10);
    decoded->request_id = plank_transport_setup_read_u32(packet + 12);
    decoded->payload = packet + PLANK_TRANSPORT_SETUP_HEADER_SIZE;
    decoded->payload_size = payload_size;
    return 0;
}

#ifdef __cplusplus
}
#endif

#endif
