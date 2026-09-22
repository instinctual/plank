/* SPDX-License-Identifier: AGPL-3.0-or-later */

#ifndef PLANK_TRANSPORT_H
#define PLANK_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PLANK_TRANSPORT_ABI_VERSION 13u

typedef struct PlankTransportEndpoint PlankTransportEndpoint;
typedef struct PlankTransportNativeEndpoint PlankTransportNativeEndpoint;

typedef enum PlankTransportMode {
    PLANK_TRANSPORT_MODE_SERVER = 1,
    PLANK_TRANSPORT_MODE_CLIENT = 2,
} PlankTransportMode;

typedef enum PlankTransportSessionMode {
    PLANK_TRANSPORT_SESSION_ACTIVE = 0,
    PLANK_TRANSPORT_SESSION_SETUP = 1,
} PlankTransportSessionMode;

typedef enum PlankTransportState {
    PLANK_TRANSPORT_STATE_INVALID = 0,
    PLANK_TRANSPORT_STATE_IDLE = 1,
    PLANK_TRANSPORT_STATE_STARTING = 2,
    PLANK_TRANSPORT_STATE_PEER_VALIDATION = 3,
    PLANK_TRANSPORT_STATE_SETUP_READY = 4,
    PLANK_TRANSPORT_STATE_READY = 5,
    PLANK_TRANSPORT_STATE_STOPPING = 6,
    PLANK_TRANSPORT_STATE_STOPPED = 7,
    PLANK_TRANSPORT_STATE_FAILED = 8,
} PlankTransportState;

typedef enum PlankTransportResult {
    PLANK_TRANSPORT_OK = 0,
    PLANK_TRANSPORT_TIMEOUT = 1,
    PLANK_TRANSPORT_DROPPED = 2,
    PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT = -1,
    PLANK_TRANSPORT_ERROR_INVALID_STATE = -2,
    PLANK_TRANSPORT_ERROR_RUNTIME = -3,
    PLANK_TRANSPORT_ERROR_PANIC = -4,
    PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL = -5,
} PlankTransportResult;

typedef struct PlankTransportStats {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t video_packets_sent;
    uint64_t video_bytes_sent;
    uint64_t video_packets_received;
    uint64_t video_bytes_received;
    uint64_t video_send_queue_drops;
    uint64_t video_receive_queue_drops;
    uint64_t video_transport_send_drops;
    uint64_t malformed_datagrams;
    uint64_t video_send_queue_high_water;
    uint64_t video_receive_queue_high_water;
    uint64_t audio_packets_sent;
    uint64_t audio_bytes_sent;
    uint64_t audio_packets_received;
    uint64_t audio_bytes_received;
    uint64_t audio_send_queue_drops;
    uint64_t audio_receive_queue_drops;
    uint64_t audio_transport_send_drops;
    uint64_t audio_send_queue_high_water;
    uint64_t audio_receive_queue_high_water;
    uint64_t media_quic_rtt_us;
    uint64_t media_quic_packets_lost;
    uint64_t control_packets_sent;
    uint64_t control_bytes_sent;
    uint64_t control_packets_received;
    uint64_t control_bytes_received;
    uint64_t control_send_queue_full;
    uint64_t control_receive_queue_overflow;
    uint64_t control_send_queue_high_water;
    uint64_t control_receive_queue_high_water;
    uint64_t interaction_quic_rtt_us;
    uint64_t interaction_quic_packets_lost;
} PlankTransportStats;

/*
 * Strings are copied during plank_transport_endpoint_create() and need only
 * remain valid for that call. Server mode requires bind_address,
 * certificate_path, private_key_path, and session_token. Client mode requires
 * remote_address, server_name, and session_token. A non-NULL
 * certificate_sha256 selects exact-fingerprint validation. NULL selects the
 * explicit PLANK certificate-profile validation workflow documented
 * with plank_transport_native_endpoint_peer_certificate().
 */
typedef struct PlankTransportConfig {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t mode;
    uint32_t handshake_timeout_ms;
    uint32_t idle_timeout_ms;
    uint32_t keep_alive_interval_ms;
    uint32_t session_mode;
    /*
     * Maximum complete QUIC UDP payload, excluding outer IP/UDP headers.
     * Zero retains Quinn's default path policy. A nonzero value also limits
     * the peer through QUIC's max_udp_payload_size transport parameter.
     */
    uint32_t max_udp_payload_size;
    /*
     * Initial server-side video encoder target in kilobits per second. This
     * drives the FEC-inclusive native transport budget. Zero is valid for a
     * receive-only client endpoint.
     */
    uint32_t initial_video_bitrate_kbps;
    const char *bind_address;
    const char *remote_address;
    const char *server_name;
    const char *certificate_path;
    const char *private_key_path;
    const char *certificate_sha256;
    const char *session_token;
} PlankTransportConfig;

#define PLANK_TRANSPORT_NATIVE_VIDEO_CODEC_H264 0x48323634u
#define PLANK_TRANSPORT_NATIVE_VIDEO_CODEC_HEVC 0x48455643u
#define PLANK_TRANSPORT_NATIVE_VIDEO_FLAG_KEY 0x00000001u

typedef struct PlankTransportNativeVideoFrameInfo {
    uint32_t struct_size;
    uint32_t codec;
    uint32_t flags;
    uint32_t reserved;
    uint64_t frame_number;
    uint64_t pts;
    uint16_t host_processing_latency;
    uint8_t reserved2[6];
} PlankTransportNativeVideoFrameInfo;

typedef struct PlankTransportNativeAudioPacketInfo {
    uint32_t struct_size;
    uint16_t frame_samples;
    uint16_t reserved;
    uint32_t missing_samples;
    uint32_t reserved2;
    uint64_t pts;
} PlankTransportNativeAudioPacketInfo;

typedef struct PlankTransportNativeStats {
    uint32_t struct_size;
    uint64_t video_frames_sent;
    uint64_t video_bytes_sent;
    uint64_t video_frames_received;
    uint64_t video_bytes_received;
    uint64_t video_send_drops;
    uint64_t video_receive_drops;
    uint64_t audio_packets_sent;
    uint64_t audio_bytes_sent;
    uint64_t audio_packets_received;
    uint64_t audio_bytes_received;
    uint64_t audio_send_drops;
    uint64_t audio_receive_drops;
    uint64_t input_packets_sent;
    uint64_t input_packets_received;
    uint64_t data_packets_sent;
    uint64_t data_packets_received;
    uint64_t quic_rtt_us;
    uint64_t quic_packets_lost;
    uint64_t kyproto_packets_dropped;
    uint64_t video_fec_source_symbols;
    uint64_t video_fec_source_symbols_missing;
    /* Missing originals in expired, unreconstructed FEC objects; not frame gaps. */
    uint64_t video_fec_source_symbols_unrecovered;
} PlankTransportNativeStats;

uint32_t plank_transport_abi_version(void);

int32_t plank_transport_endpoint_create(const PlankTransportConfig *config,
                                     PlankTransportEndpoint **endpoint_out);
int32_t plank_transport_endpoint_start(PlankTransportEndpoint *endpoint);
int32_t plank_transport_endpoint_wait_ready(PlankTransportEndpoint *endpoint,
                                         uint32_t timeout_ms);
uint32_t plank_transport_endpoint_state(const PlankTransportEndpoint *endpoint);

/*
 * Returns the largest complete legacy video packet that can be carried inside
 * one negotiated QUIC DATAGRAM after PLANK framing. Zero means the
 * endpoint is invalid or has not reached READY.
 */
size_t plank_transport_video_max_packet_size(const PlankTransportEndpoint *endpoint);
size_t plank_transport_audio_max_packet_size(const PlankTransportEndpoint *endpoint);

/*
 * Server-only, nonblocking video submission. Both byte ranges are copied
 * before this function returns. PLANK_TRANSPORT_DROPPED means the new packet was
 * accepted after evicting the oldest queued video packet to preserve latency.
 */
int32_t plank_transport_video_send(PlankTransportEndpoint *endpoint,
                                const uint8_t *prefix,
                                size_t prefix_size,
                                const uint8_t *payload,
                                size_t payload_size);

/*
 * Client-only bounded wait for one received legacy video packet. On success,
 * packet_size_out is the copied byte count. When the destination is too small,
 * packet_size_out reports the required count and the packet remains queued.
 */
int32_t plank_transport_video_receive(PlankTransportEndpoint *endpoint,
                                   uint8_t *packet,
                                   size_t packet_capacity,
                                   size_t *packet_size_out,
                                   uint32_t timeout_ms);

/*
 * Server-only, nonblocking audio submission. Complete existing encrypted
 * audio or audio-FEC packets are copied without repacketization. Audio has
 * strict dequeue priority over video. PLANK_TRANSPORT_DROPPED means the new
 * packet was accepted after evicting the oldest queued audio packet.
 */
int32_t plank_transport_audio_send(PlankTransportEndpoint *endpoint,
                                const uint8_t *prefix,
                                size_t prefix_size,
                                const uint8_t *payload,
                                size_t payload_size);

/*
 * Client-only bounded wait for one received legacy audio packet. Buffer and
 * retention behavior matches plank_transport_video_receive().
 */
int32_t plank_transport_audio_receive(PlankTransportEndpoint *endpoint,
                                   uint8_t *packet,
                                   size_t packet_capacity,
                                   size_t *packet_size_out,
                                   uint32_t timeout_ms);

/*
 * Bidirectional, nonblocking submission of one complete encrypted GameStream
 * control packet. The bytes are copied. A full bounded queue returns
 * PLANK_TRANSPORT_TIMEOUT and never evicts a previously accepted record.
 */
int32_t plank_transport_control_send(PlankTransportEndpoint *endpoint,
                                  const uint8_t *packet,
                                  size_t packet_size);

/*
 * Bidirectional bounded wait for one complete encrypted GameStream control
 * packet. Buffer and retention behavior matches the media receive functions.
 */
int32_t plank_transport_control_receive(PlankTransportEndpoint *endpoint,
                                     uint8_t *packet,
                                     size_t packet_capacity,
                                     size_t *packet_size_out,
                                     uint32_t timeout_ms);

int32_t plank_transport_endpoint_stats(const PlankTransportEndpoint *endpoint,
                                    PlankTransportStats *stats);

int32_t plank_transport_endpoint_stop(PlankTransportEndpoint *endpoint);
void plank_transport_endpoint_destroy(PlankTransportEndpoint *endpoint);

/*
 * Returns the required byte count including the trailing NUL. If buffer is
 * non-NULL and buffer_size is nonzero, the result is always NUL-terminated.
 */
size_t plank_transport_endpoint_last_error(const PlankTransportEndpoint *endpoint,
                                        char *buffer,
                                        size_t buffer_size);

/*
 * KyProto-native complete-frame API. This deliberately bypasses the legacy
 * GameStream RTP, AES, Reed-Solomon, packetization, and depacketization path.
 * The Host submits complete encoded Annex-B frames and raw Opus packets;
 * KyProto owns packetization, RaptorQ, ordering, and reconstruction.
 */
int32_t plank_transport_native_endpoint_create(
        const PlankTransportConfig *config,
        PlankTransportNativeEndpoint **endpoint_out);
int32_t plank_transport_native_endpoint_start(
        PlankTransportNativeEndpoint *endpoint);
int32_t plank_transport_native_endpoint_wait_ready(
        PlankTransportNativeEndpoint *endpoint, uint32_t timeout_ms);
uint32_t plank_transport_native_endpoint_state(
        const PlankTransportNativeEndpoint *endpoint);

/*
 * A Client config with certificate_sha256 == NULL pauses in PEER_VALIDATION.
 * The caller must validate this DER leaf certificate against the
 * PLANK certificate profile, then explicitly approve it. No native
 * application queue is active before approval. Exact-fingerprint Client
 * configs retain automatic validation and proceed directly to READY.
 */
int32_t plank_transport_native_endpoint_peer_certificate(
        const PlankTransportNativeEndpoint *endpoint,
        uint8_t *certificate, size_t certificate_capacity,
        size_t *certificate_size_out);
int32_t plank_transport_native_endpoint_approve_peer_certificate(
        PlankTransportNativeEndpoint *endpoint);

/*
 * SETUP endpoints expose only reliable data while in SETUP_READY. After the
 * Host has completed PAM, ownership, display, and launch validation and sent
 * SESSION_READY, each peer authorizes its side of the same connection. Only
 * then are KyProto media and input endpoints registered and READY reached.
 */
int32_t plank_transport_native_endpoint_authorize_session(
        PlankTransportNativeEndpoint *endpoint);

int32_t plank_transport_native_video_send(
        PlankTransportNativeEndpoint *endpoint,
        const PlankTransportNativeVideoFrameInfo *info,
        const uint8_t *payload, size_t payload_size);
/* Update the live video target and peak-inclusive native transport budget. */
int32_t plank_transport_native_set_video_bitrate(
        PlankTransportNativeEndpoint *endpoint, uint32_t bitrate_kbps,
        uint32_t peak_bitrate_kbps);
/* Native video/audio/input receives validate output storage and claim exactly
 * one queued item atomically, then copy its payload outside the queue lock.
 * BUFFER_TOO_SMALL reports the required size without consuming the item;
 * metadata is written only on OK. A later video/audio overflow may still
 * evict an unclaimed item before a caller retries with a larger buffer. */
int32_t plank_transport_native_video_receive(
        PlankTransportNativeEndpoint *endpoint,
        PlankTransportNativeVideoFrameInfo *info,
        uint8_t *payload, size_t payload_capacity,
        size_t *payload_size_out, uint32_t timeout_ms);

int32_t plank_transport_native_audio_send(
        PlankTransportNativeEndpoint *endpoint,
        const PlankTransportNativeAudioPacketInfo *info,
        const uint8_t *payload, size_t payload_size);
/* Audio hole notifications have size zero; payload may be NULL in that case. */
int32_t plank_transport_native_audio_receive(
        PlankTransportNativeEndpoint *endpoint,
        PlankTransportNativeAudioPacketInfo *info,
        uint8_t *payload, size_t payload_capacity,
        size_t *payload_size_out, uint32_t timeout_ms);

int32_t plank_transport_native_input_send(
        PlankTransportNativeEndpoint *endpoint, uint8_t type,
        const uint8_t *payload, size_t payload_size);
int32_t plank_transport_native_input_receive(
        PlankTransportNativeEndpoint *endpoint, uint8_t *type_out,
        uint8_t *payload, size_t payload_capacity,
        size_t *payload_size_out, uint32_t timeout_ms);

/* Reliable data payloads are 1..1048576 bytes. Each direction is bounded to
 * 64 queued packets AND 8 MiB of payload. Send pressure returns TIMEOUT without
 * enqueueing; incoming overflow fails the endpoint without evicting records.
 * A short receive buffer leaves the pending record queued for a retry. */
int32_t plank_transport_native_data_send(
        PlankTransportNativeEndpoint *endpoint,
        const uint8_t *payload, size_t payload_size);
int32_t plank_transport_native_data_receive(
        PlankTransportNativeEndpoint *endpoint,
        uint8_t *payload, size_t payload_capacity,
        size_t *payload_size_out, uint32_t timeout_ms);

int32_t plank_transport_native_endpoint_stats(
        const PlankTransportNativeEndpoint *endpoint,
        PlankTransportNativeStats *stats);
/* Stop cancels establishment, setup/promotion and streaming, then joins the
 * worker. It does not wait for the handshake timeout. Hosts retain a bounded
 * (up to one second) QUIC close drain. Repeated stop calls are safe; failure
 * state and its original error are preserved. */
int32_t plank_transport_native_endpoint_stop(
        PlankTransportNativeEndpoint *endpoint);
/* Destroy includes stop. No other call may use this pointer during/after it. */
void plank_transport_native_endpoint_destroy(
        PlankTransportNativeEndpoint *endpoint);
size_t plank_transport_native_endpoint_last_error(
        const PlankTransportNativeEndpoint *endpoint,
        char *buffer, size_t buffer_size);

#ifdef __cplusplus
}
#endif

#endif
