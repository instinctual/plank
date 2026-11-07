/* SPDX-License-Identifier: GPL-3.0-only */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "plank_transport_setup.h"

#define CHECK(condition) do { if (!(condition)) abort(); } while (0)

static void check_launch_envelope_vector(void) {
    static const uint8_t payload[] = "{}";
    static const uint8_t expected[] = {
        0x50, 0x4c, 0x53, 0x31, 0x00, 0x01, 0x00, 0x0a,
        0x00, 0x01, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04,
        0x00, 0x00, 0x00, 0x02,
        0x7b, 0x7d,
    };
    uint8_t encoded[128] = {0};
    size_t encoded_size = 0;
    PlankTransportSetupPacket decoded;

    CHECK(plank_transport_setup_encode(
              PLANK_TRANSPORT_SETUP_LAUNCH_RESPONSE,
              PLANK_TRANSPORT_SETUP_FLAG_RESPONSE,
              PLANK_TRANSPORT_SETUP_STATUS_OK, 0x01020304,
              payload, sizeof(payload) - 1,
              encoded, sizeof(encoded), &encoded_size) == 0);
    CHECK(encoded_size == sizeof(expected));
    CHECK(memcmp(encoded, expected, sizeof(expected)) == 0);
    CHECK(plank_transport_setup_decode(encoded, encoded_size, &decoded) == 0);
    CHECK(decoded.type == PLANK_TRANSPORT_SETUP_LAUNCH_RESPONSE);
    CHECK(decoded.flags == PLANK_TRANSPORT_SETUP_FLAG_RESPONSE);
    CHECK(decoded.status == PLANK_TRANSPORT_SETUP_STATUS_OK);
    CHECK(decoded.request_id == 0x01020304);
    CHECK(decoded.payload_size == sizeof(payload) - 1);
    CHECK(memcmp(decoded.payload, payload, sizeof(payload) - 1) == 0);
}

static void check_empty_request(void) {
    uint8_t encoded[PLANK_TRANSPORT_SETUP_HEADER_SIZE] = {0};
    size_t encoded_size = 0;
    PlankTransportSetupPacket decoded;

    CHECK(plank_transport_setup_encode(
              PLANK_TRANSPORT_SETUP_LAUNCH_REQUEST, 0,
              PLANK_TRANSPORT_SETUP_STATUS_OK, 1, NULL, 0,
              encoded, sizeof(encoded), &encoded_size) == 0);
    CHECK(encoded_size == PLANK_TRANSPORT_SETUP_HEADER_SIZE);
    CHECK(plank_transport_setup_decode(encoded, encoded_size, &decoded) == 0);
    CHECK(decoded.payload_size == 0);
}

static void check_launch_response(void) {
    static const uint8_t payload[] =
        "{\"video_format\":8,\"host_feature_flags\":127,"
        "\"reference_frame_invalidation\":1,\"audio\":{"
        "\"sample_rate\":48000,\"channels\":2,\"streams\":1,"
        "\"coupled_streams\":1,\"packet_duration_ms\":5,"
        "\"mapping\":[0,1]}}";
    uint8_t encoded[512] = {0};
    size_t encoded_size = 0;
    PlankTransportSetupPacket decoded;

    CHECK(plank_transport_setup_encode(
              PLANK_TRANSPORT_SETUP_LAUNCH_RESPONSE,
              PLANK_TRANSPORT_SETUP_FLAG_RESPONSE,
              PLANK_TRANSPORT_SETUP_STATUS_OK, 9,
              payload, sizeof(payload) - 1,
              encoded, sizeof(encoded), &encoded_size) == 0);
    CHECK(plank_transport_setup_decode(encoded, encoded_size, &decoded) == 0);
    CHECK(decoded.type == PLANK_TRANSPORT_SETUP_LAUNCH_RESPONSE);
    CHECK(decoded.flags == PLANK_TRANSPORT_SETUP_FLAG_RESPONSE);
    CHECK(decoded.status == PLANK_TRANSPORT_SETUP_STATUS_OK);
    CHECK(decoded.request_id == 9);
    CHECK(decoded.payload_size == sizeof(payload) - 1);
    CHECK(memcmp(decoded.payload, payload, sizeof(payload) - 1) == 0);
}

static void check_malformed_records(void) {
    uint8_t encoded[64] = {0};
    size_t encoded_size = 0;
    PlankTransportSetupPacket decoded;

    CHECK(plank_transport_setup_encode(
              PLANK_TRANSPORT_SETUP_LAUNCH_REQUEST, 0,
              PLANK_TRANSPORT_SETUP_STATUS_OK, 7, NULL, 0,
              encoded, sizeof(encoded), &encoded_size) == 0);
    CHECK(plank_transport_setup_decode(encoded, encoded_size - 1, &decoded) == -1);
    encoded[0] = 0;
    CHECK(plank_transport_setup_decode(encoded, encoded_size, &decoded) == -1);
    encoded[0] = 0x50;
    encoded[5] = 2;
    CHECK(plank_transport_setup_decode(encoded, encoded_size, &decoded) == -1);
    encoded[5] = 1;
    encoded[8] = 0x80;
    CHECK(plank_transport_setup_decode(encoded, encoded_size, &decoded) == -1);

    CHECK(plank_transport_setup_encode(
              0, 0, 0, 1, NULL, 0,
              encoded, sizeof(encoded), &encoded_size) == -1);
    CHECK(plank_transport_setup_encode(
              PLANK_TRANSPORT_SETUP_LAUNCH_REQUEST, 0, 0, 0,
              NULL, 0, encoded, sizeof(encoded), &encoded_size) == -1);
}

int main(void) {
    check_launch_envelope_vector();
    check_empty_request();
    check_launch_response();
    check_malformed_records();
    return 0;
}
