/* SPDX-License-Identifier: AGPL-3.0-or-later */
#ifndef PLANK_METRICS_H
#define PLANK_METRICS_H

#include "plank_transport.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PlankMetricsHandle PlankMetricsHandle;

/* Optional observability only. Destination is always IPv4 localhost.
 * Strings are copied by configure; never supply credentials or usernames.
 * Role is derived from the endpoint, and Telegraf supplies its local host tag. */
typedef struct PlankMetricsConfig {
    uint32_t struct_size;
    uint32_t port;
    uint32_t interval_seconds;
    const char *workstation_id;
    const char *slot_id;
    const char *version;
} PlankMetricsConfig;

typedef struct PlankMetricsStreamInfo {
    uint32_t struct_size;
    uint32_t width;
    uint32_t height;
    uint32_t requested_fps;
    const char *capture_source;
    const char *encoding_profile;
} PlankMetricsStreamInfo;

/* One actual decoder statistics window, not the smoothed overlay values.
 * Raw counts/sums allow a longer export interval without losing observations.
 * Timings are sums in milliseconds. Hardware is 0/1; -1 means unknown. */
typedef struct PlankMetricsClientVideo {
    uint32_t struct_size;
    int32_t hardware_decoder;
    double window_seconds;
    uint64_t received_frames;
    uint64_t decoded_frames;
    uint64_t rendered_frames;
    uint64_t network_dropped_frames;
    uint64_t render_dropped_frames;
    uint64_t overflow_dropped_frames;
    double decode_time_ms;
    double render_queue_time_ms;
    double render_time_ms;
    uint64_t host_latency_samples;
    double host_latency_time_ms;
} PlankMetricsClientVideo;

/* Aggregate pen activity during an active Client session. No coordinates,
 * pressure values, tool identifiers or stroke contents are accepted here.
 * observed is 0/1 and describes whether the pen source is currently monitored. */
typedef struct PlankMetricsPenActivity {
    uint32_t struct_size;
    uint32_t observed;
    uint64_t motion_events;
    uint64_t tip_down_events;
} PlankMetricsPenActivity;

/* Configure once before start. An optional handle lets the Client publish media
 * windows without holding a transport pointer across reconnect/teardown.
 * Metrics errors must never reject a PLANK session. No API here performs remote
 * HTTP, DNS, disk I/O, retry, or an unbounded socket write. */
int32_t plank_transport_native_metrics_configure(PlankTransportNativeEndpoint *endpoint,
    const PlankMetricsConfig *config, PlankMetricsHandle **handle_out);
int32_t plank_transport_native_metrics_stream_info(PlankTransportNativeEndpoint *endpoint,
    const PlankMetricsStreamInfo *info);
int32_t plank_metrics_client_video(PlankMetricsHandle *handle,
    const PlankMetricsClientVideo *window);
int32_t plank_metrics_pen_activity(PlankMetricsHandle *handle,
    const PlankMetricsPenActivity *activity);
/* Destroy only after callers publishing through this handle have drained.
 * Endpoint sampling retains its own reference; shutdown does not join a new
 * metrics thread or wait for Telegraf. Null is accepted. */
void plank_metrics_destroy(PlankMetricsHandle *handle);

#ifdef __cplusplus
}
#endif
#endif
