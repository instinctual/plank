/* SPDX-License-Identifier: AGPL-3.0-or-later */

#ifndef PLANK_TRANSPORT_CONTROL_H
#define PLANK_TRANSPORT_CONTROL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ASCII "PLD1": PLANK native data/control protocol version 1. */
#define PLANK_TRANSPORT_CONTROL_MAGIC 0x504c4431u
#define PLANK_TRANSPORT_CONTROL_HEADER_SIZE 8u
#define PLANK_TRANSPORT_CONTROL_MAX_PACKET_SIZE 20u

/* Host termination reasons carried by PLANK_TRANSPORT_CONTROL_HOST_TERMINATE. */
#define PLANK_TRANSPORT_TERMINATION_GRACEFUL 0x80030023u
#define PLANK_TRANSPORT_TERMINATION_SESSION_TAKEN_OVER 0x80030024u

typedef enum PlankTransportControlType {
    PLANK_TRANSPORT_CONTROL_CLIENT_DISCONNECT = 1,
    PLANK_TRANSPORT_CONTROL_HOST_TERMINATE = 2,
    PLANK_TRANSPORT_CONTROL_REQUEST_IDR = 3,
    PLANK_TRANSPORT_CONTROL_INVALIDATE_REFERENCE_FRAMES = 4,
    PLANK_TRANSPORT_CONTROL_SET_VIDEO_BITRATE = 5,
    PLANK_TRANSPORT_CONTROL_VIDEO_BITRATE_APPLIED = 6,
    /* Host-only, zero payload; advisory, never authentication or launch authority. */
    PLANK_TRANSPORT_CONTROL_HOST_DESKTOP_HANDOFF = 7,
    /* Capability-gated: u64 generation (high/low u32), then flags or state. */
    PLANK_TRANSPORT_CONTROL_SET_MICROPHONE = 8,
    PLANK_TRANSPORT_CONTROL_MICROPHONE_APPLIED = 9,
} PlankTransportControlType;

#define PLANK_TRANSPORT_MICROPHONE_ENABLED 1u
#define PLANK_TRANSPORT_MICROPHONE_AUTO_INPUT 2u
#define PLANK_TRANSPORT_MICROPHONE_OFF 0u
#define PLANK_TRANSPORT_MICROPHONE_PENDING 1u
#define PLANK_TRANSPORT_MICROPHONE_ACTIVE 2u
#define PLANK_TRANSPORT_MICROPHONE_UNAVAILABLE 3u

typedef struct PlankTransportControlPacket {
    uint16_t type;
    const uint8_t *payload;
    uint16_t payload_size;
} PlankTransportControlPacket;

static inline void plank_transport_control_write_u16(uint8_t *output,
                                                   uint16_t value) {
    output[0] = (uint8_t)(value >> 8);
    output[1] = (uint8_t)value;
}

static inline void plank_transport_control_write_u32(uint8_t *output,
                                                   uint32_t value) {
    output[0] = (uint8_t)(value >> 24);
    output[1] = (uint8_t)(value >> 16);
    output[2] = (uint8_t)(value >> 8);
    output[3] = (uint8_t)value;
}

static inline uint16_t plank_transport_control_read_u16(const uint8_t *input) {
    return (uint16_t)(((uint16_t)input[0] << 8) | input[1]);
}

static inline uint32_t plank_transport_control_read_u32(const uint8_t *input) {
    return ((uint32_t)input[0] << 24) |
           ((uint32_t)input[1] << 16) |
           ((uint32_t)input[2] << 8) |
           (uint32_t)input[3];
}

static inline int plank_transport_control_encode(
        uint16_t type, const uint32_t *values, size_t value_count,
        uint8_t *output, size_t output_capacity, size_t *output_size) {
    size_t payload_size;
    size_t packet_size;
    size_t index;

    if (output == NULL || output_size == NULL ||
            value_count > 3 || (value_count != 0 && values == NULL)) {
        return -1;
    }
    payload_size = value_count * sizeof(uint32_t);
    packet_size = PLANK_TRANSPORT_CONTROL_HEADER_SIZE + payload_size;
    if (output_capacity < packet_size) {
        return -1;
    }

    plank_transport_control_write_u32(output, PLANK_TRANSPORT_CONTROL_MAGIC);
    plank_transport_control_write_u16(output + 4, type);
    plank_transport_control_write_u16(output + 6, (uint16_t)payload_size);
    for (index = 0; index < value_count; ++index) {
        plank_transport_control_write_u32(
                    output + PLANK_TRANSPORT_CONTROL_HEADER_SIZE +
                        index * sizeof(uint32_t),
                    values[index]);
    }
    *output_size = packet_size;
    return 0;
}

static inline int plank_transport_control_decode(
        const uint8_t *packet, size_t packet_size,
        PlankTransportControlPacket *decoded) {
    uint16_t payload_size;

    if (packet == NULL || decoded == NULL ||
            packet_size < PLANK_TRANSPORT_CONTROL_HEADER_SIZE ||
            plank_transport_control_read_u32(packet) !=
                PLANK_TRANSPORT_CONTROL_MAGIC) {
        return -1;
    }
    payload_size = plank_transport_control_read_u16(packet + 6);
    if (packet_size != PLANK_TRANSPORT_CONTROL_HEADER_SIZE + payload_size) {
        return -1;
    }

    decoded->type = plank_transport_control_read_u16(packet + 4);
    decoded->payload = packet + PLANK_TRANSPORT_CONTROL_HEADER_SIZE;
    decoded->payload_size = payload_size;
    return 0;
}

#ifdef __cplusplus
}
#endif

#endif
