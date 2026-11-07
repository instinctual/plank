// SPDX-License-Identifier: AGPL-3.0-or-later
//! Optional, bounded localhost Telegraf output. This is never a transport lane.
use crate::native_ffi::PlankTransportNativeStats;
use std::ffi::{CStr, c_char};
use std::fmt::Write;
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_DATAGRAM: usize = 4096;
const MAX_TEXT: usize = 128;

#[cfg(test)]
#[path = "metrics_tests.rs"]
mod tests;

#[repr(C)]
pub struct PlankMetricsConfig {
    pub struct_size: u32,
    pub port: u32,
    pub interval_seconds: u32,
    pub workstation_id: *const c_char,
    pub slot_id: *const c_char,
    pub version: *const c_char,
}

#[repr(C)]
pub struct PlankMetricsStreamInfo {
    pub struct_size: u32,
    pub width: u32,
    pub height: u32,
    pub requested_fps: u32,
    pub capture_source: *const c_char,
    pub encoding_profile: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct PlankMetricsClientVideo {
    pub struct_size: u32,
    pub hardware_decoder: i32,
    pub window_seconds: f64,
    pub received_frames: u64,
    pub decoded_frames: u64,
    pub rendered_frames: u64,
    pub network_dropped_frames: u64,
    pub render_dropped_frames: u64,
    pub overflow_dropped_frames: u64,
    pub decode_time_ms: f64,
    pub render_queue_time_ms: f64,
    pub render_time_ms: f64,
    pub host_latency_samples: u64,
    pub host_latency_time_ms: f64,
}

pub struct PlankMetricsHandle(pub(crate) Arc<Reporter>);

#[derive(Clone)]
struct StreamInfo {
    width: u32,
    height: u32,
    fps: u32,
    capture: String,
    profile: String,
}

#[derive(Default)]
struct HostWindow {
    submissions: u64,
    latency_count: u64,
    latency_sum_us: u64,
    latency_max_us: u64,
    latency_clamped: u64,
}

#[derive(Default)]
struct Cache {
    info: Option<StreamInfo>,
    client: Option<PlankMetricsClientVideo>,
    client_updated: Option<Instant>,
    host: HostWindow,
}

#[derive(Clone, Copy, Default)]
pub(crate) struct QueueDepths {
    pub video_send_frames: u64,
    pub video_send_bytes: u64,
    pub video_receive_frames: u64,
    pub video_receive_bytes: u64,
    pub audio_send_packets: u64,
    pub audio_receive_packets: u64,
    pub reliable_send_packets: u64,
    pub reliable_send_bytes: u64,
    pub reliable_receive_packets: u64,
    pub reliable_receive_bytes: u64,
}

pub(crate) struct Reporter {
    socket: UdpSocket,
    tags: String,
    version: String,
    interval: Duration,
    server: bool,
    started_ns: u64,
    cache: Mutex<Cache>,
    observations_dropped: AtomicU64,
    send_errors: AtomicU64,
    finished: AtomicBool,
}

fn unix_ns() -> Option<u64> {
    let value = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_nanos();
    (value <= i64::MAX as u128).then_some(value as u64)
}

fn checked_text(value: &str) -> Result<String, ()> {
    if value.is_empty() || value.len() > MAX_TEXT || value.chars().any(char::is_control) {
        return Err(());
    }
    Ok(value.to_owned())
}

unsafe fn text_from_c(value: *const c_char) -> Result<String, ()> {
    if value.is_null() {
        return Err(());
    }
    checked_text(unsafe { CStr::from_ptr(value) }.to_str().map_err(|_| ())?)
}

fn tag(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for c in value.chars() {
        if matches!(c, '\\' | ',' | '=' | ' ') {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    escaped
}

struct Point {
    text: String,
    fields: usize,
}

impl Point {
    fn new(measurement: &str, tags: &str) -> Self {
        Self {
            text: format!("{measurement},{tags} "),
            fields: 0,
        }
    }
    fn key(&mut self, name: &str) {
        if self.fields != 0 {
            self.text.push(',');
        }
        self.fields += 1;
        self.text.push_str(name);
        self.text.push('=');
    }
    fn integer(&mut self, key: &str, value: u64) {
        // Telegraf's existing v2 output defaults to signed integer support.
        if value > i64::MAX as u64 {
            return;
        }
        self.key(key);
        let _ = write!(self.text, "{value}i");
    }
    fn number(&mut self, key: &str, value: f64) {
        if !value.is_finite() {
            return;
        }
        self.key(key);
        let _ = write!(self.text, "{value:.6}");
    }
    fn boolean(&mut self, key: &str, value: bool) {
        self.key(key);
        self.text.push_str(if value { "true" } else { "false" });
    }
    fn string(&mut self, key: &str, value: &str) {
        self.key(key);
        self.text.push('"');
        for c in value.chars() {
            if matches!(c, '\\' | '"') {
                self.text.push('\\');
            }
            self.text.push(c);
        }
        self.text.push('"');
    }
    fn finish(mut self, timestamp: u64) -> Option<String> {
        if self.fields == 0 || timestamp > i64::MAX as u64 {
            return None;
        }
        let _ = write!(self.text, " {timestamp}");
        (self.text.len() <= MAX_DATAGRAM).then_some(self.text)
    }
}

impl Reporter {
    /// Caller provides readable, NUL-terminated strings for this call only.
    pub(crate) unsafe fn create(
        config: &PlankMetricsConfig,
        server: bool,
    ) -> Result<Arc<Self>, ()> {
        if config.struct_size as usize != size_of::<PlankMetricsConfig>()
            || !(1024..=65535).contains(&config.port)
            || !(1..=60).contains(&config.interval_seconds)
        {
            return Err(());
        }
        let workstation = unsafe { text_from_c(config.workstation_id) }?.to_ascii_lowercase();
        let slot = unsafe { text_from_c(config.slot_id) }?;
        let version = unsafe { text_from_c(config.version) }?;
        let socket = UdpSocket::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0)).map_err(|_| ())?;
        socket.set_nonblocking(true).map_err(|_| ())?;
        socket
            .connect(SocketAddrV4::new(Ipv4Addr::LOCALHOST, config.port as u16))
            .map_err(|_| ())?;
        let role = if server { "host" } else { "client" };
        let reporter = Arc::new(Self {
            socket,
            tags: format!(
                "role={role},slot_id={},workstation_id={}",
                tag(&slot),
                tag(&workstation)
            ),
            version,
            interval: Duration::from_secs(config.interval_seconds as u64),
            server,
            started_ns: unix_ns().ok_or(())?,
            cache: Mutex::new(Cache::default()),
            observations_dropped: AtomicU64::new(0),
            send_errors: AtomicU64::new(0),
            finished: AtomicBool::new(false),
        });
        Ok(reporter)
    }

    fn point(&self, measurement: &str) -> Point {
        let mut point = Point::new(measurement, &self.tags);
        point.integer("connection_started_ns", self.started_ns);
        point.string("version", &self.version);
        point
    }

    fn send(&self, point: Point) {
        let packet = unix_ns().and_then(|timestamp| point.finish(timestamp));
        if packet
            .as_ref()
            .is_none_or(|value| self.socket.send(value.as_bytes()).ok() != Some(value.len()))
        {
            self.send_errors.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub(crate) fn event(&self, name: &str) {
        let mut point = self.point("plank_session");
        point.string("event", name);
        self.send(point);
    }

    pub(crate) fn finish(&self, failed: bool) {
        if !self.finished.swap(true, Ordering::AcqRel) {
            self.event(if failed { "failed" } else { "stopped" });
        }
    }

    /// No lock is retained while formatting or sending datagrams.
    pub(crate) unsafe fn stream_info(&self, info: &PlankMetricsStreamInfo) -> Result<(), ()> {
        if info.struct_size as usize != size_of::<PlankMetricsStreamInfo>()
            || !(1..=65535).contains(&info.width)
            || !(1..=65535).contains(&info.height)
            || !(1..=1000).contains(&info.requested_fps)
        {
            return Err(());
        }
        let value = StreamInfo {
            width: info.width,
            height: info.height,
            fps: info.requested_fps,
            capture: unsafe { text_from_c(info.capture_source) }?,
            profile: unsafe { text_from_c(info.encoding_profile) }?,
        };
        self.cache.lock().map_err(|_| ())?.info = Some(value);
        Ok(())
    }

    pub(crate) fn client_video(&self, value: &PlankMetricsClientVideo) -> Result<bool, ()> {
        if self.server
            || value.struct_size as usize != size_of::<PlankMetricsClientVideo>()
            || !(-1..=1).contains(&value.hardware_decoder)
            || !value.window_seconds.is_finite()
            || !(0.000001..=3600.0).contains(&value.window_seconds)
            || [
                value.decode_time_ms,
                value.render_queue_time_ms,
                value.render_time_ms,
                value.host_latency_time_ms,
            ]
            .iter()
            .any(|v| !v.is_finite() || *v < 0.0)
        {
            return Err(());
        }
        if self.finished.load(Ordering::Acquire) {
            return Ok(false);
        }
        let Ok(mut cache) = self.cache.try_lock() else {
            self.observations_dropped.fetch_add(1, Ordering::Relaxed);
            return Ok(false);
        };
        let total = cache.client.get_or_insert_with(|| PlankMetricsClientVideo {
            hardware_decoder: -1,
            ..Default::default()
        });
        total.hardware_decoder = value.hardware_decoder;
        total.window_seconds += value.window_seconds;
        macro_rules! add { ($($field:ident),+ $(,)?) => { $(total.$field = total.$field.saturating_add(value.$field);)+ }; }
        add!(
            received_frames,
            decoded_frames,
            rendered_frames,
            network_dropped_frames,
            render_dropped_frames,
            overflow_dropped_frames,
            host_latency_samples
        );
        total.decode_time_ms += value.decode_time_ms;
        total.render_queue_time_ms += value.render_queue_time_ms;
        total.render_time_ms += value.render_time_ms;
        total.host_latency_time_ms += value.host_latency_time_ms;
        cache.client_updated = Some(Instant::now());
        Ok(true)
    }

    pub(crate) fn host_video(&self, latency_tenths_ms: u16) {
        if !self.server || self.finished.load(Ordering::Acquire) {
            return;
        }
        if let Ok(mut cache) = self.cache.try_lock() {
            cache.host.submissions += 1;
            if latency_tenths_ms != 0 {
                let us = u64::from(latency_tenths_ms) * 100;
                cache.host.latency_count += 1;
                cache.host.latency_sum_us += us;
                cache.host.latency_max_us = cache.host.latency_max_us.max(us);
                cache.host.latency_clamped += u64::from(latency_tenths_ms == u16::MAX);
            }
        } else {
            self.observations_dropped.fetch_add(1, Ordering::Relaxed);
        }
    }
}

pub(crate) struct Sampler {
    reporter: Arc<Reporter>,
    previous: Option<(PlankTransportNativeStats, Instant)>,
    next_tick: Option<Instant>,
    host_previous: Option<Instant>,
}

fn delta(current: u64, previous: u64) -> Option<u64> {
    current.checked_sub(previous)
}

fn fec_percent(
    current: &PlankTransportNativeStats,
    previous: &PlankTransportNativeStats,
) -> Option<(f64, f64)> {
    let source = delta(
        current.video_fec_source_symbols,
        previous.video_fec_source_symbols,
    )?;
    let missing = delta(
        current.video_fec_source_symbols_missing,
        previous.video_fec_source_symbols_missing,
    )?;
    let residual = delta(
        current.video_fec_source_symbols_unrecovered,
        previous.video_fec_source_symbols_unrecovered,
    )?;
    if source == 0 || missing > source || residual > missing {
        return None;
    }
    Some((
        missing as f64 * 100.0 / source as f64,
        residual as f64 * 100.0 / source as f64,
    ))
}

impl Sampler {
    pub(crate) fn new(reporter: Arc<Reporter>) -> Self {
        Self {
            reporter,
            previous: None,
            next_tick: None,
            host_previous: None,
        }
    }

    pub(crate) fn sample(
        &mut self,
        stats: PlankTransportNativeStats,
        queues: Option<QueueDepths>,
        target_bps: u64,
        scheduled: Instant,
    ) {
        self.sample_at(stats, queues, target_bps, Instant::now(), scheduled);
    }

    fn sample_at(
        &mut self,
        stats: PlankTransportNativeStats,
        queues: Option<QueueDepths>,
        target_bps: u64,
        now: Instant,
        scheduled: Instant,
    ) {
        let r = &self.reporter;
        if r.finished.load(Ordering::Acquire) || self.next_tick.is_some_and(|next| scheduled < next)
        {
            return;
        }
        let first = self.previous.is_none();
        let mut point = r.point("plank_transport");
        point.boolean("connected", true);
        point.integer("export_errors_total", r.send_errors.load(Ordering::Relaxed));
        point.integer(
            "observation_drops_total",
            r.observations_dropped.load(Ordering::Relaxed),
        );
        if stats.quic_rtt_us != 0 {
            point.number("rtt_ms", stats.quic_rtt_us as f64 / 1000.0);
        }
        if r.server && target_bps != 0 {
            point.number("encoder_target_mbps", target_bps as f64 / 1_000_000.0);
        }
        macro_rules! counters { ($($field:ident),+ $(,)?) => { $(point.integer(concat!(stringify!($field), "_total"), stats.$field);)+ }; }
        counters!(
            video_frames_sent,
            video_bytes_sent,
            video_frames_received,
            video_bytes_received,
            video_send_drops,
            video_receive_drops,
            audio_packets_sent,
            audio_bytes_sent,
            audio_packets_received,
            audio_bytes_received,
            audio_send_drops,
            audio_receive_drops,
            input_packets_sent,
            input_packets_received,
            data_packets_sent,
            data_packets_received,
            quic_packets_lost,
            kyproto_packets_dropped
        );
        if !r.server {
            counters!(
                video_fec_source_symbols,
                video_fec_source_symbols_missing,
                video_fec_source_symbols_unrecovered
            );
        }
        let elapsed = self
            .previous
            .as_ref()
            .map(|(_, time)| now.duration_since(*time).as_secs_f64());
        if let Some((old, _)) = self.previous.as_ref() {
            let seconds = elapsed.unwrap();
            point.number("interval_seconds", seconds);
            for (name, current, previous, scale) in [
                (
                    "video_send_mbps",
                    stats.video_bytes_sent,
                    old.video_bytes_sent,
                    8.0 / 1_000_000.0,
                ),
                (
                    "video_receive_mbps",
                    stats.video_bytes_received,
                    old.video_bytes_received,
                    8.0 / 1_000_000.0,
                ),
                (
                    "video_send_fps",
                    stats.video_frames_sent,
                    old.video_frames_sent,
                    1.0,
                ),
                (
                    "video_receive_fps",
                    stats.video_frames_received,
                    old.video_frames_received,
                    1.0,
                ),
                (
                    "audio_send_kbps",
                    stats.audio_bytes_sent,
                    old.audio_bytes_sent,
                    8.0 / 1000.0,
                ),
                (
                    "audio_receive_kbps",
                    stats.audio_bytes_received,
                    old.audio_bytes_received,
                    8.0 / 1000.0,
                ),
            ] {
                if let Some(change) = delta(current, previous) {
                    point.number(name, change as f64 * scale / seconds);
                }
            }
            macro_rules! changes { ($($field:ident),+ $(,)?) => { $(
                if let Some(change) = delta(stats.$field, old.$field) {
                    point.integer(concat!(stringify!($field), "_interval"), change);
                }
            )+ }; }
            changes!(
                video_send_drops,
                video_receive_drops,
                audio_send_drops,
                audio_receive_drops,
                quic_packets_lost,
                kyproto_packets_dropped
            );
            if !r.server
                && let Some((before, after)) = fec_percent(&stats, old)
            {
                point.number("video_loss_before_fec_percent", before);
                point.number("video_loss_after_fec_percent", after);
                changes!(
                    video_fec_source_symbols,
                    video_fec_source_symbols_missing,
                    video_fec_source_symbols_unrecovered
                );
            }
        }
        if let Some(depths) = queues {
            macro_rules! queue_fields { ($($field:ident),+ $(,)?) => { $(point.integer(concat!(stringify!($field), "_queued"), depths.$field);)+ }; }
            queue_fields!(
                video_send_frames,
                video_send_bytes,
                video_receive_frames,
                video_receive_bytes,
                audio_send_packets,
                audio_receive_packets,
                reliable_send_packets,
                reliable_send_bytes,
                reliable_receive_packets,
                reliable_receive_bytes
            );
        }
        let observation = r.cache.try_lock().ok().map(|mut cache| {
            (
                cache.info.clone(),
                cache.client.take(),
                cache.client_updated,
                std::mem::take(&mut cache.host),
            )
        });
        // All application, endpoint and cache locks are released before I/O.
        if let Some((info, client, updated, host)) = observation {
            if let Some(info) = info {
                point.integer("width", info.width as u64);
                point.integer("height", info.height as u64);
                point.integer("requested_fps", info.fps as u64);
                point.string("capture_source", &info.capture);
                point.string("encoding_profile", &info.profile);
            }
            if let Some(updated) = updated {
                point.number(
                    "client_video_age_seconds",
                    now.saturating_duration_since(updated).as_secs_f64(),
                );
            }
            if r.server {
                point.integer("video_submissions_interval", host.submissions);
                if let Some(previous) = self.host_previous {
                    let seconds = now.duration_since(previous).as_secs_f64();
                    point.number("host_window_seconds", seconds);
                    point.number("video_submit_fps", host.submissions as f64 / seconds);
                }
                self.host_previous = Some(now);
                if host.latency_count != 0 {
                    point.integer("processing_samples_interval", host.latency_count);
                    point.number(
                        "host_processing_mean_ms",
                        host.latency_sum_us as f64 / host.latency_count as f64 / 1000.0,
                    );
                    point.number(
                        "host_processing_max_ms",
                        host.latency_max_us as f64 / 1000.0,
                    );
                    point.integer("processing_clamped_interval", host.latency_clamped);
                }
            }
            if let Some(client) = client {
                let mut media = r.point("plank_client_video");
                media.number("window_seconds", client.window_seconds);
                if client.hardware_decoder >= 0 {
                    media.boolean("hardware_decoder", client.hardware_decoder != 0);
                }
                media.number(
                    "network_fps",
                    client.received_frames as f64 / client.window_seconds,
                );
                media.number(
                    "decode_fps",
                    client.decoded_frames as f64 / client.window_seconds,
                );
                media.number(
                    "render_fps",
                    client.rendered_frames as f64 / client.window_seconds,
                );
                media.integer("network_dropped_frames", client.network_dropped_frames);
                media.integer("render_dropped_frames", client.render_dropped_frames);
                media.integer("overflow_dropped_frames", client.overflow_dropped_frames);
                if client.decoded_frames != 0 {
                    media.number(
                        "decode_ms",
                        client.decode_time_ms / client.decoded_frames as f64,
                    );
                }
                if client.rendered_frames != 0 {
                    media.number(
                        "render_queue_ms",
                        client.render_queue_time_ms / client.rendered_frames as f64,
                    );
                    media.number(
                        "render_ms",
                        client.render_time_ms / client.rendered_frames as f64,
                    );
                }
                if client.host_latency_samples != 0 {
                    media.number(
                        "host_processing_ms",
                        client.host_latency_time_ms / client.host_latency_samples as f64,
                    );
                }
                r.send(media);
            }
        }
        r.send(point);
        if first {
            r.event("ready");
        }
        self.previous = Some((stats, now));
        // Use the existing timer's scheduled ticks for cadence, and actual
        // monotonic elapsed time for rates. Sub-millisecond scheduler jitter
        // must not accidentally turn a one-second interval into two seconds.
        self.next_tick = Some(scheduled + r.interval);
    }
}

/// # Safety
/// Handle and window must remain live during the call; destroy requires exclusive ownership.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_metrics_client_video(
    handle: *mut PlankMetricsHandle,
    window: *const PlankMetricsClientVideo,
) -> i32 {
    crate::catch_result(|| {
        let (Some(handle), Some(window)) = (unsafe { handle.as_ref() }, unsafe { window.as_ref() })
        else {
            return crate::PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        match handle.0.client_video(window) {
            Ok(true) => crate::PLANK_TRANSPORT_OK,
            Ok(false) => crate::PLANK_TRANSPORT_DROPPED,
            Err(()) => crate::PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT,
        }
    })
}

/// # Safety
/// Handle is null or was returned once by configure and is no longer being used by a caller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_metrics_destroy(handle: *mut PlankMetricsHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}
