// SPDX-License-Identifier: AGPL-3.0-or-later

use anyhow::{Context, Result, anyhow, bail};
use bytes::{BufMut, Bytes, BytesMut};
use kynet::{Connection, Server};
use std::collections::VecDeque;
use std::ffi::{CStr, c_char};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, Once};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use subtle::ConstantTimeEq;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub mod camera;
pub mod microphone;
pub mod native;
pub mod native_ffi;
pub mod rate_control;

pub const PROTOCOL_MAGIC: [u8; 4] = *b"DSM1";
pub const PROTOCOL_VERSION: u16 = 8;
pub const ABI_VERSION: u32 = 13;

const DEFAULT_HANDSHAKE_TIMEOUT_MS: u32 = 10_000;
const DEFAULT_IDLE_TIMEOUT_MS: u32 = 10_000;
const DEFAULT_KEEP_ALIVE_INTERVAL_MS: u32 = 2_000;
const MAX_ADDRESS_LENGTH: usize = 512;
const MAX_SERVER_NAME_LENGTH: usize = 253;
const MAX_PATH_LENGTH: usize = 4_096;
const MAX_TOKEN_LENGTH: usize = 1_024;
const DATAGRAM_HEADER_SIZE: usize = 16;
const VIDEO_LANE: u8 = 1;
const AUDIO_LANE: u8 = 2;
// A single 4K IDR/FEC burst can exceed 64 packets before the Tokio worker is
// scheduled. Keep enough bounded headroom for that burst without allowing an
// unbounded latency queue; 512 maximum-sized packets are under 1 MiB.
const VIDEO_SEND_QUEUE_CAPACITY: usize = 512;
const VIDEO_RECEIVE_QUEUE_CAPACITY: usize = 2_048;
// Eight 5 ms audio packets bound sender-side queueing to 40 ms. Audio is
// always dequeued before video, so reaching this bound means the media path is
// already unable to preserve real-time delivery.
const AUDIO_SEND_QUEUE_CAPACITY: usize = 8;
const AUDIO_RECEIVE_QUEUE_CAPACITY: usize = 64;
const CONTROL_STREAM_MAGIC: [u8; 4] = *b"DSCR";
const CONTROL_STREAM_HEADER_SIZE: usize = 8;
const MAX_CONTROL_PACKET_SIZE: usize = 64 * 1024;
// Control records must never be evicted. A full bounded queue applies
// backpressure to the caller or peer instead of silently losing a command.
const CONTROL_SEND_QUEUE_CAPACITY: usize = 64;
const CONTROL_RECEIVE_QUEUE_CAPACITY: usize = 64;

pub const PLANK_TRANSPORT_OK: i32 = 0;
pub const PLANK_TRANSPORT_TIMEOUT: i32 = 1;
pub const PLANK_TRANSPORT_DROPPED: i32 = 2;
pub const PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT: i32 = -1;
pub const PLANK_TRANSPORT_ERROR_INVALID_STATE: i32 = -2;
pub const PLANK_TRANSPORT_ERROR_RUNTIME: i32 = -3;
pub const PLANK_TRANSPORT_ERROR_PANIC: i32 = -4;
pub const PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL: i32 = -5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ConnectionRole {
    Media = 1,
    Interaction = 2,
}

impl ConnectionRole {
    pub fn name(self) -> &'static str {
        match self {
            Self::Media => "media",
            Self::Interaction => "interaction",
        }
    }
}

impl TryFrom<u8> for ConnectionRole {
    type Error = anyhow::Error;

    fn try_from(value: u8) -> Result<Self> {
        match value {
            value if value == Self::Media as u8 => Ok(Self::Media),
            value if value == Self::Interaction as u8 => Ok(Self::Interaction),
            _ => bail!("unknown connection role {value}"),
        }
    }
}

pub async fn write_auth(stream: &mut kynet::SendStream, token: &str, role: u8) -> Result<()> {
    let token_len: u16 = token
        .len()
        .try_into()
        .context("authentication token is too long")?;
    stream.write_all(&PROTOCOL_MAGIC).await?;
    stream.write_all(&PROTOCOL_VERSION.to_be_bytes()).await?;
    stream.write_all(&[role]).await?;
    stream.write_all(&token_len.to_be_bytes()).await?;
    stream.write_all(token.as_bytes()).await?;
    stream.flush().await?;
    Ok(())
}

pub async fn read_auth(
    stream: &mut kynet::RecvStream,
    expected_token: &str,
) -> Result<ConnectionRole> {
    let mut header = [0_u8; 9];
    stream.read_exact(&mut header).await?;
    if header[..4] != PROTOCOL_MAGIC {
        bail!("authentication magic mismatch");
    }
    let version = u16::from_be_bytes([header[4], header[5]]);
    if version != PROTOCOL_VERSION {
        bail!("unsupported protocol version {version}");
    }
    let role = ConnectionRole::try_from(header[6])?;
    let token_len = u16::from_be_bytes([header[7], header[8]]) as usize;
    if token_len == 0 || token_len > MAX_TOKEN_LENGTH {
        bail!("invalid authentication token length");
    }
    let mut token = vec![0_u8; token_len];
    stream.read_exact(&mut token).await?;
    if token
        .as_slice()
        .ct_eq(expected_token.as_bytes())
        .unwrap_u8()
        != 1
    {
        bail!("authentication token mismatch");
    }
    Ok(role)
}

pub async fn accept_authenticated_candidate(
    server: &kynet::common::CommonServer,
    expected_token: &str,
) -> Result<(
    ConnectionRole,
    Connection,
    kynet::SendStream,
    kynet::RecvStream,
)> {
    let connection = server
        .accept()
        .await?
        .ok_or_else(|| anyhow!("QUIC listener closed"))?;
    let (send, mut recv) = connection.accept_bi().await?;
    let role = match read_auth(&mut recv, expected_token).await {
        Ok(role) => role,
        Err(error) => {
            connection.close(1, "authentication failed");
            return Err(error);
        }
    };
    Ok((role, connection, send, recv))
}

pub async fn connect_with_role_code(
    server_address: SocketAddr,
    server_name: &str,
    options: &kynet::quinn::QuinnClientOptions,
    token: &str,
    role: u8,
    role_name: &str,
) -> Result<(Connection, kynet::SendStream, kynet::RecvStream)> {
    let connection = Connection::quinn_connect(server_address, server_name, None, options).await?;
    let (mut send, mut recv) = connection.open_bi().await?;
    write_auth(&mut send, token, role).await?;
    let mut auth_status = [1_u8; 1];
    recv.read_exact(&mut auth_status).await?;
    if auth_status[0] != 0 {
        connection.close(1, "authentication rejected");
        bail!("server rejected {role_name} authentication");
    }
    Ok((connection, send, recv))
}

pub async fn connect_authenticated(
    server_address: SocketAddr,
    server_name: &str,
    options: &kynet::quinn::QuinnClientOptions,
    token: &str,
    role: ConnectionRole,
) -> Result<(Connection, kynet::SendStream, kynet::RecvStream)> {
    connect_with_role_code(
        server_address,
        server_name,
        options,
        token,
        role as u8,
        role.name(),
    )
    .await
}

fn init_crypto_once() {
    static CRYPTO_INIT: Once = Once::new();
    CRYPTO_INIT.call_once(kynet::init_crypto);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum EndpointState {
    Invalid = 0,
    Idle = 1,
    Starting = 2,
    PeerValidation = 3,
    SetupReady = 4,
    Ready = 5,
    Stopping = 6,
    Stopped = 7,
    Failed = 8,
}

#[derive(Clone)]
enum EndpointConfig {
    Server {
        bind_address: SocketAddr,
        certificate_path: PathBuf,
        private_key_path: PathBuf,
        session_token: String,
        setup_mode: bool,
        options: RuntimeOptions,
    },
    Client {
        remote_address: SocketAddr,
        server_name: String,
        certificate_sha256: Option<String>,
        session_token: String,
        setup_mode: bool,
        options: RuntimeOptions,
    },
}

#[derive(Clone, Copy)]
struct RuntimeOptions {
    handshake_timeout: Duration,
    idle_timeout: Duration,
    keep_alive_interval: Duration,
    max_udp_payload_size: Option<u16>,
    initial_video_bitrate_bps: u64,
}

struct SharedStatus {
    state: EndpointState,
    error: String,
}

#[derive(Default)]
struct MediaQueues {
    video_send: VecDeque<Bytes>,
    video_receive: VecDeque<Bytes>,
    audio_send: VecDeque<Bytes>,
    audio_receive: VecDeque<Bytes>,
}

#[derive(Default)]
struct InteractionQueues {
    control_send: VecDeque<Bytes>,
    control_receive: VecDeque<Bytes>,
}

#[derive(Default)]
struct TransportStats {
    video_packets_sent: AtomicU64,
    video_bytes_sent: AtomicU64,
    video_packets_received: AtomicU64,
    video_bytes_received: AtomicU64,
    video_send_queue_drops: AtomicU64,
    video_receive_queue_drops: AtomicU64,
    video_transport_send_drops: AtomicU64,
    malformed_datagrams: AtomicU64,
    video_send_queue_high_water: AtomicU64,
    video_receive_queue_high_water: AtomicU64,
    audio_packets_sent: AtomicU64,
    audio_bytes_sent: AtomicU64,
    audio_packets_received: AtomicU64,
    audio_bytes_received: AtomicU64,
    audio_send_queue_drops: AtomicU64,
    audio_receive_queue_drops: AtomicU64,
    audio_transport_send_drops: AtomicU64,
    audio_send_queue_high_water: AtomicU64,
    audio_receive_queue_high_water: AtomicU64,
    media_quic_rtt_us: AtomicU64,
    media_quic_packets_lost: AtomicU64,
    control_packets_sent: AtomicU64,
    control_bytes_sent: AtomicU64,
    control_packets_received: AtomicU64,
    control_bytes_received: AtomicU64,
    control_send_queue_full: AtomicU64,
    control_receive_queue_overflow: AtomicU64,
    control_send_queue_high_water: AtomicU64,
    control_receive_queue_high_water: AtomicU64,
    interaction_quic_rtt_us: AtomicU64,
    interaction_quic_packets_lost: AtomicU64,
}

struct Shared {
    status: Mutex<SharedStatus>,
    changed: Condvar,
    stop: AtomicBool,
    stop_notify: tokio::sync::Notify,
    media_queues: Mutex<MediaQueues>,
    media_send_notify: tokio::sync::Notify,
    video_receive_changed: Condvar,
    audio_receive_changed: Condvar,
    interaction_queues: Mutex<InteractionQueues>,
    control_send_notify: tokio::sync::Notify,
    control_receive_changed: Condvar,
    video_sequence: AtomicU64,
    audio_sequence: AtomicU64,
    max_media_packet_size: AtomicUsize,
    stats: TransportStats,
}

impl Shared {
    fn new() -> Self {
        Self {
            status: Mutex::new(SharedStatus {
                state: EndpointState::Idle,
                error: String::new(),
            }),
            changed: Condvar::new(),
            stop: AtomicBool::new(false),
            stop_notify: tokio::sync::Notify::new(),
            media_queues: Mutex::new(MediaQueues::default()),
            media_send_notify: tokio::sync::Notify::new(),
            video_receive_changed: Condvar::new(),
            audio_receive_changed: Condvar::new(),
            interaction_queues: Mutex::new(InteractionQueues::default()),
            control_send_notify: tokio::sync::Notify::new(),
            control_receive_changed: Condvar::new(),
            video_sequence: AtomicU64::new(0),
            audio_sequence: AtomicU64::new(0),
            max_media_packet_size: AtomicUsize::new(0),
            stats: TransportStats::default(),
        }
    }

    fn state(&self) -> EndpointState {
        self.status.lock().unwrap().state
    }

    fn set_state(&self, state: EndpointState) {
        let mut status = self.status.lock().unwrap();
        status.state = state;
        self.changed.notify_all();
    }

    fn fail(&self, error: impl ToString) {
        let mut status = self.status.lock().unwrap();
        status.error = error.to_string();
        status.state = EndpointState::Failed;
        self.changed.notify_all();
        self.video_receive_changed.notify_all();
        self.audio_receive_changed.notify_all();
        self.control_receive_changed.notify_all();
    }
}

#[repr(C)]
pub struct PlankTransportConfig {
    pub struct_size: u32,
    pub abi_version: u32,
    pub mode: u32,
    pub handshake_timeout_ms: u32,
    pub idle_timeout_ms: u32,
    pub keep_alive_interval_ms: u32,
    pub session_mode: u32,
    pub max_udp_payload_size: u32,
    pub initial_video_bitrate_kbps: u32,
    pub bind_address: *const c_char,
    pub remote_address: *const c_char,
    pub server_name: *const c_char,
    pub certificate_path: *const c_char,
    pub private_key_path: *const c_char,
    pub certificate_sha256: *const c_char,
    pub session_token: *const c_char,
}

#[repr(C)]
pub struct PlankTransportStats {
    pub struct_size: u32,
    pub abi_version: u32,
    pub video_packets_sent: u64,
    pub video_bytes_sent: u64,
    pub video_packets_received: u64,
    pub video_bytes_received: u64,
    pub video_send_queue_drops: u64,
    pub video_receive_queue_drops: u64,
    pub video_transport_send_drops: u64,
    pub malformed_datagrams: u64,
    pub video_send_queue_high_water: u64,
    pub video_receive_queue_high_water: u64,
    pub audio_packets_sent: u64,
    pub audio_bytes_sent: u64,
    pub audio_packets_received: u64,
    pub audio_bytes_received: u64,
    pub audio_send_queue_drops: u64,
    pub audio_receive_queue_drops: u64,
    pub audio_transport_send_drops: u64,
    pub audio_send_queue_high_water: u64,
    pub audio_receive_queue_high_water: u64,
    pub media_quic_rtt_us: u64,
    pub media_quic_packets_lost: u64,
    pub control_packets_sent: u64,
    pub control_bytes_sent: u64,
    pub control_packets_received: u64,
    pub control_bytes_received: u64,
    pub control_send_queue_full: u64,
    pub control_receive_queue_overflow: u64,
    pub control_send_queue_high_water: u64,
    pub control_receive_queue_high_water: u64,
    pub interaction_quic_rtt_us: u64,
    pub interaction_quic_packets_lost: u64,
}

pub struct PlankTransportEndpoint {
    config: EndpointConfig,
    mode: u32,
    shared: Arc<Shared>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

unsafe fn required_string(value: *const c_char, field: &str, maximum: usize) -> Result<String> {
    if value.is_null() {
        bail!("{field} is required");
    }
    let value = unsafe { CStr::from_ptr(value) };
    let bytes = value.to_bytes();
    if bytes.is_empty() || bytes.len() > maximum {
        bail!("{field} length is invalid");
    }
    Ok(value
        .to_str()
        .with_context(|| format!("{field} is not UTF-8"))?
        .to_owned())
}

fn configured_duration(value_ms: u32, default_ms: u32, field: &str) -> Result<Duration> {
    let value_ms = if value_ms == 0 { default_ms } else { value_ms };
    if !(100..=120_000).contains(&value_ms) {
        bail!("{field} must be between 100 and 120000 milliseconds");
    }
    Ok(Duration::from_millis(u64::from(value_ms)))
}

fn configured_max_udp_payload_size(value: u32) -> Result<Option<u16>> {
    if value == 0 {
        return Ok(None);
    }
    if !(1200..=65_527).contains(&value) {
        bail!("max_udp_payload_size must be zero or between 1200 and 65527 bytes");
    }
    Ok(Some(value as u16))
}

unsafe fn parse_config(config: *const PlankTransportConfig) -> Result<EndpointConfig> {
    if config.is_null() {
        bail!("config is required");
    }
    let config = unsafe { &*config };
    if config.struct_size as usize != std::mem::size_of::<PlankTransportConfig>() {
        bail!("config structure size mismatch");
    }
    if config.abi_version != ABI_VERSION {
        bail!("unsupported ABI version {}", config.abi_version);
    }
    let options = RuntimeOptions {
        handshake_timeout: configured_duration(
            config.handshake_timeout_ms,
            DEFAULT_HANDSHAKE_TIMEOUT_MS,
            "handshake_timeout_ms",
        )?,
        idle_timeout: configured_duration(
            config.idle_timeout_ms,
            DEFAULT_IDLE_TIMEOUT_MS,
            "idle_timeout_ms",
        )?,
        keep_alive_interval: configured_duration(
            config.keep_alive_interval_ms,
            DEFAULT_KEEP_ALIVE_INTERVAL_MS,
            "keep_alive_interval_ms",
        )?,
        max_udp_payload_size: configured_max_udp_payload_size(config.max_udp_payload_size)?,
        initial_video_bitrate_bps: u64::from(config.initial_video_bitrate_kbps)
            .saturating_mul(1_000),
    };
    if config.session_mode > 1 {
        bail!("unsupported session_mode {}", config.session_mode);
    }
    let setup_mode = config.session_mode == 1;
    if options.keep_alive_interval >= options.idle_timeout {
        bail!("keep_alive_interval_ms must be less than idle_timeout_ms");
    }

    match config.mode {
        1 => {
            let bind_address = unsafe {
                required_string(config.bind_address, "bind_address", MAX_ADDRESS_LENGTH)?
            }
            .parse()
            .context("bind_address is not a socket address")?;
            let certificate_path = PathBuf::from(unsafe {
                required_string(config.certificate_path, "certificate_path", MAX_PATH_LENGTH)?
            });
            let private_key_path = PathBuf::from(unsafe {
                required_string(config.private_key_path, "private_key_path", MAX_PATH_LENGTH)?
            });
            let session_token = unsafe {
                required_string(config.session_token, "session_token", MAX_TOKEN_LENGTH)?
            };
            Ok(EndpointConfig::Server {
                bind_address,
                certificate_path,
                private_key_path,
                session_token,
                setup_mode,
                options,
            })
        }
        2 => {
            let remote_address = unsafe {
                required_string(config.remote_address, "remote_address", MAX_ADDRESS_LENGTH)?
            }
            .parse()
            .context("remote_address is not a socket address")?;
            let server_name = unsafe {
                required_string(config.server_name, "server_name", MAX_SERVER_NAME_LENGTH)?
            };
            let certificate_sha256 = if config.certificate_sha256.is_null() {
                None
            } else {
                let value = unsafe {
                    required_string(config.certificate_sha256, "certificate_sha256", 64)?
                };
                let decoded =
                    hex::decode(&value).context("certificate_sha256 is not valid hexadecimal")?;
                if decoded.len() != 32 {
                    bail!("certificate_sha256 must contain exactly 32 bytes");
                }
                Some(value)
            };
            let session_token = unsafe {
                required_string(config.session_token, "session_token", MAX_TOKEN_LENGTH)?
            };
            Ok(EndpointConfig::Client {
                remote_address,
                server_name,
                certificate_sha256,
                session_token,
                setup_mode,
                options,
            })
        }
        mode => bail!("unsupported endpoint mode {mode}"),
    }
}

type RoleConnection = (Connection, kynet::SendStream, kynet::RecvStream);

fn frame_media_datagram(lane: u8, sequence: u64, prefix: &[u8], payload: &[u8]) -> Bytes {
    let mut packet = BytesMut::with_capacity(DATAGRAM_HEADER_SIZE + prefix.len() + payload.len());
    packet.extend_from_slice(&PROTOCOL_MAGIC);
    packet.put_u8(lane);
    packet.put_u8(0);
    packet.put_u16(DATAGRAM_HEADER_SIZE as u16);
    packet.put_u64(sequence);
    packet.extend_from_slice(prefix);
    packet.extend_from_slice(payload);
    packet.freeze()
}

fn parse_media_datagram(packet: Bytes) -> Option<(u8, Bytes)> {
    if packet.len() <= DATAGRAM_HEADER_SIZE || packet[..4] != PROTOCOL_MAGIC {
        return None;
    }
    let lane = packet[4];
    if !matches!(lane, VIDEO_LANE | AUDIO_LANE) || packet[5] != 0 {
        return None;
    }
    let header_size = u16::from_be_bytes([packet[6], packet[7]]) as usize;
    if header_size != DATAGRAM_HEADER_SIZE || header_size >= packet.len() {
        return None;
    }
    Some((lane, packet.slice(header_size..)))
}

fn pop_next_media_packet(queues: &mut MediaQueues) -> Option<(u8, Bytes)> {
    queues
        .audio_send
        .pop_front()
        .map(|packet| (AUDIO_LANE, packet))
        .or_else(|| {
            queues
                .video_send
                .pop_front()
                .map(|packet| (VIDEO_LANE, packet))
        })
}

async fn send_media_datagrams(shared: Arc<Shared>, connection: Connection) -> Result<()> {
    loop {
        let notified = shared.media_send_notify.notified();
        let packet = pop_next_media_packet(&mut shared.media_queues.lock().unwrap());
        if let Some((lane, packet)) = packet {
            let payload_size = packet.len().saturating_sub(DATAGRAM_HEADER_SIZE) as u64;
            match connection.send_datagram(packet).await {
                Ok(()) => {
                    if lane == AUDIO_LANE {
                        shared
                            .stats
                            .audio_packets_sent
                            .fetch_add(1, Ordering::Relaxed);
                        shared
                            .stats
                            .audio_bytes_sent
                            .fetch_add(payload_size, Ordering::Relaxed);
                    } else {
                        shared
                            .stats
                            .video_packets_sent
                            .fetch_add(1, Ordering::Relaxed);
                        shared
                            .stats
                            .video_bytes_sent
                            .fetch_add(payload_size, Ordering::Relaxed);
                    }
                }
                Err(_) => {
                    if lane == AUDIO_LANE {
                        shared
                            .stats
                            .audio_transport_send_drops
                            .fetch_add(1, Ordering::Relaxed);
                    } else {
                        shared
                            .stats
                            .video_transport_send_drops
                            .fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
            continue;
        }
        if shared.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        notified.await;
    }
}

async fn receive_media_datagrams(shared: Arc<Shared>, connection: Connection) -> Result<()> {
    loop {
        let packet = tokio::select! {
            _ = shared.stop_notify.notified() => return Ok(()),
            result = connection.read_datagram() => result?,
        };
        let Some((lane, payload)) = parse_media_datagram(packet) else {
            shared
                .stats
                .malformed_datagrams
                .fetch_add(1, Ordering::Relaxed);
            continue;
        };
        let payload_size = payload.len() as u64;
        if lane == AUDIO_LANE {
            let (dropped, depth) = {
                let mut queues = shared.media_queues.lock().unwrap();
                let dropped = if queues.audio_receive.len() == AUDIO_RECEIVE_QUEUE_CAPACITY {
                    queues.audio_receive.pop_front();
                    true
                } else {
                    false
                };
                queues.audio_receive.push_back(payload);
                (dropped, queues.audio_receive.len())
            };
            if dropped {
                shared
                    .stats
                    .audio_receive_queue_drops
                    .fetch_add(1, Ordering::Relaxed);
            }
            shared
                .stats
                .audio_receive_queue_high_water
                .fetch_max(depth as u64, Ordering::Relaxed);
            shared
                .stats
                .audio_packets_received
                .fetch_add(1, Ordering::Relaxed);
            shared
                .stats
                .audio_bytes_received
                .fetch_add(payload_size, Ordering::Relaxed);
            shared.audio_receive_changed.notify_one();
        } else {
            let (dropped, depth) = {
                let mut queues = shared.media_queues.lock().unwrap();
                let dropped = if queues.video_receive.len() == VIDEO_RECEIVE_QUEUE_CAPACITY {
                    queues.video_receive.pop_front();
                    true
                } else {
                    false
                };
                queues.video_receive.push_back(payload);
                (dropped, queues.video_receive.len())
            };
            if dropped {
                shared
                    .stats
                    .video_receive_queue_drops
                    .fetch_add(1, Ordering::Relaxed);
            }
            shared
                .stats
                .video_receive_queue_high_water
                .fetch_max(depth as u64, Ordering::Relaxed);
            shared
                .stats
                .video_packets_received
                .fetch_add(1, Ordering::Relaxed);
            shared
                .stats
                .video_bytes_received
                .fetch_add(payload_size, Ordering::Relaxed);
            shared.video_receive_changed.notify_one();
        }
    }
}

fn frame_control_record(payload: &[u8]) -> Bytes {
    let mut record = BytesMut::with_capacity(CONTROL_STREAM_HEADER_SIZE + payload.len());
    record.extend_from_slice(&CONTROL_STREAM_MAGIC);
    record.put_u32(payload.len() as u32);
    record.extend_from_slice(payload);
    record.freeze()
}

async fn send_control_records(shared: Arc<Shared>, mut stream: kynet::SendStream) -> Result<()> {
    loop {
        let notified = shared.control_send_notify.notified();
        let packet = shared
            .interaction_queues
            .lock()
            .unwrap()
            .control_send
            .pop_front();
        if let Some(packet) = packet {
            let payload_size = packet.len().saturating_sub(CONTROL_STREAM_HEADER_SIZE) as u64;
            stream
                .write_all(&packet)
                .await
                .context("failed to write reliable control record")?;
            stream
                .flush()
                .await
                .context("failed to flush reliable control record")?;
            shared
                .stats
                .control_packets_sent
                .fetch_add(1, Ordering::Relaxed);
            shared
                .stats
                .control_bytes_sent
                .fetch_add(payload_size, Ordering::Relaxed);
            continue;
        }
        if shared.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        notified.await;
    }
}

async fn receive_control_records(shared: Arc<Shared>, mut stream: kynet::RecvStream) -> Result<()> {
    loop {
        let mut header = [0_u8; CONTROL_STREAM_HEADER_SIZE];
        let first_byte_count = tokio::select! {
            _ = shared.stop_notify.notified() => return Ok(()),
            result = stream.read(&mut header[..1]) => {
                result.context("failed to begin reliable control header")?
            },
        };
        if first_byte_count == 0 {
            return Ok(());
        }
        tokio::select! {
            _ = shared.stop_notify.notified() => return Ok(()),
            result = stream.read_exact(&mut header[1..]) => {
                result.context("failed to finish reliable control header")?;
            },
        }
        if header[..4] != CONTROL_STREAM_MAGIC {
            bail!("reliable control record magic mismatch");
        }
        let payload_size = u32::from_be_bytes(header[4..8].try_into().unwrap()) as usize;
        if !(2..=MAX_CONTROL_PACKET_SIZE).contains(&payload_size) {
            bail!("invalid reliable control record size {payload_size}");
        }
        let mut payload = vec![0_u8; payload_size];
        tokio::select! {
            _ = shared.stop_notify.notified() => return Ok(()),
            result = stream.read_exact(&mut payload) => {
                result.context("failed to read reliable control payload")?;
            },
        }
        let depth = {
            let mut queues = shared.interaction_queues.lock().unwrap();
            if queues.control_receive.len() == CONTROL_RECEIVE_QUEUE_CAPACITY {
                shared
                    .stats
                    .control_receive_queue_overflow
                    .fetch_add(1, Ordering::Relaxed);
                bail!("reliable control receive queue exhausted");
            }
            queues.control_receive.push_back(Bytes::from(payload));
            queues.control_receive.len()
        };
        shared
            .stats
            .control_receive_queue_high_water
            .fetch_max(depth as u64, Ordering::Relaxed);
        shared
            .stats
            .control_packets_received
            .fetch_add(1, Ordering::Relaxed);
        shared
            .stats
            .control_bytes_received
            .fetch_add(payload_size as u64, Ordering::Relaxed);
        shared.control_receive_changed.notify_one();
    }
}

async fn sample_media_stats(shared: Arc<Shared>, connection: Connection) {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    loop {
        interval.tick().await;
        if shared.stop.load(Ordering::Acquire) {
            return;
        }
        let stats = connection.stats().await;
        shared.stats.media_quic_rtt_us.store(
            stats.rtt.map(|value| value.as_micros() as u64).unwrap_or(0),
            Ordering::Relaxed,
        );
        shared
            .stats
            .media_quic_packets_lost
            .store(stats.packets_lost.unwrap_or(0), Ordering::Relaxed);
    }
}

async fn sample_interaction_stats(shared: Arc<Shared>, connection: Connection) {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    loop {
        interval.tick().await;
        if shared.stop.load(Ordering::Acquire) {
            return;
        }
        let stats = connection.stats().await;
        shared.stats.interaction_quic_rtt_us.store(
            stats.rtt.map(|value| value.as_micros() as u64).unwrap_or(0),
            Ordering::Relaxed,
        );
        shared
            .stats
            .interaction_quic_packets_lost
            .store(stats.packets_lost.unwrap_or(0), Ordering::Relaxed);
    }
}

async fn hold_connections(
    shared: Arc<Shared>,
    media: RoleConnection,
    interaction: RoleConnection,
    server_mode: bool,
) -> Result<()> {
    let (media_connection, _media_send_stream, _media_receive_stream) = media;
    let (interaction_connection, interaction_send_stream, interaction_receive_stream) = interaction;
    let max_datagram_size = media_connection
        .max_datagram_size()
        .ok_or_else(|| anyhow!("peer did not negotiate QUIC DATAGRAM support"))?;
    if max_datagram_size <= DATAGRAM_HEADER_SIZE {
        bail!("negotiated QUIC DATAGRAM size {max_datagram_size} is too small");
    }
    shared
        .max_media_packet_size
        .store(max_datagram_size - DATAGRAM_HEADER_SIZE, Ordering::Release);
    shared.set_state(EndpointState::Ready);
    let payload_shared = shared.clone();
    let payload_connection = media_connection.clone();
    let mut payload_task = tokio::spawn(async move {
        if server_mode {
            send_media_datagrams(payload_shared, payload_connection).await
        } else {
            receive_media_datagrams(payload_shared, payload_connection).await
        }
    });
    let interaction_send_shared = shared.clone();
    let interaction_receive_shared = shared.clone();
    let mut interaction_task = tokio::spawn(async move {
        let mut send_task = Box::pin(send_control_records(
            interaction_send_shared,
            interaction_send_stream,
        ));
        let mut receive_task = Box::pin(receive_control_records(
            interaction_receive_shared,
            interaction_receive_stream,
        ));
        tokio::select! {
            result = &mut send_task => result.context("reliable control sender failed"),
            result = &mut receive_task => result.context("reliable control receiver failed"),
        }
    });
    let mut media_stats_task =
        tokio::spawn(sample_media_stats(shared.clone(), media_connection.clone()));
    let mut interaction_stats_task = tokio::spawn(sample_interaction_stats(
        shared.clone(),
        interaction_connection.clone(),
    ));
    let mut payload_finished = false;
    let mut interaction_finished = false;
    let result = tokio::select! {
        _ = shared.stop_notify.notified() => Ok(()),
        result = media_connection.closed() => {
            result.context("media connection closed")
        },
        result = interaction_connection.closed() => {
            result.context("interaction connection closed")
        },
        result = &mut payload_task => {
            payload_finished = true;
            match result {
                Ok(result) => result.context("video payload task failed"),
                Err(error) => Err(anyhow!("video payload task failed: {error}")),
            }
        },
        result = &mut interaction_task => {
            interaction_finished = true;
            match result {
                Ok(result) => result.context("reliable control task failed"),
                Err(error) => Err(anyhow!("reliable control task failed: {error}")),
            }
        },
    };
    if !payload_finished {
        payload_task.abort();
        let _ = (&mut payload_task).await;
    }
    if !interaction_finished {
        interaction_task.abort();
        let _ = (&mut interaction_task).await;
    }
    media_stats_task.abort();
    let _ = (&mut media_stats_task).await;
    interaction_stats_task.abort();
    let _ = (&mut interaction_stats_task).await;
    media_connection.close(0, "PLANK endpoint stopping");
    interaction_connection.close(0, "PLANK endpoint stopping");
    shared.video_receive_changed.notify_all();
    shared.audio_receive_changed.notify_all();
    shared.control_receive_changed.notify_all();
    result
}

async fn run_server(
    shared: Arc<Shared>,
    bind_address: SocketAddr,
    certificate_path: &Path,
    private_key_path: &Path,
    session_token: &str,
    options: RuntimeOptions,
) -> Result<()> {
    let certificate = kynet::cert::load_cert_from_pem_file(certificate_path).await?;
    let private_key = kynet::cert::load_private_key_from_pem_file(private_key_path).await?;
    let server_options = kynet::common::CommonServerOptions {
        max_idle_timeout: Some(options.idle_timeout),
        keep_alive_interval: Some(options.keep_alive_interval),
        max_udp_payload_size: options.max_udp_payload_size,
        ..Default::default()
    };
    let server = Connection::start_server_on_addr(
        bind_address,
        vec![certificate],
        private_key,
        &server_options,
    )?;
    let deadline = tokio::time::Instant::now() + options.handshake_timeout;
    let mut media = None;
    let mut interaction = None;

    while media.is_none() || interaction.is_none() {
        let candidate = tokio::select! {
            _ = shared.stop_notify.notified() => {
                server.close(0, "PLANK endpoint stopping");
                return Ok(());
            },
            result = tokio::time::timeout_at(
                deadline,
                accept_authenticated_candidate(&server, session_token),
            ) => result.context("timed out waiting for authenticated QUIC roles")?,
        };
        let Ok((role, connection, mut send, recv)) = candidate else {
            if tokio::time::Instant::now() >= deadline {
                bail!("timed out waiting for authenticated QUIC roles");
            }
            continue;
        };
        let slot = match role {
            ConnectionRole::Media => &mut media,
            ConnectionRole::Interaction => &mut interaction,
        };
        if slot.is_some() {
            connection.close(2, "duplicate connection role");
            continue;
        }
        send.write_all(&[0]).await?;
        send.flush().await?;
        *slot = Some((connection, send, recv));
    }

    let result = hold_connections(
        shared.clone(),
        media.expect("media role checked"),
        interaction.expect("interaction role checked"),
        true,
    )
    .await;
    server.close(0, "PLANK endpoint stopping");
    result
}

async fn run_client(
    shared: Arc<Shared>,
    remote_address: SocketAddr,
    server_name: &str,
    certificate_sha256: &str,
    session_token: &str,
    options: RuntimeOptions,
) -> Result<()> {
    let client_options = kynet::quinn::QuinnClientOptions {
        max_idle_timeout: Some(options.idle_timeout),
        keep_alive_interval: Some(options.keep_alive_interval),
        max_udp_payload_size: options.max_udp_payload_size,
        certificate_hash: Some(certificate_sha256.to_owned()),
        ..Default::default()
    };
    let connect = async {
        let media = connect_authenticated(
            remote_address,
            server_name,
            &client_options,
            session_token,
            ConnectionRole::Media,
        )
        .await?;
        let interaction = connect_authenticated(
            remote_address,
            server_name,
            &client_options,
            session_token,
            ConnectionRole::Interaction,
        )
        .await?;
        Ok::<_, anyhow::Error>((media, interaction))
    };
    let (media, interaction) = tokio::select! {
        _ = shared.stop_notify.notified() => return Ok(()),
        result = tokio::time::timeout(options.handshake_timeout, connect) => {
            result.context("timed out establishing authenticated QUIC roles")??
        },
    };
    hold_connections(shared, media, interaction, false).await
}

fn endpoint_worker(config: EndpointConfig, shared: Arc<Shared>) {
    init_crypto_once();
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .thread_name("sc-plank_transport")
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            shared.fail(format!("failed to create transport runtime: {error}"));
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
                    Err(anyhow!("legacy endpoint API does not support setup mode"))
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
                    Err(anyhow!("legacy endpoint API does not support setup mode"))
                } else {
                    run_client(
                        shared.clone(),
                        remote_address,
                        &server_name,
                        certificate_sha256.as_deref().ok_or_else(|| {
                            anyhow!("legacy endpoint requires certificate_sha256")
                        })?,
                        &session_token,
                        options,
                    )
                    .await
                }
            }
        }
    });
    if shared.stop.load(Ordering::Acquire) {
        shared.set_state(EndpointState::Stopped);
    } else if let Err(error) = result {
        shared.fail(error);
    } else {
        shared.set_state(EndpointState::Stopped);
    }
}

fn catch_result(function: impl FnOnce() -> i32) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(function))
        .unwrap_or(PLANK_TRANSPORT_ERROR_PANIC)
}

#[unsafe(no_mangle)]
pub extern "C" fn plank_transport_abi_version() -> u32 {
    ABI_VERSION
}

#[unsafe(no_mangle)]
/// Creates an endpoint and copies its configuration.
///
/// # Safety
/// `config` must point to a valid configuration whose non-null string fields
/// are NUL-terminated. `endpoint_out` must point to writable pointer storage.
pub unsafe extern "C" fn plank_transport_endpoint_create(
    config: *const PlankTransportConfig,
    endpoint_out: *mut *mut PlankTransportEndpoint,
) -> i32 {
    catch_result(|| {
        if endpoint_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        unsafe { *endpoint_out = ptr::null_mut() };
        let mode = if config.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        } else {
            unsafe { (*config).mode }
        };
        let parsed_config = match unsafe { parse_config(config) } {
            Ok(config) => config,
            Err(_) => return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT,
        };
        let endpoint = Box::new(PlankTransportEndpoint {
            config: parsed_config,
            mode,
            shared: Arc::new(Shared::new()),
            worker: Mutex::new(None),
        });
        unsafe { *endpoint_out = Box::into_raw(endpoint) };
        PLANK_TRANSPORT_OK
    })
}

#[unsafe(no_mangle)]
/// Starts the endpoint worker exactly once.
///
/// # Safety
/// `endpoint` must be null or a live handle returned by
/// [`plank_transport_endpoint_create`] that has not been destroyed.
pub unsafe extern "C" fn plank_transport_endpoint_start(endpoint: *mut PlankTransportEndpoint) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        let mut worker = endpoint.worker.lock().unwrap();
        if worker.is_some() || endpoint.shared.state() != EndpointState::Idle {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        endpoint.shared.set_state(EndpointState::Starting);
        let config = endpoint.config.clone();
        let shared = endpoint.shared.clone();
        match std::thread::Builder::new()
            .name("sc-plank_transport-endpoint".to_owned())
            .spawn(move || endpoint_worker(config, shared))
        {
            Ok(handle) => {
                *worker = Some(handle);
                PLANK_TRANSPORT_OK
            }
            Err(error) => {
                endpoint.shared.fail(error);
                PLANK_TRANSPORT_ERROR_RUNTIME
            }
        }
    })
}

#[unsafe(no_mangle)]
/// Waits for the endpoint to become ready or enter a terminal state.
///
/// # Safety
/// `endpoint` must be null or a live handle returned by
/// [`plank_transport_endpoint_create`] that has not been destroyed.
pub unsafe extern "C" fn plank_transport_endpoint_wait_ready(
    endpoint: *mut PlankTransportEndpoint,
    timeout_ms: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        let timeout = Duration::from_millis(u64::from(timeout_ms));
        let status = endpoint.shared.status.lock().unwrap();
        let (status, _) = endpoint
            .shared
            .changed
            .wait_timeout_while(status, timeout, |status| {
                matches!(status.state, EndpointState::Idle | EndpointState::Starting)
            })
            .unwrap();
        match status.state {
            EndpointState::Ready => PLANK_TRANSPORT_OK,
            EndpointState::Idle | EndpointState::Starting => PLANK_TRANSPORT_TIMEOUT,
            EndpointState::Failed => PLANK_TRANSPORT_ERROR_RUNTIME,
            _ => PLANK_TRANSPORT_ERROR_INVALID_STATE,
        }
    })
}

#[unsafe(no_mangle)]
/// Returns the current endpoint state.
///
/// # Safety
/// `endpoint` must be null or a live handle returned by
/// [`plank_transport_endpoint_create`] that has not been destroyed.
pub unsafe extern "C" fn plank_transport_endpoint_state(endpoint: *const PlankTransportEndpoint) -> u32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        unsafe { endpoint.as_ref() }
            .map(|endpoint| endpoint.shared.state() as u32)
            .unwrap_or(EndpointState::Invalid as u32)
    }))
    .unwrap_or(EndpointState::Invalid as u32)
}

#[unsafe(no_mangle)]
/// Returns the negotiated maximum legacy-video packet payload.
///
/// # Safety
/// `endpoint` must be null or a live, non-destroyed endpoint.
pub unsafe extern "C" fn plank_transport_video_max_packet_size(
    endpoint: *const PlankTransportEndpoint,
) -> usize {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        unsafe { endpoint.as_ref() }
            .filter(|endpoint| endpoint.shared.state() == EndpointState::Ready)
            .map(|endpoint| {
                endpoint
                    .shared
                    .max_media_packet_size
                    .load(Ordering::Acquire)
            })
            .unwrap_or(0)
    }))
    .unwrap_or(0)
}

#[unsafe(no_mangle)]
/// Returns the negotiated maximum legacy-audio packet payload.
///
/// # Safety
/// `endpoint` must be null or a live, non-destroyed endpoint.
pub unsafe extern "C" fn plank_transport_audio_max_packet_size(
    endpoint: *const PlankTransportEndpoint,
) -> usize {
    unsafe { plank_transport_video_max_packet_size(endpoint) }
}

unsafe fn submit_media_packet(
    endpoint: *mut PlankTransportEndpoint,
    lane: u8,
    prefix: *const u8,
    prefix_size: usize,
    payload: *const u8,
    payload_size: usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 1 || endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        if (prefix_size != 0 && prefix.is_null()) || (payload_size != 0 && payload.is_null()) {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let packet_size = match prefix_size.checked_add(payload_size) {
            Some(size) if size > 0 => size,
            _ => return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT,
        };
        if packet_size
            > endpoint
                .shared
                .max_media_packet_size
                .load(Ordering::Acquire)
        {
            return PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL;
        }
        let prefix = if prefix_size == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(prefix, prefix_size) }
        };
        let payload = if payload_size == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(payload, payload_size) }
        };
        let sequence = if lane == AUDIO_LANE {
            endpoint
                .shared
                .audio_sequence
                .fetch_add(1, Ordering::Relaxed)
        } else {
            endpoint
                .shared
                .video_sequence
                .fetch_add(1, Ordering::Relaxed)
        };
        let packet = frame_media_datagram(lane, sequence, prefix, payload);
        let (dropped, depth) = if lane == AUDIO_LANE {
            let mut queues = endpoint.shared.media_queues.lock().unwrap();
            let dropped = if queues.audio_send.len() == AUDIO_SEND_QUEUE_CAPACITY {
                queues.audio_send.pop_front();
                true
            } else {
                false
            };
            queues.audio_send.push_back(packet);
            (dropped, queues.audio_send.len())
        } else {
            let mut queues = endpoint.shared.media_queues.lock().unwrap();
            let dropped = if queues.video_send.len() == VIDEO_SEND_QUEUE_CAPACITY {
                queues.video_send.pop_front();
                true
            } else {
                false
            };
            queues.video_send.push_back(packet);
            (dropped, queues.video_send.len())
        };
        if lane == AUDIO_LANE {
            if dropped {
                endpoint
                    .shared
                    .stats
                    .audio_send_queue_drops
                    .fetch_add(1, Ordering::Relaxed);
            }
            endpoint
                .shared
                .stats
                .audio_send_queue_high_water
                .fetch_max(depth as u64, Ordering::Relaxed);
        } else {
            if dropped {
                endpoint
                    .shared
                    .stats
                    .video_send_queue_drops
                    .fetch_add(1, Ordering::Relaxed);
            }
            endpoint
                .shared
                .stats
                .video_send_queue_high_water
                .fetch_max(depth as u64, Ordering::Relaxed);
        }
        endpoint.shared.media_send_notify.notify_one();
        if dropped {
            PLANK_TRANSPORT_DROPPED
        } else {
            PLANK_TRANSPORT_OK
        }
    })
}

#[unsafe(no_mangle)]
/// Copies one video packet into the bounded server send queue.
///
/// # Safety
/// Byte ranges must be readable for their supplied lengths. `endpoint` must
/// be a live, non-destroyed server endpoint.
pub unsafe extern "C" fn plank_transport_video_send(
    endpoint: *mut PlankTransportEndpoint,
    prefix: *const u8,
    prefix_size: usize,
    payload: *const u8,
    payload_size: usize,
) -> i32 {
    unsafe {
        submit_media_packet(
            endpoint,
            VIDEO_LANE,
            prefix,
            prefix_size,
            payload,
            payload_size,
        )
    }
}

#[unsafe(no_mangle)]
/// Copies one audio packet into the priority server send queue.
///
/// # Safety
/// Byte ranges must be readable for their supplied lengths. `endpoint` must
/// be a live, non-destroyed server endpoint.
pub unsafe extern "C" fn plank_transport_audio_send(
    endpoint: *mut PlankTransportEndpoint,
    prefix: *const u8,
    prefix_size: usize,
    payload: *const u8,
    payload_size: usize,
) -> i32 {
    unsafe {
        submit_media_packet(
            endpoint,
            AUDIO_LANE,
            prefix,
            prefix_size,
            payload,
            payload_size,
        )
    }
}

unsafe fn receive_media_packet(
    endpoint: *mut PlankTransportEndpoint,
    lane: u8,
    packet: *mut u8,
    packet_capacity: usize,
    packet_size_out: *mut usize,
    timeout_ms: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 2 || packet_size_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if packet_capacity != 0 && packet.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        unsafe { *packet_size_out = 0 };
        if endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let deadline = Instant::now() + Duration::from_millis(u64::from(timeout_ms));
        let mut queues = endpoint.shared.media_queues.lock().unwrap();
        loop {
            let receive_queue = if lane == AUDIO_LANE {
                &mut queues.audio_receive
            } else {
                &mut queues.video_receive
            };
            if let Some(front) = receive_queue.front() {
                unsafe { *packet_size_out = front.len() };
                if packet_capacity < front.len() {
                    return PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL;
                }
                let packet_data = receive_queue.pop_front().expect("front checked");
                unsafe {
                    ptr::copy_nonoverlapping(packet_data.as_ptr(), packet, packet_data.len());
                }
                return PLANK_TRANSPORT_OK;
            }
            if endpoint.shared.state() != EndpointState::Ready {
                return PLANK_TRANSPORT_ERROR_RUNTIME;
            }
            let now = Instant::now();
            if now >= deadline {
                return PLANK_TRANSPORT_TIMEOUT;
            }
            let receive_changed = if lane == AUDIO_LANE {
                &endpoint.shared.audio_receive_changed
            } else {
                &endpoint.shared.video_receive_changed
            };
            let (next_queues, wait) = receive_changed
                .wait_timeout(queues, deadline - now)
                .unwrap();
            queues = next_queues;
            let is_empty = if lane == AUDIO_LANE {
                queues.audio_receive.is_empty()
            } else {
                queues.video_receive.is_empty()
            };
            if wait.timed_out() && is_empty {
                return PLANK_TRANSPORT_TIMEOUT;
            }
        }
    })
}

#[unsafe(no_mangle)]
/// Waits for and copies one received video packet from the client queue.
///
/// # Safety
/// `packet_size_out` must be writable. When `packet_capacity` is nonzero,
/// `packet` must point to that many writable bytes. `endpoint` must be live.
pub unsafe extern "C" fn plank_transport_video_receive(
    endpoint: *mut PlankTransportEndpoint,
    packet: *mut u8,
    packet_capacity: usize,
    packet_size_out: *mut usize,
    timeout_ms: u32,
) -> i32 {
    unsafe {
        receive_media_packet(
            endpoint,
            VIDEO_LANE,
            packet,
            packet_capacity,
            packet_size_out,
            timeout_ms,
        )
    }
}

#[unsafe(no_mangle)]
/// Waits for and copies one received audio packet from the client queue.
///
/// # Safety
/// `packet_size_out` must be writable. When `packet_capacity` is nonzero,
/// `packet` must point to that many writable bytes. `endpoint` must be live.
pub unsafe extern "C" fn plank_transport_audio_receive(
    endpoint: *mut PlankTransportEndpoint,
    packet: *mut u8,
    packet_capacity: usize,
    packet_size_out: *mut usize,
    timeout_ms: u32,
) -> i32 {
    unsafe {
        receive_media_packet(
            endpoint,
            AUDIO_LANE,
            packet,
            packet_capacity,
            packet_size_out,
            timeout_ms,
        )
    }
}

#[unsafe(no_mangle)]
/// Copies one complete encrypted GameStream control packet into the bounded
/// bidirectional send queue. Full queues apply backpressure and never evict records.
///
/// # Safety
/// `packet` must point to `packet_size` readable bytes. `endpoint` must be a
/// live, non-destroyed endpoint.
pub unsafe extern "C" fn plank_transport_control_send(
    endpoint: *mut PlankTransportEndpoint,
    packet: *const u8,
    packet_size: usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        if packet.is_null() || !(2..=MAX_CONTROL_PACKET_SIZE).contains(&packet_size) {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let payload = unsafe { std::slice::from_raw_parts(packet, packet_size) };
        let record = frame_control_record(payload);
        let depth = {
            let mut queues = endpoint.shared.interaction_queues.lock().unwrap();
            if queues.control_send.len() == CONTROL_SEND_QUEUE_CAPACITY {
                endpoint
                    .shared
                    .stats
                    .control_send_queue_full
                    .fetch_add(1, Ordering::Relaxed);
                return PLANK_TRANSPORT_TIMEOUT;
            }
            queues.control_send.push_back(record);
            queues.control_send.len()
        };
        endpoint
            .shared
            .stats
            .control_send_queue_high_water
            .fetch_max(depth as u64, Ordering::Relaxed);
        endpoint.shared.control_send_notify.notify_one();
        PLANK_TRANSPORT_OK
    })
}

#[unsafe(no_mangle)]
/// Waits for and copies one complete encrypted GameStream control packet from
/// the bounded bidirectional receive queue. An undersized destination leaves the
/// packet queued and reports its required size.
///
/// # Safety
/// `packet_size_out` must be writable. When `packet_capacity` is nonzero,
/// `packet` must point to that many writable bytes. `endpoint` must be live.
pub unsafe extern "C" fn plank_transport_control_receive(
    endpoint: *mut PlankTransportEndpoint,
    packet: *mut u8,
    packet_capacity: usize,
    packet_size_out: *mut usize,
    timeout_ms: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if packet_size_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if packet_capacity != 0 && packet.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        unsafe { *packet_size_out = 0 };
        if endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let deadline = Instant::now() + Duration::from_millis(u64::from(timeout_ms));
        let mut queues = endpoint.shared.interaction_queues.lock().unwrap();
        loop {
            if let Some(front) = queues.control_receive.front() {
                unsafe { *packet_size_out = front.len() };
                if packet_capacity < front.len() {
                    return PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL;
                }
                let packet_data = queues.control_receive.pop_front().expect("front checked");
                unsafe {
                    ptr::copy_nonoverlapping(packet_data.as_ptr(), packet, packet_data.len());
                }
                return PLANK_TRANSPORT_OK;
            }
            if endpoint.shared.state() != EndpointState::Ready {
                return PLANK_TRANSPORT_ERROR_RUNTIME;
            }
            let now = Instant::now();
            if now >= deadline {
                return PLANK_TRANSPORT_TIMEOUT;
            }
            let (next_queues, wait) = endpoint
                .shared
                .control_receive_changed
                .wait_timeout(queues, deadline - now)
                .unwrap();
            queues = next_queues;
            if wait.timed_out() && queues.control_receive.is_empty() {
                return PLANK_TRANSPORT_TIMEOUT;
            }
        }
    })
}

#[unsafe(no_mangle)]
/// Copies a consistent snapshot of endpoint transport counters.
///
/// # Safety
/// `endpoint` must be live and `stats` must point to a writable structure with
/// the exact current size and ABI version initialized by the caller.
pub unsafe extern "C" fn plank_transport_endpoint_stats(
    endpoint: *const PlankTransportEndpoint,
    stats: *mut PlankTransportStats,
) -> i32 {
    catch_result(|| {
        let (Some(endpoint), Some(stats)) =
            (unsafe { endpoint.as_ref() }, unsafe { stats.as_mut() })
        else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if stats.struct_size as usize != std::mem::size_of::<PlankTransportStats>()
            || stats.abi_version != ABI_VERSION
        {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        stats.video_packets_sent = endpoint
            .shared
            .stats
            .video_packets_sent
            .load(Ordering::Relaxed);
        stats.video_bytes_sent = endpoint
            .shared
            .stats
            .video_bytes_sent
            .load(Ordering::Relaxed);
        stats.video_packets_received = endpoint
            .shared
            .stats
            .video_packets_received
            .load(Ordering::Relaxed);
        stats.video_bytes_received = endpoint
            .shared
            .stats
            .video_bytes_received
            .load(Ordering::Relaxed);
        stats.video_send_queue_drops = endpoint
            .shared
            .stats
            .video_send_queue_drops
            .load(Ordering::Relaxed);
        stats.video_receive_queue_drops = endpoint
            .shared
            .stats
            .video_receive_queue_drops
            .load(Ordering::Relaxed);
        stats.video_transport_send_drops = endpoint
            .shared
            .stats
            .video_transport_send_drops
            .load(Ordering::Relaxed);
        stats.malformed_datagrams = endpoint
            .shared
            .stats
            .malformed_datagrams
            .load(Ordering::Relaxed);
        stats.video_send_queue_high_water = endpoint
            .shared
            .stats
            .video_send_queue_high_water
            .load(Ordering::Relaxed);
        stats.video_receive_queue_high_water = endpoint
            .shared
            .stats
            .video_receive_queue_high_water
            .load(Ordering::Relaxed);
        stats.audio_packets_sent = endpoint
            .shared
            .stats
            .audio_packets_sent
            .load(Ordering::Relaxed);
        stats.audio_bytes_sent = endpoint
            .shared
            .stats
            .audio_bytes_sent
            .load(Ordering::Relaxed);
        stats.audio_packets_received = endpoint
            .shared
            .stats
            .audio_packets_received
            .load(Ordering::Relaxed);
        stats.audio_bytes_received = endpoint
            .shared
            .stats
            .audio_bytes_received
            .load(Ordering::Relaxed);
        stats.audio_send_queue_drops = endpoint
            .shared
            .stats
            .audio_send_queue_drops
            .load(Ordering::Relaxed);
        stats.audio_receive_queue_drops = endpoint
            .shared
            .stats
            .audio_receive_queue_drops
            .load(Ordering::Relaxed);
        stats.audio_transport_send_drops = endpoint
            .shared
            .stats
            .audio_transport_send_drops
            .load(Ordering::Relaxed);
        stats.audio_send_queue_high_water = endpoint
            .shared
            .stats
            .audio_send_queue_high_water
            .load(Ordering::Relaxed);
        stats.audio_receive_queue_high_water = endpoint
            .shared
            .stats
            .audio_receive_queue_high_water
            .load(Ordering::Relaxed);
        stats.media_quic_rtt_us = endpoint
            .shared
            .stats
            .media_quic_rtt_us
            .load(Ordering::Relaxed);
        stats.media_quic_packets_lost = endpoint
            .shared
            .stats
            .media_quic_packets_lost
            .load(Ordering::Relaxed);
        stats.control_packets_sent = endpoint
            .shared
            .stats
            .control_packets_sent
            .load(Ordering::Relaxed);
        stats.control_bytes_sent = endpoint
            .shared
            .stats
            .control_bytes_sent
            .load(Ordering::Relaxed);
        stats.control_packets_received = endpoint
            .shared
            .stats
            .control_packets_received
            .load(Ordering::Relaxed);
        stats.control_bytes_received = endpoint
            .shared
            .stats
            .control_bytes_received
            .load(Ordering::Relaxed);
        stats.control_send_queue_full = endpoint
            .shared
            .stats
            .control_send_queue_full
            .load(Ordering::Relaxed);
        stats.control_receive_queue_overflow = endpoint
            .shared
            .stats
            .control_receive_queue_overflow
            .load(Ordering::Relaxed);
        stats.control_send_queue_high_water = endpoint
            .shared
            .stats
            .control_send_queue_high_water
            .load(Ordering::Relaxed);
        stats.control_receive_queue_high_water = endpoint
            .shared
            .stats
            .control_receive_queue_high_water
            .load(Ordering::Relaxed);
        stats.interaction_quic_rtt_us = endpoint
            .shared
            .stats
            .interaction_quic_rtt_us
            .load(Ordering::Relaxed);
        stats.interaction_quic_packets_lost = endpoint
            .shared
            .stats
            .interaction_quic_packets_lost
            .load(Ordering::Relaxed);
        PLANK_TRANSPORT_OK
    })
}

#[unsafe(no_mangle)]
/// Stops the worker and waits for it to exit.
///
/// # Safety
/// `endpoint` must be null or a live handle returned by
/// [`plank_transport_endpoint_create`] that has not been destroyed.
pub unsafe extern "C" fn plank_transport_endpoint_stop(endpoint: *mut PlankTransportEndpoint) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        let state = endpoint.shared.state();
        if state == EndpointState::Idle {
            endpoint.shared.stop.store(true, Ordering::Release);
            endpoint.shared.set_state(EndpointState::Stopped);
            return PLANK_TRANSPORT_OK;
        }
        if matches!(state, EndpointState::Starting | EndpointState::Ready) {
            endpoint.shared.set_state(EndpointState::Stopping);
        }
        endpoint.shared.stop.store(true, Ordering::Release);
        endpoint.shared.stop_notify.notify_waiters();
        endpoint.shared.media_send_notify.notify_waiters();
        endpoint.shared.control_send_notify.notify_waiters();
        endpoint.shared.video_receive_changed.notify_all();
        endpoint.shared.audio_receive_changed.notify_all();
        endpoint.shared.control_receive_changed.notify_all();
        if let Some(worker) = endpoint.worker.lock().unwrap().take()
            && worker.join().is_err()
        {
            endpoint.shared.fail("transport worker panicked");
            return PLANK_TRANSPORT_ERROR_PANIC;
        }
        if endpoint.shared.state() == EndpointState::Failed {
            PLANK_TRANSPORT_ERROR_RUNTIME
        } else {
            endpoint.shared.set_state(EndpointState::Stopped);
            PLANK_TRANSPORT_OK
        }
    })
}

#[unsafe(no_mangle)]
/// Stops and destroys an endpoint.
///
/// # Safety
/// `endpoint` must be null or a live handle returned by
/// [`plank_transport_endpoint_create`]. A non-null handle must be passed exactly
/// once and must not be used concurrently after destruction begins.
pub unsafe extern "C" fn plank_transport_endpoint_destroy(endpoint: *mut PlankTransportEndpoint) {
    if endpoint.is_null() {
        return;
    }
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let endpoint = unsafe { Box::from_raw(endpoint) };
        endpoint.shared.stop.store(true, Ordering::Release);
        endpoint.shared.stop_notify.notify_waiters();
        endpoint.shared.media_send_notify.notify_waiters();
        endpoint.shared.control_send_notify.notify_waiters();
        endpoint.shared.video_receive_changed.notify_all();
        endpoint.shared.audio_receive_changed.notify_all();
        endpoint.shared.control_receive_changed.notify_all();
        if let Some(worker) = endpoint.worker.lock().unwrap().take() {
            let _ = worker.join();
        }
    }));
}

#[unsafe(no_mangle)]
/// Copies the endpoint's last error into caller-owned storage.
///
/// # Safety
/// `endpoint` must be null or a live, non-destroyed endpoint. When `buffer` is
/// non-null and `buffer_size` is nonzero, it must reference at least that many
/// writable bytes.
pub unsafe extern "C" fn plank_transport_endpoint_last_error(
    endpoint: *const PlankTransportEndpoint,
    buffer: *mut c_char,
    buffer_size: usize,
) -> usize {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let error = unsafe { endpoint.as_ref() }
            .map(|endpoint| endpoint.shared.status.lock().unwrap().error.clone())
            .unwrap_or_else(|| "invalid endpoint".to_owned());
        let required = error.len().saturating_add(1);
        if !buffer.is_null() && buffer_size > 0 {
            let copy_length = error.len().min(buffer_size - 1);
            unsafe {
                ptr::copy_nonoverlapping(error.as_ptr(), buffer.cast::<u8>(), copy_length);
                *buffer.add(copy_length) = 0;
            }
        }
        required
    }))
    .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn base_config() -> PlankTransportConfig {
        PlankTransportConfig {
            struct_size: std::mem::size_of::<PlankTransportConfig>() as u32,
            abi_version: ABI_VERSION,
            mode: 0,
            handshake_timeout_ms: 0,
            idle_timeout_ms: 0,
            keep_alive_interval_ms: 0,
            session_mode: 0,
            max_udp_payload_size: 0,
            initial_video_bitrate_kbps: 0,
            bind_address: ptr::null(),
            remote_address: ptr::null(),
            server_name: ptr::null(),
            certificate_path: ptr::null(),
            private_key_path: ptr::null(),
            certificate_sha256: ptr::null(),
            session_token: ptr::null(),
        }
    }

    #[test]
    fn public_header_abi_values_are_stable() {
        assert_eq!(plank_transport_abi_version(), 13);
        assert_eq!(EndpointState::Idle as u32, 1);
        assert_eq!(EndpointState::PeerValidation as u32, 3);
        assert_eq!(EndpointState::SetupReady as u32, 4);
        assert_eq!(EndpointState::Failed as u32, 8);
        assert_eq!(PLANK_TRANSPORT_DROPPED, 2);
        assert_eq!(PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL, -5);
    }

    #[test]
    fn maximum_udp_payload_size_is_bounded_by_quic() {
        assert_eq!(configured_max_udp_payload_size(0).unwrap(), None);
        assert_eq!(configured_max_udp_payload_size(1200).unwrap(), Some(1200));
        assert_eq!(configured_max_udp_payload_size(1344).unwrap(), Some(1344));
        assert_eq!(
            configured_max_udp_payload_size(65_527).unwrap(),
            Some(65_527)
        );
        assert!(configured_max_udp_payload_size(1199).is_err());
        assert!(configured_max_udp_payload_size(65_528).is_err());
    }

    #[test]
    fn reliable_control_record_preserves_complete_packet_bytes() {
        let payload = [0x01, 0x00, 0xaa, 0xbb, 0xcc, 0xdd];
        let record = frame_control_record(&payload);
        assert_eq!(record[..4], CONTROL_STREAM_MAGIC);
        assert_eq!(
            u32::from_be_bytes(record[4..8].try_into().unwrap()) as usize,
            payload.len()
        );
        assert_eq!(&record[CONTROL_STREAM_HEADER_SIZE..], payload);
    }

    #[test]
    fn reliable_control_queue_applies_backpressure_without_eviction() {
        let endpoint = Box::new(PlankTransportEndpoint {
            config: EndpointConfig::Client {
                remote_address: "127.0.0.1:28989".parse().unwrap(),
                server_name: "plank".to_owned(),
                certificate_sha256: Some("00".repeat(32)),
                session_token: "test-token".to_owned(),
                setup_mode: false,
                options: RuntimeOptions {
                    handshake_timeout: Duration::from_secs(1),
                    idle_timeout: Duration::from_secs(1),
                    keep_alive_interval: Duration::from_secs(1),
                    max_udp_payload_size: None,
                    initial_video_bitrate_bps: 0,
                },
            },
            mode: 2,
            shared: Arc::new(Shared::new()),
            worker: Mutex::new(None),
        });
        endpoint.shared.set_state(EndpointState::Ready);
        let endpoint = Box::into_raw(endpoint);
        let packet = [0x01_u8, 0x00, 0xaa, 0xbb];

        for _ in 0..CONTROL_SEND_QUEUE_CAPACITY {
            assert_eq!(
                unsafe { plank_transport_control_send(endpoint, packet.as_ptr(), packet.len()) },
                PLANK_TRANSPORT_OK
            );
        }
        assert_eq!(
            unsafe { plank_transport_control_send(endpoint, packet.as_ptr(), packet.len()) },
            PLANK_TRANSPORT_TIMEOUT
        );

        let endpoint_ref = unsafe { &*endpoint };
        let queues = endpoint_ref.shared.interaction_queues.lock().unwrap();
        assert_eq!(queues.control_send.len(), CONTROL_SEND_QUEUE_CAPACITY);
        assert!(
            queues
                .control_send
                .iter()
                .all(|record| { &record[CONTROL_STREAM_HEADER_SIZE..] == packet.as_slice() })
        );
        drop(queues);
        assert_eq!(
            endpoint_ref
                .shared
                .stats
                .control_send_queue_full
                .load(Ordering::Relaxed),
            1
        );
        assert_eq!(
            endpoint_ref
                .shared
                .stats
                .control_send_queue_high_water
                .load(Ordering::Relaxed),
            CONTROL_SEND_QUEUE_CAPACITY as u64
        );

        unsafe { plank_transport_endpoint_destroy(endpoint) };
    }

    #[test]
    fn media_datagram_preserves_lane_and_existing_packet_bytes() {
        let prefix = [0x10, 0x20, 0x30];
        let payload = [0x40, 0x50, 0x60, 0x70];
        let packet = frame_media_datagram(VIDEO_LANE, 0x0123_4567_89ab_cdef, &prefix, &payload);
        assert_eq!(
            packet.len(),
            DATAGRAM_HEADER_SIZE + prefix.len() + payload.len()
        );
        assert_eq!(packet[..4], PROTOCOL_MAGIC);
        assert_eq!(packet[4], VIDEO_LANE);
        assert_eq!(
            u64::from_be_bytes(packet[8..16].try_into().unwrap()),
            0x0123_4567_89ab_cdef
        );
        assert_eq!(
            parse_media_datagram(packet).unwrap(),
            (
                VIDEO_LANE,
                Bytes::from_static(&[0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70])
            )
        );

        let audio = frame_media_datagram(AUDIO_LANE, 9, &prefix, &payload);
        assert_eq!(
            parse_media_datagram(audio).unwrap(),
            (
                AUDIO_LANE,
                Bytes::from_static(&[0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70])
            )
        );
    }

    #[test]
    fn audio_is_dequeued_before_video() {
        let mut queues = MediaQueues::default();
        queues
            .video_send
            .push_back(Bytes::from_static(b"video-one"));
        queues
            .video_send
            .push_back(Bytes::from_static(b"video-two"));
        queues.audio_send.push_back(Bytes::from_static(b"audio"));

        assert_eq!(
            pop_next_media_packet(&mut queues),
            Some((AUDIO_LANE, Bytes::from_static(b"audio")))
        );
        assert_eq!(
            pop_next_media_packet(&mut queues),
            Some((VIDEO_LANE, Bytes::from_static(b"video-one")))
        );
        assert_eq!(
            pop_next_media_packet(&mut queues),
            Some((VIDEO_LANE, Bytes::from_static(b"video-two")))
        );
    }

    #[test]
    fn malformed_media_datagrams_are_rejected() {
        assert!(parse_media_datagram(Bytes::from_static(b"short")).is_none());
        let mut packet = frame_media_datagram(VIDEO_LANE, 1, &[], b"payload").to_vec();
        packet[4] = 99;
        assert!(parse_media_datagram(Bytes::from(packet)).is_none());
    }

    #[test]
    fn server_config_is_copied_and_validated() {
        let bind = CString::new("127.0.0.1:47489").unwrap();
        let cert = CString::new("/tmp/cert.pem").unwrap();
        let key = CString::new("/tmp/key.pem").unwrap();
        let token = CString::new("session-token").unwrap();
        let mut config = base_config();
        config.mode = 1;
        config.bind_address = bind.as_ptr();
        config.certificate_path = cert.as_ptr();
        config.private_key_path = key.as_ptr();
        config.session_token = token.as_ptr();

        let parsed = unsafe { parse_config(&config) }.unwrap();
        match parsed {
            EndpointConfig::Server { bind_address, .. } => {
                assert_eq!(bind_address, "127.0.0.1:47489".parse().unwrap());
            }
            EndpointConfig::Client { .. } => panic!("unexpected client config"),
        }
    }

    #[test]
    fn client_accepts_profile_validation_or_an_exact_certificate_hash() {
        let remote = CString::new("127.0.0.1:47489").unwrap();
        let name = CString::new("localhost").unwrap();
        let hash = CString::new("00").unwrap();
        let token = CString::new("session-token").unwrap();
        let mut config = base_config();
        config.mode = 2;
        config.remote_address = remote.as_ptr();
        config.server_name = name.as_ptr();
        config.certificate_sha256 = hash.as_ptr();
        config.session_token = token.as_ptr();

        assert!(unsafe { parse_config(&config) }.is_err());

        config.certificate_sha256 = ptr::null();
        let parsed = unsafe { parse_config(&config) }.unwrap();
        match parsed {
            EndpointConfig::Client {
                certificate_sha256, ..
            } => assert!(certificate_sha256.is_none()),
            EndpointConfig::Server { .. } => panic!("unexpected server config"),
        }
    }

    #[test]
    fn create_start_failure_and_destroy_are_safe() {
        let bind = CString::new("127.0.0.1:0").unwrap();
        let cert = CString::new("/definitely/missing/cert.pem").unwrap();
        let key = CString::new("/definitely/missing/key.pem").unwrap();
        let token = CString::new("session-token").unwrap();
        let mut config = base_config();
        config.mode = 1;
        config.bind_address = bind.as_ptr();
        config.certificate_path = cert.as_ptr();
        config.private_key_path = key.as_ptr();
        config.session_token = token.as_ptr();
        let mut endpoint = ptr::null_mut();

        assert_eq!(
            unsafe { plank_transport_endpoint_create(&config, &mut endpoint) },
            PLANK_TRANSPORT_OK
        );
        assert!(!endpoint.is_null());
        assert_eq!(
            unsafe { plank_transport_endpoint_start(endpoint) },
            PLANK_TRANSPORT_OK
        );
        assert_eq!(
            unsafe { plank_transport_endpoint_wait_ready(endpoint, 2_000) },
            PLANK_TRANSPORT_ERROR_RUNTIME
        );
        assert_eq!(
            unsafe { plank_transport_endpoint_state(endpoint) },
            EndpointState::Failed as u32
        );
        let required = unsafe { plank_transport_endpoint_last_error(endpoint, ptr::null_mut(), 0) };
        assert!(required > 1);
        unsafe { plank_transport_endpoint_destroy(endpoint) };
    }

    #[test]
    fn stop_before_start_is_idempotent() {
        let bind = CString::new("127.0.0.1:0").unwrap();
        let cert = CString::new("/tmp/cert.pem").unwrap();
        let key = CString::new("/tmp/key.pem").unwrap();
        let token = CString::new("session-token").unwrap();
        let mut config = base_config();
        config.mode = 1;
        config.bind_address = bind.as_ptr();
        config.certificate_path = cert.as_ptr();
        config.private_key_path = key.as_ptr();
        config.session_token = token.as_ptr();
        let mut endpoint = ptr::null_mut();

        assert_eq!(
            unsafe { plank_transport_endpoint_create(&config, &mut endpoint) },
            PLANK_TRANSPORT_OK
        );
        assert_eq!(
            unsafe { plank_transport_endpoint_stop(endpoint) },
            PLANK_TRANSPORT_OK
        );
        assert_eq!(
            unsafe { plank_transport_endpoint_stop(endpoint) },
            PLANK_TRANSPORT_OK
        );
        unsafe { plank_transport_endpoint_destroy(endpoint) };
    }
}
