// SPDX-License-Identifier: AGPL-3.0-or-later
use super::*;
use std::ffi::CString;

fn collector(server: bool) -> (Arc<Reporter>, UdpSocket) {
    let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let config = PlankMetricsConfig {
        struct_size: size_of::<PlankMetricsConfig>() as u32,
        port: socket.local_addr().unwrap().port() as u32,
        interval_seconds: 1,
        workstation_id: c"WORKSTATION-TEST".as_ptr(),
        slot_id: c"bookmark-test".as_ptr(),
        version: c"1.4.11-test".as_ptr(),
    };
    (
        unsafe { Reporter::create(&config, server).unwrap() },
        socket,
    )
}

fn receive(socket: &UdpSocket) -> String {
    let mut bytes = [0; MAX_DATAGRAM + 1];
    let count = socket.recv(&mut bytes).unwrap();
    assert!(count <= MAX_DATAGRAM);
    String::from_utf8(bytes[..count].to_vec()).unwrap()
}

#[test]
fn escaping_types_and_size_bounds() {
    assert_eq!(tag("a b,c=d\\e"), "a\\ b\\,c\\=d\\\\e");
    let mut point = Point::new("test", "role=host");
    point.integer("count", 7);
    point.integer("too_big", u64::MAX);
    point.number("rate", 1.25);
    point.number("nan", f64::NAN);
    point.number("infinite", f64::INFINITY);
    point.boolean("connected", true);
    point.string("text", "a\"b\\c");
    assert_eq!(
        point.finish(123).unwrap(),
        "test,role=host count=7i,rate=1.250000,connected=true,text=\"a\\\"b\\\\c\" 123"
    );
    assert!(Point::new("empty", "role=host").finish(123).is_none());
    let mut large = Point::new("test", "role=host");
    large.string("text", &"x".repeat(MAX_DATAGRAM));
    assert!(large.finish(123).is_none());
    for value in ["", "bad\nvalue", "bad\rvalue", "bad\0value", "bad\u{7f}"] {
        assert!(checked_text(value).is_err());
    }
    assert!(checked_text(&"x".repeat(MAX_TEXT + 1)).is_err());
}

#[test]
fn invalid_configuration_is_rejected_without_io() {
    let (reporter, socket) = collector(false);
    let mut config = PlankMetricsConfig {
        struct_size: size_of::<PlankMetricsConfig>() as u32,
        port: 1023,
        interval_seconds: 1,
        workstation_id: c"workstation".as_ptr(),
        slot_id: c"bookmark".as_ptr(),
        version: c"test".as_ptr(),
    };
    assert!(unsafe { Reporter::create(&config, false) }.is_err());
    config.port = socket.local_addr().unwrap().port() as u32;
    for interval in [0, 61, u32::MAX] {
        config.interval_seconds = interval;
        assert!(unsafe { Reporter::create(&config, false) }.is_err());
    }
    config.interval_seconds = 1;
    config.workstation_id = std::ptr::null();
    assert!(unsafe { Reporter::create(&config, false) }.is_err());
    assert!(reporter.tags.contains("workstation_id=workstation-test"));
    assert!(socket.recv(&mut [0; 1]).is_err());
}

#[test]
fn rates_use_elapsed_time_and_do_not_reuse_reset_counters() {
    let (reporter, socket) = collector(false);
    let mut sampler = Sampler::new(reporter);
    let time = Instant::now();
    let mut stats = PlankTransportNativeStats::default();
    sampler.test_sample(stats, None, 0, time);
    assert!(!receive(&socket).contains("video_receive_mbps="));
    assert!(receive(&socket).contains("event=\"ready\""));
    stats.video_bytes_received = 3_000_000;
    stats.video_frames_received = 120;
    stats.quic_rtt_us = 25_500;
    stats.video_fec_source_symbols = 1000;
    stats.video_fec_source_symbols_missing = 20;
    stats.video_fec_source_symbols_unrecovered = 1;
    sampler.test_sample(stats, None, 0, time + Duration::from_secs(2));
    let sample = receive(&socket);
    for field in [
        "video_receive_mbps=12.000000",
        "video_receive_fps=60.000000",
        "rtt_ms=25.500000",
        "video_loss_before_fec_percent=2.000000",
        "video_loss_after_fec_percent=0.100000",
    ] {
        assert!(sample.contains(field), "{sample}");
    }
    sampler.test_sample(stats, None, 0, time + Duration::from_millis(2500));
    assert!(socket.recv(&mut [0; 1]).is_err());
    sampler.test_sample(
        PlankTransportNativeStats::default(),
        None,
        0,
        time + Duration::from_secs(4),
    );
    let reset = receive(&socket);
    assert!(
        !reset.contains("video_receive_mbps=") && !reset.contains("video_loss_before_fec_percent=")
    );
    assert!(fec_percent(&stats, &stats).is_none());
    stats.video_fec_source_symbols_missing = 1001;
    assert!(fec_percent(&stats, &PlankTransportNativeStats::default()).is_none());
}

#[test]
fn media_windows_aggregate_once_and_contention_never_waits() {
    let (reporter, socket) = collector(false);
    let window = PlankMetricsClientVideo {
        struct_size: size_of::<PlankMetricsClientVideo>() as u32,
        hardware_decoder: 1,
        window_seconds: 1.0,
        received_frames: 60,
        decoded_frames: 60,
        rendered_frames: 59,
        decode_time_ms: 180.0,
        render_queue_time_ms: 59.0,
        render_time_ms: 118.0,
        render_dropped_frames: 1,
        ..Default::default()
    };
    assert_eq!(reporter.client_video(&window), Ok(true));
    assert_eq!(reporter.client_video(&window), Ok(true));
    let guard = reporter.cache.lock().unwrap();
    assert_eq!(reporter.client_video(&window), Ok(false));
    drop(guard);
    assert_eq!(reporter.observations_dropped.load(Ordering::Relaxed), 1);
    let mut sampler = Sampler::new(reporter.clone());
    let time = Instant::now();
    sampler.test_sample(PlankTransportNativeStats::default(), None, 0, time);
    let media = receive(&socket);
    for field in [
        "plank_client_video,",
        "window_seconds=2.000000",
        "decode_fps=60.000000",
        "render_fps=59.000000",
        "decode_ms=3.000000",
        "render_ms=2.000000",
        "render_queue_ms=1.000000",
        "render_dropped_frames=2i",
        "hardware_decoder=true",
    ] {
        assert!(media.contains(field), "{media}");
    }
    receive(&socket);
    receive(&socket);
    sampler.test_sample(
        PlankTransportNativeStats::default(),
        None,
        0,
        time + Duration::from_secs(1),
    );
    assert!(receive(&socket).starts_with("plank_transport,"));
    assert!(socket.recv(&mut [0; 1]).is_err());
    let mut invalid = window;
    invalid.decode_time_ms = f64::NAN;
    assert!(reporter.client_video(&invalid).is_err());
    reporter.finish(false);
    assert!(receive(&socket).contains("event=\"stopped\""));
    assert_eq!(reporter.client_video(&window), Ok(false));
    reporter.finish(true);
    assert!(socket.recv(&mut [0; 1]).is_err());
}

#[test]
fn collector_absence_or_not_reading_does_not_block() {
    let (reporter, socket) = collector(true);
    let start = Instant::now();
    for _ in 0..5000 {
        reporter.event("ready");
    }
    drop(socket);
    for _ in 0..5000 {
        reporter.event("ready");
    }
    reporter.finish(false);
    assert!(start.elapsed() < Duration::from_secs(5));
}

// The standalone Telegraf integration runner requests this fixture file. All
// lines come through the real exporter and localhost UDP, not a second encoder.
#[test]
fn telegraf_fixture_serialization() {
    let (reporter, socket) = collector(true);
    let escaped = CString::new("native x11,=\\ test").unwrap();
    let info = PlankMetricsStreamInfo {
        struct_size: size_of::<PlankMetricsStreamInfo>() as u32,
        width: 5120,
        height: 2160,
        requested_fps: 60,
        capture_source: escaped.as_ptr(),
        encoding_profile: c"hevc-10-444-nvenc".as_ptr(),
    };
    unsafe {
        reporter.stream_info(&info).unwrap();
    }
    let mut sampler = Sampler::new(reporter.clone());
    let time = Instant::now();
    let stats = PlankTransportNativeStats::default();
    let mut lines = Vec::new();
    reporter.event("created");
    lines.push(receive(&socket));
    sampler.test_sample(stats, Some(QueueDepths::default()), 150_000_000, time);
    lines.push(receive(&socket));
    lines.push(receive(&socket));
    reporter.host_video(25);
    reporter.host_video(35);
    sampler.test_sample(
        PlankTransportNativeStats {
            video_bytes_sent: 18_750_000,
            video_frames_sent: 60,
            ..stats
        },
        Some(QueueDepths::default()),
        150_000_000,
        time + Duration::from_secs(1),
    );
    let host = receive(&socket);
    assert!(host.contains("host_processing_mean_ms=3.000000"));
    assert!(host.contains("host_processing_max_ms=3.500000"));
    assert!(!host.contains("video_loss_before_fec_percent="));
    lines.push(host);
    reporter.finish(false);
    lines.push(receive(&socket));
    let (client, client_socket) = collector(false);
    let client_info = PlankMetricsStreamInfo {
        encoding_profile: c"hevc-10-444-nvenc".as_ptr(),
        ..info
    };
    unsafe {
        client.stream_info(&client_info).unwrap();
    }
    client
        .client_video(&PlankMetricsClientVideo {
            struct_size: size_of::<PlankMetricsClientVideo>() as u32,
            hardware_decoder: 1,
            window_seconds: 1.0,
            received_frames: 60,
            decoded_frames: 60,
            rendered_frames: 60,
            decode_time_ms: 120.0,
            render_time_ms: 60.0,
            ..Default::default()
        })
        .unwrap();
    Sampler::new(client).test_sample(stats, Some(QueueDepths::default()), 0, time);
    for _ in 0..3 {
        lines.push(receive(&client_socket));
    }
    if let Some(path) = std::env::var_os("PLANK_METRICS_FIXTURE_OUTPUT") {
        std::fs::write(path, lines.join("\n") + "\n").unwrap();
    }
}

impl Sampler {
    fn test_sample(
        &mut self,
        stats: PlankTransportNativeStats,
        queues: Option<QueueDepths>,
        target: u64,
        time: Instant,
    ) {
        self.sample_at(stats, queues, target, time, time);
    }
}

#[test]
fn scheduler_jitter_does_not_skip_the_next_sample() {
    let (reporter, socket) = collector(false);
    let mut sampler = Sampler::new(reporter);
    let tick = Instant::now();
    sampler.sample_at(
        PlankTransportNativeStats::default(),
        None,
        0,
        tick + Duration::from_millis(5),
        tick,
    );
    receive(&socket);
    receive(&socket);
    sampler.sample_at(
        PlankTransportNativeStats {
            video_frames_received: 60,
            ..Default::default()
        },
        None,
        0,
        tick + Duration::from_millis(1001),
        tick + Duration::from_secs(1),
    );
    let sample = receive(&socket);
    assert!(
        sample.contains("interval_seconds=0.996000")
            && sample.contains("video_receive_fps=60.240964")
    );
}

#[test]
fn host_accumulator_uses_its_actual_window_after_contention() {
    let (reporter, socket) = collector(true);
    let mut sampler = Sampler::new(reporter.clone());
    let time = Instant::now();
    sampler.test_sample(PlankTransportNativeStats::default(), None, 0, time);
    receive(&socket);
    receive(&socket);
    reporter.host_video(10);
    let guard = reporter.cache.lock().unwrap();
    sampler.test_sample(
        PlankTransportNativeStats::default(),
        None,
        0,
        time + Duration::from_secs(1),
    );
    assert!(!receive(&socket).contains("video_submit_fps="));
    drop(guard);
    reporter.host_video(30);
    sampler.test_sample(
        PlankTransportNativeStats::default(),
        None,
        0,
        time + Duration::from_secs(2),
    );
    let sample = receive(&socket);
    assert!(sample.contains("host_window_seconds=2.000000"));
    assert!(sample.contains("video_submit_fps=1.000000"));
    assert!(sample.contains("host_processing_mean_ms=2.000000"));
}
