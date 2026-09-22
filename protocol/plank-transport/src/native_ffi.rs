// SPDX-License-Identifier: AGPL-3.0-or-later

//! Bounded synchronous C ABI for the KyProto-native PLANK data plane.

use super::native::{self, NativeClientProtocols, NativeOptions, NativeServerProtocols};
use super::{
    EndpointConfig, EndpointState, PLANK_TRANSPORT_DROPPED, PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL,
    PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT, PLANK_TRANSPORT_ERROR_INVALID_STATE,
    PLANK_TRANSPORT_ERROR_PANIC, PLANK_TRANSPORT_ERROR_RUNTIME, PLANK_TRANSPORT_OK,
    PLANK_TRANSPORT_TIMEOUT, PlankTransportConfig, catch_result, init_crypto_once, parse_config,
};
use crate::rate_control::{PlankRateControllerFactory, TransportRatePolicy};
use anyhow::{Context, Result, anyhow};
use bytes::{BufMut, Bytes, BytesMut};
use kymux_types::{
    AVPacket, CodecPacket, CodecPacketHeader, DataPacket, InputPacket, MAX_DATA_PACKET_SIZE,
    MediaPacket, MediaPacketHeader,
};
use kynet::Server;
use std::collections::VecDeque;
use std::ffi::c_char;
use std::future::Future;
use std::path::Path;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[cfg(feature = "sender-timing")]
#[path = "sender_trace.rs"]
mod sender_trace;

const VIDEO_SEND_CAPACITY: usize = 4;
const VIDEO_RECEIVE_CAPACITY: usize = 16;
const AUDIO_SEND_CAPACITY: usize = 16;
const AUDIO_RECEIVE_CAPACITY: usize = 64;
const INPUT_SEND_CAPACITY: usize = 128;
const INPUT_RECEIVE_CAPACITY: usize = 128;
const DATA_QUEUE_PACKET_CAPACITY: usize = 64;
const DATA_QUEUE_BYTE_CAPACITY: usize = 8 * 1024 * 1024;
const MAX_VIDEO_FRAME_SIZE: usize = 64 * 1024 * 1024;
const MAX_AUDIO_PACKET_SIZE: usize = 64 * 1024;
const MAX_INPUT_PACKET_SIZE: usize = u16::MAX as usize;
const VIDEO_METADATA_SIZE: usize = 16;
const VIDEO_FLAG_KEY: u32 = 1;
const VIDEO_CODEC_H264: u32 = u32::from_be_bytes(*b"H264");
const VIDEO_CODEC_HEVC: u32 = u32::from_be_bytes(*b"HEVC");
const AUDIO_CODEC_OPUS: u32 = u32::from_be_bytes(*b"OPUS");
const CONNECTION_CLOSE_DRAIN: Duration = Duration::from_secs(1);

#[cfg(test)]
#[path = "native_data_tests.rs"]
mod data_tests;

#[cfg(test)]
#[path = "native_receive_tests.rs"]
mod receive_tests;

#[cfg(test)]
#[path = "native_cancellation_tests.rs"]
mod cancellation_tests;

struct NativeVideoFrame {
    #[cfg(feature = "sender-timing")]
    enqueued_at: Instant,
    codec: u32,
    flags: u32,
    frame_number: u64,
    pts: u64,
    host_processing_latency: u16,
    payload: Bytes,
}

struct NativeAudioPacket {
    pts: u64,
    frame_samples: u16,
    missing_samples: u32,
    payload: Bytes,
}

struct NativeInputPacket {
    type_: u8,
    payload: Bytes,
}

#[derive(Default)]
struct NativeDataQueue {
    packets: VecDeque<Bytes>,
    bytes: usize,
}

impl NativeDataQueue {
    fn can_push(&self, size: usize) -> bool {
        (1..=MAX_DATA_PACKET_SIZE).contains(&size)
            && self.packets.len() < DATA_QUEUE_PACKET_CAPACITY
            && size <= DATA_QUEUE_BYTE_CAPACITY - self.bytes
    }

    fn push_back(&mut self, payload: Bytes) -> bool {
        if !self.can_push(payload.len()) {
            return false;
        }
        self.bytes += payload.len();
        self.packets.push_back(payload);
        true
    }

    fn front(&self) -> Option<&Bytes> {
        self.packets.front()
    }

    fn pop_front(&mut self) -> Option<Bytes> {
        let payload = self.packets.pop_front()?;
        self.bytes -= payload.len();
        Some(payload)
    }
}

#[derive(Default)]
struct NativeQueues {
    video_send: VecDeque<NativeVideoFrame>,
    video_receive: VecDeque<NativeVideoFrame>,
    audio_send: VecDeque<NativeAudioPacket>,
    audio_receive: VecDeque<NativeAudioPacket>,
    input_send: VecDeque<NativeInputPacket>,
    input_receive: VecDeque<NativeInputPacket>,
    data_send: NativeDataQueue,
    data_receive: NativeDataQueue,
}

#[derive(Default)]
struct NativeStats {
    video_frames_sent: AtomicU64,
    video_bytes_sent: AtomicU64,
    video_frames_received: AtomicU64,
    video_bytes_received: AtomicU64,
    video_send_drops: AtomicU64,
    video_receive_drops: AtomicU64,
    audio_packets_sent: AtomicU64,
    audio_bytes_sent: AtomicU64,
    audio_packets_received: AtomicU64,
    audio_bytes_received: AtomicU64,
    audio_send_drops: AtomicU64,
    audio_receive_drops: AtomicU64,
    input_packets_sent: AtomicU64,
    input_packets_received: AtomicU64,
    data_packets_sent: AtomicU64,
    data_packets_received: AtomicU64,
    quic_rtt_us: AtomicU64,
    quic_packets_lost: AtomicU64,
    kyproto_packets_dropped: AtomicU64,
    // Sample/publish the related counters as one coherent snapshot.
    video_fec: Mutex<(u64, u64, u64)>,
}

struct NativeStatus {
    state: EndpointState,
    error: String,
}

struct NativeShared {
    #[cfg(feature = "sender-timing")]
    sender_trace: sender_trace::Trace,
    status: Mutex<NativeStatus>,
    state_changed: Condvar,
    stop: AtomicBool,
    stop_notify: tokio::sync::Notify,
    peer_certificate: Mutex<Vec<u8>>,
    peer_certificate_approval_required: bool,
    peer_certificate_approved: AtomicBool,
    peer_certificate_approved_notify: tokio::sync::Notify,
    setup_mode: bool,
    session_authorized: AtomicBool,
    session_authorized_notify: tokio::sync::Notify,
    queues: Mutex<NativeQueues>,
    video_send_notify: tokio::sync::Notify,
    audio_send_notify: tokio::sync::Notify,
    input_send_notify: tokio::sync::Notify,
    data_send_notify: tokio::sync::Notify,
    video_receive_changed: Condvar,
    audio_receive_changed: Condvar,
    input_receive_changed: Condvar,
    data_receive_changed: Condvar,
    stats: NativeStats,
    rate_policy: Arc<TransportRatePolicy>,
}

impl NativeShared {
    fn new(
        peer_certificate_approval_required: bool,
        setup_mode: bool,
        initial_video_bitrate_bps: u64,
    ) -> Self {
        Self {
            #[cfg(feature = "sender-timing")]
            sender_trace: sender_trace::Trace::default(),
            status: Mutex::new(NativeStatus {
                state: EndpointState::Idle,
                error: String::new(),
            }),
            state_changed: Condvar::new(),
            stop: AtomicBool::new(false),
            stop_notify: tokio::sync::Notify::new(),
            peer_certificate: Mutex::new(Vec::new()),
            peer_certificate_approval_required,
            peer_certificate_approved: AtomicBool::new(false),
            peer_certificate_approved_notify: tokio::sync::Notify::new(),
            setup_mode,
            session_authorized: AtomicBool::new(false),
            session_authorized_notify: tokio::sync::Notify::new(),
            queues: Mutex::new(NativeQueues::default()),
            video_send_notify: tokio::sync::Notify::new(),
            audio_send_notify: tokio::sync::Notify::new(),
            input_send_notify: tokio::sync::Notify::new(),
            data_send_notify: tokio::sync::Notify::new(),
            video_receive_changed: Condvar::new(),
            audio_receive_changed: Condvar::new(),
            input_receive_changed: Condvar::new(),
            data_receive_changed: Condvar::new(),
            stats: NativeStats::default(),
            rate_policy: TransportRatePolicy::new(initial_video_bitrate_bps),
        }
    }

    fn state(&self) -> EndpointState {
        self.status.lock().unwrap().state
    }

    fn set_state(&self, state: EndpointState) {
        let mut status = self.status.lock().unwrap();
        // A simultaneously finishing setup step must not advertise Ready
        // again after a stop/failure has already been published.
        if matches!(status.state, EndpointState::Stopped | EndpointState::Failed)
            || (status.state == EndpointState::Stopping && state != EndpointState::Stopped)
        {
            return;
        }
        status.state = state;
        drop(status);
        self.state_changed.notify_all();
    }

    async fn shutdown_requested(&self) {
        loop {
            // Register before checking the durable predicate. notify_all()
            // is also used for failures/spurious wakes, and notify_waiters()
            // alone does not retain a permit for a future setup phase.
            let notified = self.stop_notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.stop.load(Ordering::Acquire) || self.state() == EndpointState::Failed {
                return;
            }
            notified.await;
        }
    }

    async fn until_shutdown<T>(
        &self,
        operation: impl Future<Output = Result<T>>,
    ) -> Result<Option<T>> {
        tokio::select! {
            biased;
            _ = self.shutdown_requested() => Ok(None),
            result = operation => result.map(Some),
        }
    }

    fn fail(&self, error: impl ToString) {
        let mut status = self.status.lock().unwrap();
        status.error = error.to_string();
        status.state = EndpointState::Failed;
        drop(status);
        self.notify_all();
    }

    fn notify_all(&self) {
        self.state_changed.notify_all();
        self.video_receive_changed.notify_all();
        self.audio_receive_changed.notify_all();
        self.input_receive_changed.notify_all();
        self.data_receive_changed.notify_all();
        self.stop_notify.notify_waiters();
        self.peer_certificate_approved_notify.notify_waiters();
        self.session_authorized_notify.notify_waiters();
        self.video_send_notify.notify_waiters();
        self.audio_send_notify.notify_waiters();
        self.input_send_notify.notify_waiters();
        self.data_send_notify.notify_waiters();
    }
}

#[repr(C)]
pub struct PlankTransportNativeVideoFrameInfo {
    pub struct_size: u32,
    pub codec: u32,
    pub flags: u32,
    pub reserved: u32,
    pub frame_number: u64,
    pub pts: u64,
    pub host_processing_latency: u16,
    pub reserved2: [u8; 6],
}

#[repr(C)]
pub struct PlankTransportNativeAudioPacketInfo {
    pub struct_size: u32,
    pub frame_samples: u16,
    pub reserved: u16,
    pub missing_samples: u32,
    pub reserved2: u32,
    pub pts: u64,
}

#[repr(C)]
pub struct PlankTransportNativeStats {
    pub struct_size: u32,
    pub video_frames_sent: u64,
    pub video_bytes_sent: u64,
    pub video_frames_received: u64,
    pub video_bytes_received: u64,
    pub video_send_drops: u64,
    pub video_receive_drops: u64,
    pub audio_packets_sent: u64,
    pub audio_bytes_sent: u64,
    pub audio_packets_received: u64,
    pub audio_bytes_received: u64,
    pub audio_send_drops: u64,
    pub audio_receive_drops: u64,
    pub input_packets_sent: u64,
    pub input_packets_received: u64,
    pub data_packets_sent: u64,
    pub data_packets_received: u64,
    pub quic_rtt_us: u64,
    pub quic_packets_lost: u64,
    pub kyproto_packets_dropped: u64,
    pub video_fec_source_symbols: u64,
    pub video_fec_source_symbols_missing: u64,
    pub video_fec_source_symbols_unrecovered: u64,
}

pub struct PlankTransportNativeEndpoint {
    config: EndpointConfig,
    mode: u32,
    shared: Arc<NativeShared>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

fn native_options(options: super::RuntimeOptions) -> NativeOptions {
    NativeOptions {
        handshake_timeout: options.handshake_timeout,
        idle_timeout: options.idle_timeout,
        keep_alive_interval: options.keep_alive_interval,
        max_udp_payload_size: options.max_udp_payload_size,
    }
}

fn validate_video_codec(codec: u32) -> bool {
    matches!(codec, VIDEO_CODEC_H264 | VIDEO_CODEC_HEVC)
}

async fn send_video(
    shared: Arc<NativeShared>,
    mut protocol: kymux_types::VideoServerProtocol,
) -> Result<()> {
    let mut active_codec = None;
    loop {
        let notified = shared.video_send_notify.notified();
        let (frame, _queue_depth) = {
            let mut queues = shared.queues.lock().unwrap();
            let frame = queues.video_send.pop_front();
            (frame, queues.video_send.len())
        };
        if let Some(frame) = frame {
            #[cfg(feature = "sender-timing")]
            let timing = shared.sender_trace.begin(frame.enqueued_at);
            #[cfg(feature = "sender-timing")]
            let trace_frame = sender_trace::Frame {
                number: frame.frame_number,
                key: frame.flags & VIDEO_FLAG_KEY != 0,
                bytes: frame.payload.len(),
                depth: _queue_depth,
                wire_bps: shared.rate_policy.active_wire_bps(),
                drops: shared.stats.video_send_drops.load(Ordering::Relaxed),
            };
            let payload_size = frame.payload.len() as u64;
            let submission = async {
                if active_codec != Some(frame.codec) {
                    protocol
                        .send
                        .send(AVPacket::Codec(CodecPacket {
                            header: CodecPacketHeader {
                                codec: frame.codec,
                                rotation: 0,
                                frame_size: 0,
                            },
                        }))
                        .await?;
                    active_codec = Some(frame.codec);
                }
                let key = frame.flags & VIDEO_FLAG_KEY != 0;
                if key {
                    protocol
                        .send
                        .send(AVPacket::Media(MediaPacket {
                            header: MediaPacketHeader {
                                is_config: true,
                                is_key: true,
                                pts: frame.pts,
                                size: 0,
                            },
                            payload: Bytes::new(),
                        }))
                        .await?;
                }
                let mut native_payload =
                    BytesMut::with_capacity(VIDEO_METADATA_SIZE + frame.payload.len());
                native_payload.put_u64(frame.frame_number);
                native_payload.put_u16(frame.host_processing_latency);
                native_payload.extend_from_slice(&[0; VIDEO_METADATA_SIZE - 10]);
                native_payload.extend_from_slice(&frame.payload);
                let native_payload = native_payload.freeze();
                protocol
                    .send
                    .send(AVPacket::Media(MediaPacket {
                        header: MediaPacketHeader {
                            is_config: false,
                            is_key: key,
                            pts: frame.pts,
                            size: native_payload.len() as u32,
                        },
                        payload: native_payload,
                    }))
                    .await?;
                Ok::<(), anyhow::Error>(())
            };
            #[cfg(feature = "sender-timing")]
            let result = if let Some(start) = timing {
                let (result, measurements) = kynet::sender_timing::measure(submission).await;
                shared
                    .sender_trace
                    .finish(start, trace_frame, result.is_err(), measurements);
                result
            } else {
                submission.await
            };
            #[cfg(not(feature = "sender-timing"))]
            let result = submission.await;
            result?;
            shared
                .stats
                .video_frames_sent
                .fetch_add(1, Ordering::Relaxed);
            shared
                .stats
                .video_bytes_sent
                .fetch_add(payload_size, Ordering::Relaxed);
            continue;
        }
        if shared.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        notified.await;
    }
}

async fn send_audio(
    shared: Arc<NativeShared>,
    mut protocol: kymux_types::AudioServerProtocol,
) -> Result<()> {
    let mut active_frame_samples = None;
    loop {
        let notified = shared.audio_send_notify.notified();
        let packet = shared.queues.lock().unwrap().audio_send.pop_front();
        if let Some(packet) = packet {
            if active_frame_samples != Some(packet.frame_samples) {
                protocol
                    .send
                    .send(AVPacket::Codec(CodecPacket {
                        header: CodecPacketHeader {
                            codec: AUDIO_CODEC_OPUS,
                            rotation: 0,
                            frame_size: packet.frame_samples,
                        },
                    }))
                    .await?;
                protocol
                    .send
                    .send(AVPacket::Media(MediaPacket {
                        header: MediaPacketHeader {
                            is_config: true,
                            is_key: true,
                            pts: packet.pts,
                            size: 0,
                        },
                        payload: Bytes::new(),
                    }))
                    .await?;
                active_frame_samples = Some(packet.frame_samples);
            }
            let payload_size = packet.payload.len() as u64;
            protocol
                .send
                .send(AVPacket::Media(MediaPacket {
                    header: MediaPacketHeader {
                        is_config: false,
                        is_key: false,
                        pts: packet.pts,
                        size: packet.payload.len() as u32,
                    },
                    payload: packet.payload,
                }))
                .await?;
            shared
                .stats
                .audio_packets_sent
                .fetch_add(1, Ordering::Relaxed);
            shared
                .stats
                .audio_bytes_sent
                .fetch_add(payload_size, Ordering::Relaxed);
            continue;
        }
        if shared.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        notified.await;
    }
}

fn push_video_receive(shared: &NativeShared, frame: NativeVideoFrame) {
    let payload_size = frame.payload.len() as u64;
    let dropped = {
        let mut queues = shared.queues.lock().unwrap();
        let dropped = if queues.video_receive.len() == VIDEO_RECEIVE_CAPACITY {
            queues.video_receive.pop_front();
            true
        } else {
            false
        };
        queues.video_receive.push_back(frame);
        dropped
    };
    if dropped {
        shared
            .stats
            .video_receive_drops
            .fetch_add(1, Ordering::Relaxed);
    }
    shared
        .stats
        .video_frames_received
        .fetch_add(1, Ordering::Relaxed);
    shared
        .stats
        .video_bytes_received
        .fetch_add(payload_size, Ordering::Relaxed);
    shared.video_receive_changed.notify_one();
}

async fn receive_video(
    shared: Arc<NativeShared>,
    mut protocol: kymux_types::VideoClientProtocol,
) -> Result<()> {
    let mut codec = 0;
    while let Some(packet) = protocol.recv.recv().await? {
        match packet {
            AVPacket::Codec(packet) => codec = packet.header.codec,
            AVPacket::Media(packet) if !packet.header.is_config => {
                if packet.payload.len() < VIDEO_METADATA_SIZE {
                    return Err(anyhow!("native video frame metadata is truncated"));
                }
                let frame_number = u64::from_be_bytes(
                    packet.payload[..8]
                        .try_into()
                        .expect("video frame number is exactly eight bytes"),
                );
                let host_processing_latency =
                    u16::from_be_bytes([packet.payload[8], packet.payload[9]]);
                push_video_receive(
                    &shared,
                    NativeVideoFrame {
                        #[cfg(feature = "sender-timing")]
                        enqueued_at: Instant::now(),
                        codec,
                        flags: if packet.header.is_key {
                            VIDEO_FLAG_KEY
                        } else {
                            0
                        },
                        frame_number,
                        pts: packet.header.pts,
                        host_processing_latency,
                        payload: packet.payload.slice(VIDEO_METADATA_SIZE..),
                    },
                );
            }
            AVPacket::Media(_) => {}
            // A KyProto hole is a normal unrecoverable-frame indication, not a
            // connection failure.  Preserve the endpoint and let the next
            // complete frame's sequence discontinuity drive decoder/IDR
            // recovery at the client boundary.
            AVPacket::Hole(_) => {}
        }
    }
    Ok(())
}

fn push_audio_receive(shared: &NativeShared, packet: NativeAudioPacket) {
    let payload_size = packet.payload.len() as u64;
    let dropped = {
        let mut queues = shared.queues.lock().unwrap();
        let dropped = if queues.audio_receive.len() == AUDIO_RECEIVE_CAPACITY {
            queues.audio_receive.pop_front();
            true
        } else {
            false
        };
        queues.audio_receive.push_back(packet);
        dropped
    };
    if dropped {
        shared
            .stats
            .audio_receive_drops
            .fetch_add(1, Ordering::Relaxed);
    }
    shared
        .stats
        .audio_packets_received
        .fetch_add(1, Ordering::Relaxed);
    shared
        .stats
        .audio_bytes_received
        .fetch_add(payload_size, Ordering::Relaxed);
    shared.audio_receive_changed.notify_one();
}

async fn receive_audio(
    shared: Arc<NativeShared>,
    mut protocol: kymux_types::AudioClientProtocol,
) -> Result<()> {
    let mut frame_samples = 0;
    while let Some(packet) = protocol.recv.recv().await? {
        match packet {
            AVPacket::Codec(packet) => frame_samples = packet.header.frame_size,
            AVPacket::Media(packet) if !packet.header.is_config => push_audio_receive(
                &shared,
                NativeAudioPacket {
                    pts: packet.header.pts,
                    frame_samples,
                    missing_samples: 0,
                    payload: packet.payload,
                },
            ),
            AVPacket::Hole(packet) => push_audio_receive(
                &shared,
                NativeAudioPacket {
                    pts: 0,
                    frame_samples,
                    missing_samples: packet.header.missing_audio_samples,
                    payload: Bytes::new(),
                },
            ),
            AVPacket::Media(_) => {}
        }
    }
    Ok(())
}

async fn send_input(
    shared: Arc<NativeShared>,
    mut send: kymux_types::ProtocolSend<InputPacket>,
) -> Result<()> {
    loop {
        let notified = shared.input_send_notify.notified();
        let packet = shared.queues.lock().unwrap().input_send.pop_front();
        if let Some(packet) = packet {
            send.send(InputPacket {
                type_: packet.type_,
                payload: packet.payload,
            })
            .await?;
            shared
                .stats
                .input_packets_sent
                .fetch_add(1, Ordering::Relaxed);
            continue;
        }
        if shared.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        notified.await;
    }
}

async fn receive_input(
    shared: Arc<NativeShared>,
    mut recv: kymux_types::ProtocolRecv<InputPacket>,
) -> Result<()> {
    while let Some(packet) = recv.recv().await? {
        let depth = {
            let mut queues = shared.queues.lock().unwrap();
            if queues.input_receive.len() == INPUT_RECEIVE_CAPACITY {
                return Err(anyhow!("native input receive queue exhausted"));
            }
            queues.input_receive.push_back(NativeInputPacket {
                type_: packet.type_,
                payload: packet.payload,
            });
            queues.input_receive.len()
        };
        debug_assert!(depth <= INPUT_RECEIVE_CAPACITY);
        shared
            .stats
            .input_packets_received
            .fetch_add(1, Ordering::Relaxed);
        shared.input_receive_changed.notify_one();
    }
    Ok(())
}

async fn send_data(
    shared: Arc<NativeShared>,
    mut send: kymux_types::ProtocolSend<DataPacket>,
) -> Result<()> {
    loop {
        let notified = shared.data_send_notify.notified();
        let payload = shared.queues.lock().unwrap().data_send.pop_front();
        if let Some(payload) = payload {
            send.send(DataPacket { payload }).await?;
            shared
                .stats
                .data_packets_sent
                .fetch_add(1, Ordering::Relaxed);
            continue;
        }
        if shared.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        notified.await;
    }
}

async fn receive_data(
    shared: Arc<NativeShared>,
    mut recv: kymux_types::ProtocolRecv<DataPacket>,
) -> Result<()> {
    while let Some(packet) = recv.recv().await? {
        {
            let mut queues = shared.queues.lock().unwrap();
            if !queues.data_receive.push_back(packet.payload) {
                return Err(anyhow!(
                    "native reliable data receive queue size limit exceeded"
                ));
            }
        }
        shared
            .stats
            .data_packets_received
            .fetch_add(1, Ordering::Relaxed);
        shared.data_receive_changed.notify_one();
    }
    Ok(())
}

async fn sample_stats(
    shared: Arc<NativeShared>,
    provider: kyproto::KyProtoStatsProvider,
) -> Result<()> {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    loop {
        interval.tick().await;
        if shared.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        let connection = provider.connection_stats().await;
        let protocol = provider.protocol_stats();
        shared.stats.quic_rtt_us.store(
            connection
                .rtt
                .map(|value| value.as_micros() as u64)
                .unwrap_or_default(),
            Ordering::Relaxed,
        );
        shared.stats.quic_packets_lost.store(
            connection.packets_lost.unwrap_or_default(),
            Ordering::Relaxed,
        );
        shared.stats.kyproto_packets_dropped.store(
            protocol.dropped_packets.unwrap_or_default(),
            Ordering::Relaxed,
        );
        *shared.stats.video_fec.lock().unwrap() = (
            protocol.video_fec_source_symbols.unwrap_or_default(),
            protocol
                .video_fec_source_symbols_missing
                .unwrap_or_default(),
            protocol
                .video_fec_source_symbols_unrecovered
                .unwrap_or_default(),
        );
    }
}

fn active_lane_result(result: Result<()>, lane: &str) -> Result<()> {
    result.with_context(|| format!("{lane} failed"))?;
    Err(anyhow!("{lane} ended while the native endpoint was active"))
}

async fn hold_server(shared: Arc<NativeShared>, protocols: NativeServerProtocols) -> Result<()> {
    let stats_provider = protocols.connection().stats_provider();
    let (connection, video, audio, input, data) = protocols.into_parts();
    let mut video = Box::pin(send_video(shared.clone(), video));
    let mut audio = Box::pin(send_audio(shared.clone(), audio));
    let mut input = Box::pin(receive_input(shared.clone(), input.recv));
    let mut data_send = Box::pin(send_data(shared.clone(), data.send));
    let mut data_receive = Box::pin(receive_data(shared.clone(), data.recv));
    let mut stats = Box::pin(sample_stats(shared.clone(), stats_provider));
    shared.set_state(EndpointState::Ready);
    tokio::select! {
        result = &mut video => active_lane_result(result, "native video sender"),
        result = &mut audio => active_lane_result(result, "native audio sender"),
        result = &mut input => active_lane_result(result, "native input receiver"),
        result = &mut data_send => active_lane_result(result, "native data sender"),
        result = &mut data_receive => active_lane_result(result, "native data receiver"),
        result = &mut stats => active_lane_result(result, "native stats sampler"),
        result = connection.closed() => result.context("native KyProto connection closed"),
    }
}

async fn hold_client(shared: Arc<NativeShared>, protocols: NativeClientProtocols) -> Result<()> {
    let stats_provider = protocols.connection().stats_provider();
    let (connection, video, audio, input, data, peer_certificate_der) = protocols.into_parts();
    *shared.peer_certificate.lock().unwrap() = peer_certificate_der;
    if shared.peer_certificate_approval_required {
        shared.set_state(EndpointState::PeerValidation);
        loop {
            if shared.peer_certificate_approved.load(Ordering::Acquire) {
                break;
            }
            tokio::select! {
                _ = shared.peer_certificate_approved_notify.notified() => {},
                result = connection.closed() => {
                    return result.context("native KyProto connection closed during certificate validation");
                }
            }
        }
    }
    let mut video = Box::pin(receive_video(shared.clone(), video));
    let mut audio = Box::pin(receive_audio(shared.clone(), audio));
    let mut input = Box::pin(send_input(shared.clone(), input.send));
    let mut data_send = Box::pin(send_data(shared.clone(), data.send));
    let mut data_receive = Box::pin(receive_data(shared.clone(), data.recv));
    let mut stats = Box::pin(sample_stats(shared.clone(), stats_provider));
    shared.set_state(EndpointState::Ready);
    tokio::select! {
        result = &mut video => active_lane_result(result, "native video receiver"),
        result = &mut audio => active_lane_result(result, "native audio receiver"),
        result = &mut input => active_lane_result(result, "native input sender"),
        result = &mut data_send => active_lane_result(result, "native data sender"),
        result = &mut data_receive => active_lane_result(result, "native data receiver"),
        result = &mut stats => active_lane_result(result, "native stats sampler"),
        result = connection.closed() => result.context("native KyProto connection closed"),
    }
}

async fn hold_setup_server(
    shared: Arc<NativeShared>,
    setup: native::NativeSetupServerProtocols,
    options: super::RuntimeOptions,
) -> Result<()> {
    let stats_provider = setup.connection().stats_provider();
    let (connection, data) = setup.into_parts();
    let mut data_send = Box::pin(send_data(shared.clone(), data.send));
    let mut data_receive = Box::pin(receive_data(shared.clone(), data.recv));
    let mut stats = Box::pin(sample_stats(shared.clone(), stats_provider));
    shared.set_state(EndpointState::SetupReady);

    loop {
        if shared.session_authorized.load(Ordering::Acquire) {
            break;
        }
        tokio::select! {
            _ = shared.session_authorized_notify.notified() => {},
            result = &mut data_send => return result.context("setup data sender failed"),
            result = &mut data_receive => return result.context("setup data receiver failed"),
            result = &mut stats => return result.context("setup stats sampler failed"),
            result = connection.closed() => {
                return result.context("setup KyProto connection closed");
            }
        }
    }

    let (video, audio, input) =
        native::promote_setup_server(&connection, native_options(options)).await?;
    let mut video = Box::pin(send_video(shared.clone(), video));
    let mut audio = Box::pin(send_audio(shared.clone(), audio));
    let mut input = Box::pin(receive_input(shared.clone(), input.recv));
    shared.set_state(EndpointState::Ready);
    tokio::select! {
        result = &mut video => result.context("native video sender failed"),
        result = &mut audio => result.context("native audio sender failed"),
        result = &mut input => result.context("native input receiver failed"),
        result = &mut data_send => result.context("native data sender failed"),
        result = &mut data_receive => result.context("native data receiver failed"),
        result = &mut stats => result.context("native stats sampler failed"),
        result = connection.closed() => result.context("native KyProto connection closed"),
    }
}

async fn hold_setup_client(
    shared: Arc<NativeShared>,
    setup: native::NativeSetupClientProtocols,
    options: super::RuntimeOptions,
) -> Result<()> {
    let stats_provider = setup.connection().stats_provider();
    let (connection, data, peer_certificate_der) = setup.into_parts();
    *shared.peer_certificate.lock().unwrap() = peer_certificate_der;
    shared.set_state(EndpointState::PeerValidation);
    loop {
        if shared.peer_certificate_approved.load(Ordering::Acquire) {
            break;
        }
        tokio::select! {
            _ = shared.peer_certificate_approved_notify.notified() => {},
            result = connection.closed() => {
                return result.context("setup KyProto connection closed during certificate validation");
            }
        }
    }

    let mut data_send = Box::pin(send_data(shared.clone(), data.send));
    let mut data_receive = Box::pin(receive_data(shared.clone(), data.recv));
    let mut stats = Box::pin(sample_stats(shared.clone(), stats_provider));
    shared.set_state(EndpointState::SetupReady);
    loop {
        if shared.session_authorized.load(Ordering::Acquire) {
            break;
        }
        tokio::select! {
            _ = shared.session_authorized_notify.notified() => {},
            result = &mut data_send => return result.context("setup data sender failed"),
            result = &mut data_receive => return result.context("setup data receiver failed"),
            result = &mut stats => return result.context("setup stats sampler failed"),
            result = connection.closed() => {
                return result.context("setup KyProto connection closed");
            }
        }
    }

    let (video, audio, input) =
        native::promote_setup_client(&connection, native_options(options)).await?;
    let mut video = Box::pin(receive_video(shared.clone(), video));
    let mut audio = Box::pin(receive_audio(shared.clone(), audio));
    let mut input = Box::pin(send_input(shared.clone(), input.send));
    shared.set_state(EndpointState::Ready);
    tokio::select! {
        result = &mut video => result.context("native video receiver failed"),
        result = &mut audio => result.context("native audio receiver failed"),
        result = &mut input => result.context("native input sender failed"),
        result = &mut data_send => result.context("native data sender failed"),
        result = &mut data_receive => result.context("native data receiver failed"),
        result = &mut stats => result.context("native stats sampler failed"),
        result = connection.closed() => result.context("native KyProto connection closed"),
    }
}

async fn run_server(
    shared: Arc<NativeShared>,
    bind_address: std::net::SocketAddr,
    certificate_path: &Path,
    private_key_path: &Path,
    session_token: &str,
    options: super::RuntimeOptions,
) -> Result<()> {
    let Some((certificate, private_key)) = shared
        .until_shutdown(async {
            Ok((
                kynet::cert::load_cert_from_pem_file(certificate_path).await?,
                kynet::cert::load_private_key_from_pem_file(private_key_path).await?,
            ))
        })
        .await?
    else {
        return Ok(());
    };
    let server_options = kynet::common::CommonServerOptions {
        max_idle_timeout: Some(options.idle_timeout),
        keep_alive_interval: Some(options.keep_alive_interval),
        max_udp_payload_size: options.max_udp_payload_size,
        congestion_controller_factory: Some(PlankRateControllerFactory::new(
            shared.rate_policy.clone(),
        )),
    };
    let server = kynet::Connection::start_server_on_addr(
        bind_address,
        vec![certificate],
        private_key,
        &server_options,
    )?;
    let result = shared
        .until_shutdown(async {
            let protocols =
                native::accept_server(&server, session_token, native_options(options)).await?;
            hold_server(shared.clone(), protocols).await
        })
        .await;
    server.close(0, "PLANK native endpoint stopping");
    // close() only queues CONNECTION_CLOSE. Keep the runtime alive while
    // Quinn transmits it; dropping the runtime immediately leaves the peer
    // waiting for idle expiry during a graphical-session handoff. Bound this
    // drain so an unreachable peer cannot hold Host ownership indefinitely.
    drain_server(&server).await;
    result.map(|_| ())
}

async fn drain_server(server: &impl kynet::Server) {
    // Deliberately outside the cancellable operation. Cancellation and early
    // handshake failures must still allow the queued close packet to leave.
    let _ = tokio::time::timeout(CONNECTION_CLOSE_DRAIN, server.wait_idle()).await;
}

async fn run_client(
    shared: Arc<NativeShared>,
    remote_address: std::net::SocketAddr,
    server_name: &str,
    certificate_sha256: Option<&str>,
    session_token: &str,
    options: super::RuntimeOptions,
) -> Result<()> {
    shared
        .until_shutdown(async {
            let protocols = native::connect_client(
                remote_address,
                server_name,
                certificate_sha256,
                session_token,
                native_options(options),
            )
            .await?;
            hold_client(shared.clone(), protocols).await
        })
        .await
        .map(|_| ())
}

async fn run_setup_server(
    shared: Arc<NativeShared>,
    bind_address: std::net::SocketAddr,
    certificate_path: &Path,
    private_key_path: &Path,
    setup_marker: &str,
    options: super::RuntimeOptions,
) -> Result<()> {
    let Some((certificate, private_key)) = shared
        .until_shutdown(async {
            Ok((
                kynet::cert::load_cert_from_pem_file(certificate_path).await?,
                kynet::cert::load_private_key_from_pem_file(private_key_path).await?,
            ))
        })
        .await?
    else {
        return Ok(());
    };
    let server_options = kynet::common::CommonServerOptions {
        max_idle_timeout: Some(options.idle_timeout),
        keep_alive_interval: Some(options.keep_alive_interval),
        max_udp_payload_size: options.max_udp_payload_size,
        congestion_controller_factory: Some(PlankRateControllerFactory::new(
            shared.rate_policy.clone(),
        )),
    };
    let server = kynet::Connection::start_server_on_addr(
        bind_address,
        vec![certificate],
        private_key,
        &server_options,
    )?;
    let result = shared
        .until_shutdown(async {
            let setup =
                native::accept_setup_server(&server, setup_marker, native_options(options)).await?;
            hold_setup_server(shared.clone(), setup, options).await
        })
        .await;
    server.close(0, "PLANK setup endpoint stopping");
    drain_server(&server).await;
    result.map(|_| ())
}

async fn run_setup_client(
    shared: Arc<NativeShared>,
    remote_address: std::net::SocketAddr,
    server_name: &str,
    setup_marker: &str,
    options: super::RuntimeOptions,
) -> Result<()> {
    shared
        .until_shutdown(async {
            let setup = native::connect_setup_client(
                remote_address,
                server_name,
                setup_marker,
                native_options(options),
            )
            .await?;
            hold_setup_client(shared.clone(), setup, options).await
        })
        .await
        .map(|_| ())
}

fn worker(config: EndpointConfig, shared: Arc<NativeShared>) {
    init_crypto_once();
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(4)
        .thread_name("sc-kyproto")
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            shared.fail(format!("failed to create native KyProto runtime: {error}"));
            return;
        }
    };
    let result = runtime.block_on(async {
        match config {
            EndpointConfig::Server {
                bind_address,
                certificate_path,
                private_key_path,
                session_token,
                setup_mode,
                options,
            } => {
                if setup_mode {
                    run_setup_server(
                        shared.clone(),
                        bind_address,
                        &certificate_path,
                        &private_key_path,
                        &session_token,
                        options,
                    )
                    .await
                } else {
                    run_server(
                        shared.clone(),
                        bind_address,
                        &certificate_path,
                        &private_key_path,
                        &session_token,
                        options,
                    )
                    .await
                }
            }
            EndpointConfig::Client {
                remote_address,
                server_name,
                certificate_sha256,
                session_token,
                setup_mode,
                options,
            } => {
                if setup_mode {
                    run_setup_client(
                        shared.clone(),
                        remote_address,
                        &server_name,
                        &session_token,
                        options,
                    )
                    .await
                } else {
                    run_client(
                        shared.clone(),
                        remote_address,
                        &server_name,
                        certificate_sha256.as_deref(),
                        &session_token,
                        options,
                    )
                    .await
                }
            }
        }
    });
    finish_worker(&shared, result);
}

fn finish_worker(shared: &NativeShared, result: Result<()>) {
    if shared.state() == EndpointState::Failed {
        // A queue/API failure also cancels the lifecycle; do not replace its
        // original diagnosis with the generic peer-close result.
        return;
    }
    if shared.stop.load(Ordering::Acquire) {
        shared.set_state(EndpointState::Stopped);
    } else if let Err(error) = result {
        shared.fail(format!("{error:#}"));
    } else {
        // KyNet maps an orderly peer APPLICATION_CLOSE to Ok(()). It still
        // terminates our active/setup session. Only an explicit local stop
        // may become Stopped: otherwise receive calls mistake this terminal
        // state for an empty queue and report TIMEOUT indefinitely. Centralize
        // this for every lane/setup path, independent of select! ordering.
        shared.fail("native KyProto peer closed while the endpoint was active");
    }
}

#[cfg(test)]
mod completion_tests {
    use super::*;

    #[test]
    fn orderly_peer_close_fails_all_live_phases() {
        for phase in [
            EndpointState::PeerValidation,
            EndpointState::SetupReady,
            EndpointState::Ready,
        ] {
            let shared = NativeShared::new(false, false, 150_000_000);
            shared.set_state(phase);
            finish_worker(&shared, Ok(()));
            assert_eq!(shared.state(), EndpointState::Failed);
            assert!(shared.status.lock().unwrap().error.contains("peer closed"));
        }
    }

    #[test]
    fn explicit_local_stop_remains_stopped() {
        for result in [Ok(()), Err(anyhow!("closed during local shutdown"))] {
            let shared = NativeShared::new(false, false, 150_000_000);
            shared.stop.store(true, Ordering::Release);
            finish_worker(&shared, result);
            assert_eq!(shared.state(), EndpointState::Stopped);
            assert!(shared.status.lock().unwrap().error.is_empty());
        }
    }

    #[test]
    fn transport_failure_keeps_original_error() {
        let shared = NativeShared::new(false, false, 150_000_000);
        finish_worker(&shared, Err(anyhow!("original transport error")));
        assert_eq!(shared.state(), EndpointState::Failed);
        assert_eq!(
            shared.status.lock().unwrap().error,
            "original transport error"
        );
    }

    #[test]
    fn queued_control_precedes_peer_close() {
        let shared = NativeShared::new(false, false, 150_000_000);
        shared
            .queues
            .lock()
            .unwrap()
            .data_receive
            .push_back(Bytes::from_static(b"takeover"));
        finish_worker(&shared, Ok(()));
        let receive = || {
            wait_pop(
                &shared,
                &shared.data_receive_changed,
                Duration::ZERO,
                |queues| queues.data_receive.pop_front(),
            )
        };
        assert_eq!(receive(), Some(Bytes::from_static(b"takeover")));
        assert!(receive().is_none());
        assert_eq!(shared.state(), EndpointState::Failed);
    }
}

fn enqueue_replaceable<T>(queue: &mut VecDeque<T>, capacity: usize, value: T) -> bool {
    let dropped = if queue.len() == capacity {
        queue.pop_front();
        true
    } else {
        false
    };
    queue.push_back(value);
    dropped
}

fn wait_for_state(shared: &NativeShared, timeout: Duration) -> EndpointState {
    let deadline = Instant::now() + timeout;
    let mut status = shared.status.lock().unwrap();
    while matches!(
        status.state,
        EndpointState::Idle
            | EndpointState::Starting
            | EndpointState::PeerValidation
            | EndpointState::SetupReady
    ) {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        let result = shared
            .state_changed
            .wait_timeout(status, remaining)
            .unwrap();
        status = result.0;
        if result.1.timed_out() {
            break;
        }
    }
    status.state
}

fn validate_bytes_out(
    size: usize,
    destination: *mut u8,
    capacity: usize,
    size_out: *mut usize,
) -> i32 {
    if size_out.is_null() {
        return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
    }
    unsafe { *size_out = size };
    if size > capacity {
        return PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL;
    }
    if size != 0 && destination.is_null() {
        return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
    }
    PLANK_TRANSPORT_OK
}

// Called under the queue mutex by wait_pop(). Validate before removing so a
// rejected output buffer cannot consume an item. Move (never clone) the item
// out of the queue before unlocking: overflow may then evict only other items.
fn claim_receive_front<T>(
    queue: &mut VecDeque<T>,
    payload_len: impl FnOnce(&T) -> usize,
    destination: *mut u8,
    capacity: usize,
    size_out: *mut usize,
) -> Option<Result<T, i32>> {
    let result = validate_bytes_out(payload_len(queue.front()?), destination, capacity, size_out);
    Some(if result == PLANK_TRANSPORT_OK {
        Ok(queue
            .pop_front()
            .expect("validated front remains under queue lock"))
    } else {
        Err(result)
    })
}

fn copy_bytes_out(
    payload: &Bytes,
    destination: *mut u8,
    capacity: usize,
    size_out: *mut usize,
) -> i32 {
    let result = validate_bytes_out(payload.len(), destination, capacity, size_out);
    if result != PLANK_TRANSPORT_OK {
        return result;
    }
    // Test-only interleaving at the real C ABI copy boundary; no runtime hook.
    #[cfg(test)]
    receive_tests::before_copy();
    if !payload.is_empty() {
        unsafe { ptr::copy_nonoverlapping(payload.as_ptr(), destination, payload.len()) };
    }
    PLANK_TRANSPORT_OK
}

fn wait_pop<T>(
    shared: &NativeShared,
    changed: &Condvar,
    timeout: Duration,
    pop: impl Fn(&mut NativeQueues) -> Option<T>,
) -> Option<T> {
    let deadline = Instant::now() + timeout;
    let mut queues = shared.queues.lock().unwrap();
    loop {
        if let Some(value) = pop(&mut queues) {
            return Some(value);
        }
        if shared.stop.load(Ordering::Acquire)
            || matches!(
                shared.state(),
                EndpointState::Failed | EndpointState::Stopped
            )
        {
            return None;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return None;
        }
        let result = changed.wait_timeout(queues, remaining).unwrap();
        queues = result.0;
        if result.1.timed_out() {
            return None;
        }
    }
}

/// # Safety
/// `config` and `endpoint_out` must reference valid C objects for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_create(
    config: *const PlankTransportConfig,
    endpoint_out: *mut *mut PlankTransportNativeEndpoint,
) -> i32 {
    catch_result(|| {
        if endpoint_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        unsafe { *endpoint_out = ptr::null_mut() };
        let config = match unsafe { parse_config(config) } {
            Ok(config) => config,
            Err(_) => return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT,
        };
        let (mode, peer_certificate_approval_required, setup_mode) = match &config {
            EndpointConfig::Server { setup_mode, .. } => (1, false, *setup_mode),
            EndpointConfig::Client {
                certificate_sha256,
                setup_mode,
                ..
            } => (2, certificate_sha256.is_none(), *setup_mode),
        };
        let initial_video_bitrate_bps = match &config {
            EndpointConfig::Server { options, .. } | EndpointConfig::Client { options, .. } => {
                options.initial_video_bitrate_bps
            }
        };
        let endpoint = Box::new(PlankTransportNativeEndpoint {
            config,
            mode,
            shared: Arc::new(NativeShared::new(
                peer_certificate_approval_required,
                setup_mode,
                initial_video_bitrate_bps,
            )),
            worker: Mutex::new(None),
        });
        unsafe { *endpoint_out = Box::into_raw(endpoint) };
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// `endpoint` must be null or a live endpoint returned by the create function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_start(
    endpoint: *mut PlankTransportNativeEndpoint,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        // Publish the join handle before a concurrent stop can finish.
        let mut worker_slot = endpoint.worker.lock().unwrap();
        if endpoint.shared.state() != EndpointState::Idle {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        endpoint.shared.set_state(EndpointState::Starting);
        let config = endpoint.config.clone();
        let shared = endpoint.shared.clone();
        let worker = std::thread::Builder::new()
            .name("sc-kyproto-main".to_owned())
            .spawn(move || worker(config, shared));
        match worker {
            Ok(worker) => {
                *worker_slot = Some(worker);
                PLANK_TRANSPORT_OK
            }
            Err(error) => {
                endpoint.shared.fail(error);
                PLANK_TRANSPORT_ERROR_RUNTIME
            }
        }
    })
}

/// # Safety
/// `endpoint` must be null or a live endpoint returned by the create function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_wait_ready(
    endpoint: *mut PlankTransportNativeEndpoint,
    timeout_ms: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        match wait_for_state(&endpoint.shared, Duration::from_millis(timeout_ms.into())) {
            EndpointState::Ready => PLANK_TRANSPORT_OK,
            EndpointState::Failed => PLANK_TRANSPORT_ERROR_RUNTIME,
            EndpointState::Stopped | EndpointState::Stopping => PLANK_TRANSPORT_ERROR_INVALID_STATE,
            _ => PLANK_TRANSPORT_TIMEOUT,
        }
    })
}

/// # Safety
/// `endpoint` must be null or a live endpoint returned by the create function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_state(
    endpoint: *const PlankTransportNativeEndpoint,
) -> u32 {
    if endpoint.is_null() {
        EndpointState::Invalid as u32
    } else {
        unsafe { (*endpoint).shared.state() as u32 }
    }
}

/// # Safety
/// All non-null output pointers must name writable storage of the stated size.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_peer_certificate(
    endpoint: *const PlankTransportNativeEndpoint,
    certificate: *mut u8,
    certificate_capacity: usize,
    certificate_size_out: *mut usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 2 || certificate_size_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if !matches!(
            endpoint.shared.state(),
            EndpointState::PeerValidation | EndpointState::SetupReady | EndpointState::Ready
        ) {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let peer_certificate = endpoint.shared.peer_certificate.lock().unwrap();
        if peer_certificate.is_empty() {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        unsafe { *certificate_size_out = peer_certificate.len() };
        if peer_certificate.len() > certificate_capacity {
            return PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL;
        }
        if certificate.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        unsafe {
            ptr::copy_nonoverlapping(
                peer_certificate.as_ptr(),
                certificate,
                peer_certificate.len(),
            )
        };
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// `endpoint` must be a live Client endpoint returned by the create function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_approve_peer_certificate(
    endpoint: *mut PlankTransportNativeEndpoint,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 2
            || !endpoint.shared.peer_certificate_approval_required
            || endpoint.shared.state() != EndpointState::PeerValidation
            || endpoint.shared.peer_certificate.lock().unwrap().is_empty()
        {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        if endpoint
            .shared
            .peer_certificate_approved
            .swap(true, Ordering::AcqRel)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        endpoint
            .shared
            .peer_certificate_approved_notify
            .notify_one();
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// `endpoint` must be a live setup endpoint returned by the create function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_authorize_session(
    endpoint: *mut PlankTransportNativeEndpoint,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if !endpoint.shared.setup_mode
            || endpoint.shared.state() != EndpointState::SetupReady
            || endpoint
                .shared
                .session_authorized
                .swap(true, Ordering::AcqRel)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        endpoint.shared.session_authorized_notify.notify_one();
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// All non-null pointers must remain valid for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_video_send(
    endpoint: *mut PlankTransportNativeEndpoint,
    info: *const PlankTransportNativeVideoFrameInfo,
    payload: *const u8,
    payload_size: usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        let Some(info) = (unsafe { info.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 1
            || info.struct_size as usize
                != std::mem::size_of::<PlankTransportNativeVideoFrameInfo>()
            || !validate_video_codec(info.codec)
            || info.flags & !VIDEO_FLAG_KEY != 0
            || payload.is_null()
            || !(1..=MAX_VIDEO_FRAME_SIZE).contains(&payload_size)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let payload =
            Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(payload, payload_size) });
        let dropped = enqueue_replaceable(
            &mut endpoint.shared.queues.lock().unwrap().video_send,
            VIDEO_SEND_CAPACITY,
            NativeVideoFrame {
                #[cfg(feature = "sender-timing")]
                enqueued_at: Instant::now(),
                codec: info.codec,
                flags: info.flags,
                frame_number: info.frame_number,
                pts: info.pts,
                host_processing_latency: info.host_processing_latency,
                payload,
            },
        );
        if dropped {
            endpoint
                .shared
                .stats
                .video_send_drops
                .fetch_add(1, Ordering::Relaxed);
        }
        endpoint.shared.video_send_notify.notify_one();
        if dropped {
            PLANK_TRANSPORT_DROPPED
        } else {
            PLANK_TRANSPORT_OK
        }
    })
}

/// # Safety
/// `endpoint` must be a live server endpoint returned by the create function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_set_video_bitrate(
    endpoint: *mut PlankTransportNativeEndpoint,
    bitrate_kbps: u32,
    peak_bitrate_kbps: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 1
            || !(10_000..=500_000).contains(&bitrate_kbps)
            || !(bitrate_kbps..=1_000_000).contains(&peak_bitrate_kbps)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        endpoint.shared.rate_policy.set_requested_video_bps(
            u64::from(bitrate_kbps).saturating_mul(1_000),
            u64::from(peak_bitrate_kbps).saturating_mul(1_000),
        );
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// All non-null output pointers must name writable storage of the stated size.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_video_receive(
    endpoint: *mut PlankTransportNativeEndpoint,
    info: *mut PlankTransportNativeVideoFrameInfo,
    payload: *mut u8,
    payload_capacity: usize,
    payload_size_out: *mut usize,
    timeout_ms: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 2 || info.is_null() || payload_size_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let Some(frame) = wait_pop(
            &endpoint.shared,
            &endpoint.shared.video_receive_changed,
            Duration::from_millis(timeout_ms.into()),
            |queues| {
                claim_receive_front(
                    &mut queues.video_receive,
                    |frame| frame.payload.len(),
                    payload,
                    payload_capacity,
                    payload_size_out,
                )
            },
        ) else {
            return if endpoint.shared.state() == EndpointState::Failed {
                PLANK_TRANSPORT_ERROR_RUNTIME
            } else {
                PLANK_TRANSPORT_TIMEOUT
            };
        };
        let frame = match frame {
            Ok(frame) => frame,
            Err(error) => return error,
        };
        let result = copy_bytes_out(&frame.payload, payload, payload_capacity, payload_size_out);
        if result != PLANK_TRANSPORT_OK {
            return result;
        }
        unsafe {
            *info = PlankTransportNativeVideoFrameInfo {
                struct_size: std::mem::size_of::<PlankTransportNativeVideoFrameInfo>() as u32,
                codec: frame.codec,
                flags: frame.flags,
                reserved: 0,
                frame_number: frame.frame_number,
                pts: frame.pts,
                host_processing_latency: frame.host_processing_latency,
                reserved2: [0; 6],
            }
        };
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// All non-null pointers must remain valid for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_audio_send(
    endpoint: *mut PlankTransportNativeEndpoint,
    info: *const PlankTransportNativeAudioPacketInfo,
    payload: *const u8,
    payload_size: usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        let Some(info) = (unsafe { info.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 1
            || info.struct_size as usize
                != std::mem::size_of::<PlankTransportNativeAudioPacketInfo>()
            || info.frame_samples == 0
            || info.missing_samples != 0
            || payload.is_null()
            || !(1..=MAX_AUDIO_PACKET_SIZE).contains(&payload_size)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let payload =
            Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(payload, payload_size) });
        let dropped = enqueue_replaceable(
            &mut endpoint.shared.queues.lock().unwrap().audio_send,
            AUDIO_SEND_CAPACITY,
            NativeAudioPacket {
                pts: info.pts,
                frame_samples: info.frame_samples,
                missing_samples: 0,
                payload,
            },
        );
        if dropped {
            endpoint
                .shared
                .stats
                .audio_send_drops
                .fetch_add(1, Ordering::Relaxed);
        }
        endpoint.shared.audio_send_notify.notify_one();
        if dropped {
            PLANK_TRANSPORT_DROPPED
        } else {
            PLANK_TRANSPORT_OK
        }
    })
}

/// # Safety
/// All non-null output pointers must name writable storage of the stated size.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_audio_receive(
    endpoint: *mut PlankTransportNativeEndpoint,
    info: *mut PlankTransportNativeAudioPacketInfo,
    payload: *mut u8,
    payload_capacity: usize,
    payload_size_out: *mut usize,
    timeout_ms: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 2 || info.is_null() || payload_size_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let Some(packet) = wait_pop(
            &endpoint.shared,
            &endpoint.shared.audio_receive_changed,
            Duration::from_millis(timeout_ms.into()),
            |queues| {
                claim_receive_front(
                    &mut queues.audio_receive,
                    |packet| packet.payload.len(),
                    payload,
                    payload_capacity,
                    payload_size_out,
                )
            },
        ) else {
            return if endpoint.shared.state() == EndpointState::Failed {
                PLANK_TRANSPORT_ERROR_RUNTIME
            } else {
                PLANK_TRANSPORT_TIMEOUT
            };
        };
        let packet = match packet {
            Ok(packet) => packet,
            Err(error) => return error,
        };
        let result = copy_bytes_out(&packet.payload, payload, payload_capacity, payload_size_out);
        if result != PLANK_TRANSPORT_OK {
            return result;
        }
        unsafe {
            *info = PlankTransportNativeAudioPacketInfo {
                struct_size: std::mem::size_of::<PlankTransportNativeAudioPacketInfo>() as u32,
                frame_samples: packet.frame_samples,
                reserved: 0,
                missing_samples: packet.missing_samples,
                reserved2: 0,
                pts: packet.pts,
            }
        };
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// All non-null pointers must remain valid for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_input_send(
    endpoint: *mut PlankTransportNativeEndpoint,
    type_: u8,
    payload: *const u8,
    payload_size: usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 2 || payload.is_null() || payload_size > MAX_INPUT_PACKET_SIZE {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let mut queues = endpoint.shared.queues.lock().unwrap();
        if queues.input_send.len() == INPUT_SEND_CAPACITY {
            return PLANK_TRANSPORT_TIMEOUT;
        }
        queues.input_send.push_back(NativeInputPacket {
            type_,
            payload: Bytes::copy_from_slice(unsafe {
                std::slice::from_raw_parts(payload, payload_size)
            }),
        });
        drop(queues);
        endpoint.shared.input_send_notify.notify_one();
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// All non-null output pointers must name writable storage of the stated size.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_input_receive(
    endpoint: *mut PlankTransportNativeEndpoint,
    type_out: *mut u8,
    payload: *mut u8,
    payload_capacity: usize,
    payload_size_out: *mut usize,
    timeout_ms: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 1 || type_out.is_null() || payload_size_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let Some(packet) = wait_pop(
            &endpoint.shared,
            &endpoint.shared.input_receive_changed,
            Duration::from_millis(timeout_ms.into()),
            |queues| {
                claim_receive_front(
                    &mut queues.input_receive,
                    |packet| packet.payload.len(),
                    payload,
                    payload_capacity,
                    payload_size_out,
                )
            },
        ) else {
            return if endpoint.shared.state() == EndpointState::Failed {
                PLANK_TRANSPORT_ERROR_RUNTIME
            } else {
                PLANK_TRANSPORT_TIMEOUT
            };
        };
        let packet = match packet {
            Ok(packet) => packet,
            Err(error) => return error,
        };
        let result = copy_bytes_out(&packet.payload, payload, payload_capacity, payload_size_out);
        if result != PLANK_TRANSPORT_OK {
            return result;
        }
        unsafe { *type_out = packet.type_ };
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// All non-null pointers must remain valid for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_data_send(
    endpoint: *mut PlankTransportNativeEndpoint,
    payload: *const u8,
    payload_size: usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if payload.is_null() || !(1..=MAX_DATA_PACKET_SIZE).contains(&payload_size) {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if !matches!(
            endpoint.shared.state(),
            EndpointState::SetupReady | EndpointState::Ready
        ) {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let mut queues = endpoint.shared.queues.lock().unwrap();
        // Check before copying: queue pressure must not allocate and discard
        // another payload. TIMEOUT retains the caller's existing retry contract.
        if !queues.data_send.can_push(payload_size) {
            return PLANK_TRANSPORT_TIMEOUT;
        }
        let inserted = queues.data_send.push_back(Bytes::copy_from_slice(unsafe {
            std::slice::from_raw_parts(payload, payload_size)
        }));
        debug_assert!(inserted);
        drop(queues);
        endpoint.shared.data_send_notify.notify_one();
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// All non-null output pointers must name writable storage of the stated size.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_data_receive(
    endpoint: *mut PlankTransportNativeEndpoint,
    payload: *mut u8,
    payload_capacity: usize,
    payload_size_out: *mut usize,
    timeout_ms: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if payload_size_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let Some(result) = wait_pop(
            &endpoint.shared,
            &endpoint.shared.data_receive_changed,
            Duration::from_millis(timeout_ms.into()),
            |queues| {
                let packet = queues.data_receive.front()?;
                let result = copy_bytes_out(packet, payload, payload_capacity, payload_size_out);
                if result == PLANK_TRANSPORT_OK {
                    queues.data_receive.pop_front();
                }
                // Peeking, copying and removing share the queue lock. A short
                // output buffer leaves both the packet and its byte charge intact.
                Some(result)
            },
        ) else {
            return if endpoint.shared.state() == EndpointState::Failed {
                PLANK_TRANSPORT_ERROR_RUNTIME
            } else {
                PLANK_TRANSPORT_TIMEOUT
            };
        };
        result
    })
}

/// # Safety
/// `stats` must name writable storage and `endpoint` must remain live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_stats(
    endpoint: *const PlankTransportNativeEndpoint,
    stats: *mut PlankTransportNativeStats,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        let Some(stats_out) = (unsafe { stats.as_mut() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if stats_out.struct_size as usize != std::mem::size_of::<PlankTransportNativeStats>() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let stats = &endpoint.shared.stats;
        let fec = *stats.video_fec.lock().unwrap();
        *stats_out = PlankTransportNativeStats {
            struct_size: std::mem::size_of::<PlankTransportNativeStats>() as u32,
            video_frames_sent: stats.video_frames_sent.load(Ordering::Relaxed),
            video_bytes_sent: stats.video_bytes_sent.load(Ordering::Relaxed),
            video_frames_received: stats.video_frames_received.load(Ordering::Relaxed),
            video_bytes_received: stats.video_bytes_received.load(Ordering::Relaxed),
            video_send_drops: stats.video_send_drops.load(Ordering::Relaxed),
            video_receive_drops: stats.video_receive_drops.load(Ordering::Relaxed),
            audio_packets_sent: stats.audio_packets_sent.load(Ordering::Relaxed),
            audio_bytes_sent: stats.audio_bytes_sent.load(Ordering::Relaxed),
            audio_packets_received: stats.audio_packets_received.load(Ordering::Relaxed),
            audio_bytes_received: stats.audio_bytes_received.load(Ordering::Relaxed),
            audio_send_drops: stats.audio_send_drops.load(Ordering::Relaxed),
            audio_receive_drops: stats.audio_receive_drops.load(Ordering::Relaxed),
            input_packets_sent: stats.input_packets_sent.load(Ordering::Relaxed),
            input_packets_received: stats.input_packets_received.load(Ordering::Relaxed),
            data_packets_sent: stats.data_packets_sent.load(Ordering::Relaxed),
            data_packets_received: stats.data_packets_received.load(Ordering::Relaxed),
            quic_rtt_us: stats.quic_rtt_us.load(Ordering::Relaxed),
            quic_packets_lost: stats.quic_packets_lost.load(Ordering::Relaxed),
            kyproto_packets_dropped: stats.kyproto_packets_dropped.load(Ordering::Relaxed),
            video_fec_source_symbols: fec.0,
            video_fec_source_symbols_missing: fec.1,
            video_fec_source_symbols_unrecovered: fec.2,
        };
        PLANK_TRANSPORT_OK
    })
}

fn stop_endpoint(endpoint: &PlankTransportNativeEndpoint) -> i32 {
    let mut worker_slot = endpoint.worker.lock().unwrap();
    let state = endpoint.shared.state();
    if state == EndpointState::Idle {
        endpoint.shared.set_state(EndpointState::Stopped);
    } else if !matches!(state, EndpointState::Stopped | EndpointState::Failed) {
        endpoint.shared.set_state(EndpointState::Stopping);
        endpoint.shared.stop.store(true, Ordering::Release);
        endpoint.shared.notify_all();
    }
    if let Some(worker) = worker_slot.take()
        && worker.join().is_err()
    {
        endpoint.shared.fail("native KyProto worker panicked");
        return PLANK_TRANSPORT_ERROR_PANIC;
    }
    if endpoint.shared.state() != EndpointState::Failed {
        endpoint.shared.set_state(EndpointState::Stopped);
    }
    #[cfg(feature = "sender-timing")]
    endpoint.shared.sender_trace.flush();
    PLANK_TRANSPORT_OK
}

/// # Safety
/// `endpoint` must be null or a live endpoint returned by the create function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_stop(
    endpoint: *mut PlankTransportNativeEndpoint,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        stop_endpoint(endpoint)
    })
}

/// # Safety
/// `endpoint` must be null or a live, not-yet-destroyed endpoint.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_destroy(
    endpoint: *mut PlankTransportNativeEndpoint,
) {
    if endpoint.is_null() {
        return;
    }
    let endpoint = unsafe { Box::from_raw(endpoint) };
    let _ = stop_endpoint(&endpoint);
}

/// # Safety
/// `buffer`, when non-null, must name writable storage of `buffer_size` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_endpoint_last_error(
    endpoint: *const PlankTransportNativeEndpoint,
    buffer: *mut c_char,
    buffer_size: usize,
) -> usize {
    if endpoint.is_null() {
        return 0;
    }
    let error = unsafe { &*endpoint }
        .shared
        .status
        .lock()
        .unwrap()
        .error
        .clone();
    let required = error.len() + 1;
    if !buffer.is_null() && buffer_size != 0 {
        let copy_size = error.len().min(buffer_size - 1);
        unsafe {
            ptr::copy_nonoverlapping(error.as_ptr(), buffer.cast(), copy_size);
            *buffer.add(copy_size) = 0;
        }
    }
    required
}
