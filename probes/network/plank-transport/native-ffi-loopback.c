/* SPDX-License-Identifier: AGPL-3.0-or-later */

#define _POSIX_C_SOURCE 200809L

#include "plank_transport.h"
#include "plank_transport_setup.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef PLANK_LOOPBACK_VIDEO_BYTES
/* Large keyframe: exercise submission beyond the 1 MiB outgoing queue and
 * full source-first reconstruction through the production C ABI. */
#define PLANK_LOOPBACK_VIDEO_BYTES 1600013
#endif

/* Exercise peer negotiation without changing the Host's default MTU policy. */
#ifndef PLANK_LOOPBACK_CLIENT_MTU
#define PLANK_LOOPBACK_CLIENT_MTU 0
#endif

static PlankTransportConfig base_config(uint32_t mode, const char *token) {
    PlankTransportConfig config;
    memset(&config, 0, sizeof(config));
    config.struct_size = sizeof(config);
    config.abi_version = PLANK_TRANSPORT_ABI_VERSION;
    config.mode = mode;
    config.handshake_timeout_ms = 5000;
    config.idle_timeout_ms = 10000;
    config.keep_alive_interval_ms = 1000;
    config.session_token = token;
    return config;
}

static void print_error(const char *label,
                        const PlankTransportNativeEndpoint *endpoint) {
    char error[1024] = {0};
    plank_transport_native_endpoint_last_error(endpoint, error, sizeof(error));
    fprintf(stderr, "%s: %s\n", label,
            error[0] == '\0' ? "unknown error" : error);
}

int main(int argc, char **argv) {
    if (argc != 7 && argc != 8) {
        fprintf(stderr,
                "usage: %s <bind> <remote> <server-name> <cert> <key> <hash> "
                "[expected-cert-der]\n",
                argv[0]);
        return 2;
    }

    const int profile_validation = argc == 8;

    const char *token = "plank-native-ffi-loopback";
    PlankTransportConfig server_config =
        base_config(PLANK_TRANSPORT_MODE_SERVER, token);
    server_config.bind_address = argv[1];
    server_config.certificate_path = argv[4];
    server_config.private_key_path = argv[5];
    PlankTransportConfig client_config =
        base_config(PLANK_TRANSPORT_MODE_CLIENT, token);
    client_config.remote_address = argv[2];
    client_config.server_name = argv[3];
    client_config.certificate_sha256 = profile_validation ? NULL : argv[6];
    client_config.max_udp_payload_size = PLANK_LOOPBACK_CLIENT_MTU;


    PlankTransportNativeEndpoint *server = NULL;
    PlankTransportNativeEndpoint *client = NULL;
    if (plank_transport_native_endpoint_create(&server_config, &server) !=
            PLANK_TRANSPORT_OK ||
        plank_transport_native_endpoint_create(&client_config, &client) !=
            PLANK_TRANSPORT_OK ||
        plank_transport_native_endpoint_start(server) != PLANK_TRANSPORT_OK ||
        plank_transport_native_endpoint_start(client) != PLANK_TRANSPORT_OK) {
        fprintf(stderr, "failed to create or start native endpoints\n");
        goto failure;
    }
    if (profile_validation) {
        const struct timespec pause = {0, 10 * 1000 * 1000};
        unsigned int attempt;
        for (attempt = 0; attempt < 700; ++attempt) {
            if (plank_transport_native_endpoint_state(client) ==
                    PLANK_TRANSPORT_STATE_PEER_VALIDATION) {
                break;
            }
            nanosleep(&pause, NULL);
        }
        if (plank_transport_native_endpoint_state(client) !=
                PLANK_TRANSPORT_STATE_PEER_VALIDATION) {
            fprintf(stderr, "client did not pause for certificate validation\n");
            goto failure;
        }
        if (plank_transport_native_data_send(
                client, (const uint8_t *)"blocked", 8) !=
                PLANK_TRANSPORT_ERROR_INVALID_STATE) {
            fprintf(stderr, "application data was accepted before certificate approval\n");
            goto failure;
        }
        FILE *expected_file = fopen(argv[7], "rb");
        if (expected_file == NULL || fseek(expected_file, 0, SEEK_END) != 0) {
            fprintf(stderr, "failed to open expected DER certificate\n");
            if (expected_file != NULL) {
                fclose(expected_file);
            }
            goto failure;
        }
        long expected_size_long = ftell(expected_file);
        if (expected_size_long <= 0 || fseek(expected_file, 0, SEEK_SET) != 0) {
            fprintf(stderr, "invalid expected DER certificate\n");
            fclose(expected_file);
            goto failure;
        }
        size_t expected_size = (size_t)expected_size_long;
        unsigned char *expected = malloc(expected_size);
        unsigned char *received = malloc(expected_size);
        size_t required_size = 0;
        if (expected == NULL || received == NULL ||
            fread(expected, 1, expected_size, expected_file) != expected_size) {
            fprintf(stderr, "failed to read expected DER certificate\n");
            fclose(expected_file);
            free(expected);
            free(received);
            goto failure;
        }
        fclose(expected_file);
        if (plank_transport_native_endpoint_peer_certificate(
                client, NULL, 0, &required_size) !=
                    PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL ||
            required_size != expected_size ||
            plank_transport_native_endpoint_peer_certificate(
                client, received, expected_size, &required_size) !=
                    PLANK_TRANSPORT_OK ||
            memcmp(expected, received, expected_size) != 0) {
            fprintf(stderr, "peer DER certificate mismatch\n");
            free(expected);
            free(received);
            goto failure;
        }
        free(expected);
        free(received);
        if (plank_transport_native_endpoint_approve_peer_certificate(client) !=
                PLANK_TRANSPORT_OK) {
            fprintf(stderr, "failed to approve peer certificate\n");
            goto failure;
        }

    }
    if (plank_transport_native_endpoint_wait_ready(client, 7000) !=
            PLANK_TRANSPORT_OK ||
        plank_transport_native_endpoint_wait_ready(server, 7000) !=
            PLANK_TRANSPORT_OK) {
        print_error("native client", client);
        PlankTransportNativeStats failed_server_stats;
        PlankTransportNativeStats failed_client_stats;
        memset(&failed_server_stats, 0, sizeof(failed_server_stats));
        memset(&failed_client_stats, 0, sizeof(failed_client_stats));
        failed_server_stats.struct_size = sizeof(failed_server_stats);
        failed_client_stats.struct_size = sizeof(failed_client_stats);
        if (plank_transport_native_endpoint_stats(server, &failed_server_stats) ==
                PLANK_TRANSPORT_OK &&
            plank_transport_native_endpoint_stats(client, &failed_client_stats) ==
                PLANK_TRANSPORT_OK) {
            fprintf(stderr,
                    "native video failure stats: sent=%llu received=%llu "
                    "server_quic_lost=%llu client_quic_lost=%llu "
                    "server_kyproto_drops=%llu client_kyproto_drops=%llu\n",
                    (unsigned long long)failed_server_stats.video_frames_sent,
                    (unsigned long long)failed_client_stats.video_frames_received,
                    (unsigned long long)failed_server_stats.quic_packets_lost,
                    (unsigned long long)failed_client_stats.quic_packets_lost,
                    (unsigned long long)failed_server_stats.kyproto_packets_dropped,
                    (unsigned long long)failed_client_stats.kyproto_packets_dropped);
        }
        print_error("native server", server);
        goto failure;
    }

    const size_t video_size = PLANK_LOOPBACK_VIDEO_BYTES;
    unsigned char *video = malloc(video_size);
    unsigned char *video_received = malloc(video_size);
    if (video == NULL || video_received == NULL) {
        fprintf(stderr, "failed to allocate video test buffers\n");
        free(video);
        free(video_received);
        goto failure;
    }
    for (size_t i = 0; i < video_size; ++i) {
        video[i] = (unsigned char)((i * 37u + 11u) & 0xffu);
    }
    PlankTransportNativeVideoFrameInfo video_info;
    memset(&video_info, 0, sizeof(video_info));
    video_info.struct_size = sizeof(video_info);
    video_info.codec = PLANK_TRANSPORT_NATIVE_VIDEO_CODEC_HEVC;
    video_info.flags = PLANK_TRANSPORT_NATIVE_VIDEO_FLAG_KEY;
    video_info.frame_number = 42;
    video_info.pts = 90000;
    video_info.host_processing_latency = 17;
    struct timespec video_started, video_completed;
    if (clock_gettime(CLOCK_MONOTONIC, &video_started) != 0) { abort(); }
    if (plank_transport_native_video_send(server, &video_info, video,
                                       video_size) != PLANK_TRANSPORT_OK) {
        fprintf(stderr, "failed to submit native video frame\n");
        free(video);
        free(video_received);
        goto failure;
    }
    PlankTransportNativeVideoFrameInfo received_video_info;
    memset(&received_video_info, 0, sizeof(received_video_info));
    received_video_info.struct_size = sizeof(received_video_info);
    size_t received_size = 0;
    int video_receive_result = plank_transport_native_video_receive(
            client, &received_video_info, video_received, video_size,
            &received_size, 5000);
    if (clock_gettime(CLOCK_MONOTONIC, &video_completed) != 0) { abort(); }
    printf("native_video_complete_us=%.3f video_bytes=%zu\n",
           (video_completed.tv_sec - video_started.tv_sec) * 1000000.0 +
           (video_completed.tv_nsec - video_started.tv_nsec) / 1000.0, video_size);
    if (video_receive_result != PLANK_TRANSPORT_OK ||
        received_size != video_size ||
        memcmp(video, video_received, video_size) != 0 ||
        received_video_info.codec != video_info.codec ||
        received_video_info.flags != video_info.flags ||
        received_video_info.frame_number != video_info.frame_number ||
        received_video_info.pts != video_info.pts ||
        received_video_info.host_processing_latency !=
            video_info.host_processing_latency) {
        fprintf(stderr,
                "native video mismatch: result=%d size=%zu/%zu bytes_equal=%d "
                "codec=%08x/%08x flags=%08x/%08x frame=%llu/%llu "
                "pts=%llu/%llu latency=%u/%u\n",
                video_receive_result, received_size, video_size,
                received_size == video_size &&
                    memcmp(video, video_received, video_size) == 0,
                received_video_info.codec, video_info.codec,
                received_video_info.flags, video_info.flags,
                (unsigned long long)received_video_info.frame_number,
                (unsigned long long)video_info.frame_number,
                (unsigned long long)received_video_info.pts,
                (unsigned long long)video_info.pts,
                received_video_info.host_processing_latency,
                video_info.host_processing_latency);
        print_error("native client", client);
        PlankTransportNativeStats video_server_stats;
        PlankTransportNativeStats video_client_stats;
        memset(&video_server_stats, 0, sizeof(video_server_stats));
        memset(&video_client_stats, 0, sizeof(video_client_stats));
        video_server_stats.struct_size = sizeof(video_server_stats);
        video_client_stats.struct_size = sizeof(video_client_stats);
        if (plank_transport_native_endpoint_stats(server, &video_server_stats) ==
                PLANK_TRANSPORT_OK &&
            plank_transport_native_endpoint_stats(client, &video_client_stats) ==
                PLANK_TRANSPORT_OK) {
            fprintf(stderr,
                    "native video counters: sent=%llu received=%llu "
                    "server_quic_lost=%llu client_quic_lost=%llu "
                    "server_kyproto_drops=%llu client_kyproto_drops=%llu\n",
                    (unsigned long long)video_server_stats.video_frames_sent,
                    (unsigned long long)video_client_stats.video_frames_received,
                    (unsigned long long)video_server_stats.quic_packets_lost,
                    (unsigned long long)video_client_stats.quic_packets_lost,
                    (unsigned long long)video_server_stats.kyproto_packets_dropped,
                    (unsigned long long)video_client_stats.kyproto_packets_dropped);
        }
        free(video);
        free(video_received);
        goto failure;
    }
    free(video);
    free(video_received);

    const unsigned char audio[] = "raw-opus-packet";
    unsigned char audio_received[sizeof(audio)];
    PlankTransportNativeAudioPacketInfo audio_info;
    memset(&audio_info, 0, sizeof(audio_info));
    audio_info.struct_size = sizeof(audio_info);
    audio_info.frame_samples = 240;
    audio_info.pts = 240;
    if (plank_transport_native_audio_send(server, &audio_info, audio,
                                       sizeof(audio)) != PLANK_TRANSPORT_OK) {
        fprintf(stderr, "failed to submit native audio packet\n");
        goto failure;
    }
    PlankTransportNativeAudioPacketInfo received_audio_info;
    memset(&received_audio_info, 0, sizeof(received_audio_info));
    received_audio_info.struct_size = sizeof(received_audio_info);
    received_size = 0;
    int audio_receive_result = plank_transport_native_audio_receive(
            client, &received_audio_info, audio_received,
            sizeof(audio_received), &received_size, 5000);
    if (audio_receive_result != PLANK_TRANSPORT_OK ||
        received_size != sizeof(audio) ||
        memcmp(audio, audio_received, sizeof(audio)) != 0 ||
        received_audio_info.frame_samples != audio_info.frame_samples ||
        received_audio_info.pts != audio_info.pts) {
        fprintf(stderr,
                "native audio mismatch: result=%d size=%zu/%zu bytes_equal=%d "
                "frame_samples=%u/%u pts=%llu/%llu missing_samples=%u\n",
                audio_receive_result, received_size, sizeof(audio),
                received_size == sizeof(audio) &&
                    memcmp(audio, audio_received, sizeof(audio)) == 0,
                received_audio_info.frame_samples, audio_info.frame_samples,
                (unsigned long long)received_audio_info.pts,
                (unsigned long long)audio_info.pts,
                received_audio_info.missing_samples);
        print_error("native audio client", client);
        print_error("native audio server", server);
        goto failure;
    }

    const unsigned char input[] = "wacom-tip-transition";
    unsigned char input_received[sizeof(input)];
    uint8_t input_type = 0;
    if (plank_transport_native_input_send(client, 7, input, sizeof(input)) !=
            PLANK_TRANSPORT_OK) {
        fprintf(stderr, "failed to submit native input packet\n");
        goto failure;
    }
    received_size = 0;
    if (plank_transport_native_input_receive(
            server, &input_type, input_received, sizeof(input_received),
            &received_size, 5000) != PLANK_TRANSPORT_OK ||
        input_type != 7 || received_size != sizeof(input) ||
        memcmp(input, input_received, sizeof(input)) != 0) {
        fprintf(stderr, "native input packet mismatch\n");
        goto failure;
    }

    const unsigned char client_data[] = "client-control";
    const unsigned char server_data[] = "server-control";
    unsigned char data_received[32];
    if (plank_transport_native_data_send(client, client_data,
                                      sizeof(client_data)) != PLANK_TRANSPORT_OK) {
        fprintf(stderr, "failed to submit client native data\n");
        goto failure;
    }
    received_size = 0;
    if (plank_transport_native_data_receive(
            server, data_received, sizeof(data_received), &received_size,
            5000) != PLANK_TRANSPORT_OK ||
        received_size != sizeof(client_data) ||
        memcmp(client_data, data_received, sizeof(client_data)) != 0) {
        fprintf(stderr, "client native data mismatch\n");
        goto failure;
    }
    if (plank_transport_native_data_send(server, server_data,
                                      sizeof(server_data)) != PLANK_TRANSPORT_OK) {
        fprintf(stderr, "failed to submit server native data\n");
        goto failure;
    }
    received_size = 0;
    if (plank_transport_native_data_receive(
            client, data_received, sizeof(data_received), &received_size,
            5000) != PLANK_TRANSPORT_OK ||
        received_size != sizeof(server_data) ||
        memcmp(server_data, data_received, sizeof(server_data)) != 0) {
        fprintf(stderr, "server native data mismatch\n");
        goto failure;
    }

    PlankTransportNativeStats server_stats;
    PlankTransportNativeStats client_stats;
    memset(&server_stats, 0, sizeof(server_stats));
    memset(&client_stats, 0, sizeof(client_stats));
    server_stats.struct_size = sizeof(server_stats);
    client_stats.struct_size = sizeof(client_stats);
    /* Reject mismatched local headers before writing any counters. */
    client_stats.struct_size -= sizeof(uint64_t);
    if (plank_transport_native_endpoint_stats(client, &client_stats) !=
            PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT) {
        fprintf(stderr, "native transport accepted the wrong stats ABI size\n");
        goto failure;
    }
    client_stats.struct_size = sizeof(client_stats);
    /* Reconstructed media can arrive before the sender finishes its repair
     * symbols and increments completion counters. Wait for that asynchronous
     * completion, bounded to two seconds; retain every exact assertion below. */
    unsigned int settle_attempt;
    const struct timespec settle_pause = {0, 10 * 1000 * 1000};
    for (settle_attempt = 0; settle_attempt < 200; ++settle_attempt) {
        if (plank_transport_native_endpoint_stats(server, &server_stats) !=
                PLANK_TRANSPORT_OK ||
            (server_stats.video_frames_sent >= 1 &&
             server_stats.audio_packets_sent >= 1)) {
            break;
        }
        nanosleep(&settle_pause, NULL);
    }
    printf("native_sender_counter_wait_iterations=%u\n", settle_attempt);
    /* Protocol statistics are sampled asynchronously. Require real FEC data,
     * not a default-zero field that would falsely pass a clean-loopback test. */
    for (settle_attempt = 0; settle_attempt < 200; ++settle_attempt) {
        if (plank_transport_native_endpoint_stats(client, &client_stats) !=
                PLANK_TRANSPORT_OK || client_stats.video_fec_source_symbols != 0) {
            break;
        }
        nanosleep(&settle_pause, NULL);
    }
    if (plank_transport_native_endpoint_stats(server, &server_stats) !=
            PLANK_TRANSPORT_OK ||
        plank_transport_native_endpoint_stats(client, &client_stats) !=
            PLANK_TRANSPORT_OK ||
        server_stats.video_frames_sent != 1 ||
        client_stats.video_frames_received != 1 ||
        server_stats.video_bytes_sent != video_size ||
        client_stats.video_bytes_received != video_size ||
        server_stats.audio_packets_sent != 1 ||
        client_stats.audio_packets_received != 1 ||
        client_stats.input_packets_sent != 1 ||
        server_stats.input_packets_received != 1 ||
        server_stats.data_packets_sent != 1 ||
        server_stats.data_packets_received != 1 ||
        client_stats.data_packets_sent != 1 ||
        client_stats.data_packets_received != 1 ||
        server_stats.video_send_drops != 0 ||
        client_stats.video_receive_drops != 0 ||
        server_stats.audio_send_drops != 0 ||
        client_stats.audio_receive_drops != 0 ||
        client_stats.kyproto_packets_dropped != 0 ||
        client_stats.video_fec_source_symbols == 0 ||
        client_stats.video_fec_source_symbols_missing > client_stats.video_fec_source_symbols ||
        client_stats.video_fec_source_symbols_unrecovered != 0) {
        fprintf(stderr, "native transport counters mismatch\n");
        fprintf(stderr,
                "video sent/received=%llu/%llu bytes=%llu/%llu "
                "audio=%llu/%llu input=%llu/%llu "
                "server data sent/received=%llu/%llu client data=%llu/%llu "
                "video drops=%llu/%llu audio drops=%llu/%llu kyproto drops=%llu\n",
                (unsigned long long)server_stats.video_frames_sent,
                (unsigned long long)client_stats.video_frames_received,
                (unsigned long long)server_stats.video_bytes_sent,
                (unsigned long long)client_stats.video_bytes_received,
                (unsigned long long)server_stats.audio_packets_sent,
                (unsigned long long)client_stats.audio_packets_received,
                (unsigned long long)client_stats.input_packets_sent,
                (unsigned long long)server_stats.input_packets_received,
                (unsigned long long)server_stats.data_packets_sent,
                (unsigned long long)server_stats.data_packets_received,
                (unsigned long long)client_stats.data_packets_sent,
                (unsigned long long)client_stats.data_packets_received,
                (unsigned long long)server_stats.video_send_drops,
                (unsigned long long)client_stats.video_receive_drops,
                (unsigned long long)server_stats.audio_send_drops,
                (unsigned long long)client_stats.audio_receive_drops,
                (unsigned long long)client_stats.kyproto_packets_dropped);
        goto failure;
    }

    /* A peer can exit at LoginWindow without another client input event.
     * Queued control (e.g. takeover) must precede the terminal receive error. */
    if (plank_transport_native_data_send(server, server_data, sizeof(server_data)) !=
            PLANK_TRANSPORT_OK) goto failure;
    for (settle_attempt = 0; settle_attempt < 200; ++settle_attempt) {
        if (plank_transport_native_endpoint_stats(client, &client_stats) != PLANK_TRANSPORT_OK)
            goto failure;
        if (client_stats.data_packets_received == 2) break;
        nanosleep(&settle_pause, NULL);
    }
    if (client_stats.data_packets_received != 2) goto failure;
    struct timespec closure_started;
    clock_gettime(CLOCK_MONOTONIC, &closure_started);
    plank_transport_native_endpoint_stop(server);
    if (plank_transport_native_data_receive(client, data_received, sizeof(data_received),
                &received_size, 5000) != PLANK_TRANSPORT_OK ||
            received_size != sizeof(server_data) ||
            memcmp(data_received, server_data, sizeof(server_data)) != 0) {
        fprintf(stderr, "queued control was lost before peer closure\n");
        goto failure;
    }
    int closure_result = PLANK_TRANSPORT_TIMEOUT;
    for (settle_attempt = 0; settle_attempt < 40; ++settle_attempt) {
        closure_result = plank_transport_native_data_receive(client, data_received,
                sizeof(data_received), &received_size, 50);
        if (closure_result != PLANK_TRANSPORT_TIMEOUT) break;
    }
    if (closure_result != PLANK_TRANSPORT_ERROR_RUNTIME) {
        fprintf(stderr, "peer closure did not reach control receiver: result=%d state=%u\n",
                closure_result, plank_transport_native_endpoint_state(client));
        print_error("peer closure", client);
        goto failure;
    }
    struct timespec closure_finished;
    clock_gettime(CLOCK_MONOTONIC, &closure_finished);
    double closure_ms = (closure_finished.tv_sec - closure_started.tv_sec) * 1000.0 +
                        (closure_finished.tv_nsec - closure_started.tv_nsec) / 1000000.0;
    if (closure_ms >= 2000.0) {
        fprintf(stderr, "orderly peer closure took %.3f ms (limit 2000 ms)\n", closure_ms);
        goto failure;
    }
    printf("native_peer_closure_without_input=pass queued_control_before_error=pass closure_ms=%.3f\n",
           closure_ms);
    plank_transport_native_endpoint_stop(client);
    plank_transport_native_endpoint_destroy(client);
    plank_transport_native_endpoint_destroy(server);
    printf("status=complete test=native-kyproto-ffi-loopback trust=%s "
           "video_frames=1 video_bytes=%zu audio_packets=1 input_packets=1 "
           "data_packets_each_direction=1 final_queued_control=1\n",
           profile_validation ? "profile" : "fingerprint", video_size);
    return 0;

failure:
    plank_transport_native_endpoint_destroy(client);
    plank_transport_native_endpoint_destroy(server);
    return 1;
}
