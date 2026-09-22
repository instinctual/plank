// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Standalone PLANK/Kyber QUIC multiplexing qualification probe.

use anyhow::{Context, Result, anyhow, bail};
use bytes::{BufMut, Bytes, BytesMut};
use kynet::Connection;
use plank_transport::{
    ConnectionRole, PROTOCOL_MAGIC, accept_authenticated_candidate as accept_auth_candidate,
    connect_authenticated, connect_with_role_code,
};
use std::collections::{HashMap, VecDeque};
use std::env;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Mutex, Notify};

const DATAGRAM_HEADER_SIZE: usize = 16;
const INPUT_RECORD_SIZE: usize = 16;
const DEFAULT_VIDEO_BITRATE_BPS: u64 = 150_000_000;
const DEFAULT_DURATION_SECS: u64 = 3;
const VIDEO_LANE: u8 = 1;
const AUDIO_LANE: u8 = 2;
const MOTION_LANE: u8 = 3;
const VIDEO_QUEUE_CAPACITY: usize = 64;
const AUDIO_QUEUE_CAPACITY: usize = 8;
#[cfg(feature = "quinn-bbr")]
const CONGESTION_CONTROL: &str = "bbr";
#[cfg(not(feature = "quinn-bbr"))]
const CONGESTION_CONTROL: &str = "cubic";

#[derive(Default)]
struct DatagramCounters {
    video_packets: AtomicU64,
    video_bytes: AtomicU64,
    audio_packets: AtomicU64,
    motion_packets: AtomicU64,
    invalid_packets: AtomicU64,
    blocked_sends: AtomicU64,
    video_sequence_gaps: AtomicU64,
    audio_sequence_gaps: AtomicU64,
    motion_sequence_gaps: AtomicU64,
    stale_datagrams: AtomicU64,
    app_video_queue_drops: AtomicU64,
    app_audio_queue_drops: AtomicU64,
    media_queue_high_water: AtomicU64,
}

#[derive(Debug)]
struct DatagramHeader {
    lane: u8,
    sequence: u64,
}

#[derive(Default)]
struct SequenceTracker {
    latest: Option<u64>,
    gaps: u64,
    stale: u64,
}

impl SequenceTracker {
    fn observe(&mut self, sequence: u64) -> bool {
        let Some(latest) = self.latest else {
            self.latest = Some(sequence);
            return true;
        };
        if sequence <= latest {
            self.stale = self.stale.saturating_add(1);
            return false;
        }
        self.gaps = self
            .gaps
            .saturating_add(sequence.saturating_sub(latest).saturating_sub(1));
        self.latest = Some(sequence);
        true
    }
}

#[derive(Default)]
struct MediaQueue {
    audio: VecDeque<Bytes>,
    video: VecDeque<Bytes>,
}

impl MediaQueue {
    fn push_video(&mut self, packet: Bytes) -> bool {
        let dropped = if self.video.len() == VIDEO_QUEUE_CAPACITY {
            self.video.pop_front();
            true
        } else {
            false
        };
        self.video.push_back(packet);
        dropped
    }

    fn push_audio(&mut self, packet: Bytes) -> bool {
        let dropped = if self.audio.len() == AUDIO_QUEUE_CAPACITY {
            self.audio.pop_front();
            true
        } else {
            false
        };
        self.audio.push_back(packet);
        dropped
    }

    fn pop_next(&mut self) -> Option<(u8, Bytes)> {
        self.audio
            .pop_front()
            .map(|packet| (AUDIO_LANE, packet))
            .or_else(|| self.video.pop_front().map(|packet| (VIDEO_LANE, packet)))
    }

    fn len(&self) -> usize {
        self.audio.len() + self.video.len()
    }
}

fn usage() -> &'static str {
    "usage:\n  plank-probe-plank_transport server <bind-address> <certificate.pem> <key.pem> <token> [duration-seconds] [video-bitrate-bps]\n  plank-probe-plank_transport client <server-address> <server-name> <certificate-sha256> <token> [duration-seconds] [role-order]"
}

fn now_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn make_datagram(lane: u8, sequence: u64, payload_size: usize) -> Bytes {
    let mut packet = BytesMut::with_capacity(DATAGRAM_HEADER_SIZE + payload_size);
    packet.extend_from_slice(&PROTOCOL_MAGIC);
    packet.put_u8(lane);
    packet.put_u8(0);
    packet.put_u16(DATAGRAM_HEADER_SIZE as u16);
    packet.put_u64(sequence);
    packet.resize(DATAGRAM_HEADER_SIZE + payload_size, lane);
    packet.freeze()
}

fn parse_datagram(packet: &Bytes) -> Result<DatagramHeader> {
    if packet.len() < DATAGRAM_HEADER_SIZE {
        bail!("datagram is shorter than the fixed header");
    }
    if packet[..4] != PROTOCOL_MAGIC {
        bail!("datagram magic mismatch");
    }
    let header_size = u16::from_be_bytes([packet[6], packet[7]]) as usize;
    if header_size != DATAGRAM_HEADER_SIZE || header_size > packet.len() {
        bail!("invalid datagram header length");
    }
    Ok(DatagramHeader {
        lane: packet[4],
        sequence: u64::from_be_bytes(packet[8..16].try_into().unwrap()),
    })
}

async fn produce_video(
    queue: Arc<Mutex<MediaQueue>>,
    notify: Arc<Notify>,
    active_producers: Arc<AtomicU64>,
    duration: Duration,
    bitrate_bps: u64,
    packet_size: usize,
    counters: Arc<DatagramCounters>,
) -> Result<()> {
    let payload_size = packet_size - DATAGRAM_HEADER_SIZE;
    let started = Instant::now();
    let mut sequence = 0_u64;
    let mut attempted_bytes = 0_u64;

    while started.elapsed() < duration {
        let target_bytes =
            ((started.elapsed().as_nanos() * bitrate_bps as u128) / 8_000_000_000_u128) as u64;
        if attempted_bytes + packet_size as u64 > target_bytes {
            tokio::time::sleep(Duration::from_micros(100)).await;
            continue;
        }

        let packet = make_datagram(VIDEO_LANE, sequence, payload_size);
        let (dropped, depth) = {
            let mut queue = queue.lock().await;
            let dropped = queue.push_video(packet);
            (dropped, queue.len())
        };
        if dropped {
            counters
                .app_video_queue_drops
                .fetch_add(1, Ordering::Relaxed);
        }
        counters
            .media_queue_high_water
            .fetch_max(depth as u64, Ordering::Relaxed);
        notify.notify_one();
        attempted_bytes += packet_size as u64;
        sequence = sequence.wrapping_add(1);
    }
    active_producers.fetch_sub(1, Ordering::Release);
    notify.notify_one();
    Ok(())
}

async fn produce_audio(
    queue: Arc<Mutex<MediaQueue>>,
    notify: Arc<Notify>,
    active_producers: Arc<AtomicU64>,
    duration: Duration,
    counters: Arc<DatagramCounters>,
) {
    let started = Instant::now();
    let mut interval = tokio::time::interval(Duration::from_millis(5));
    let mut sequence = 0_u64;
    while started.elapsed() < duration {
        interval.tick().await;
        let (dropped, depth) = {
            let mut queue = queue.lock().await;
            let dropped = queue.push_audio(make_datagram(AUDIO_LANE, sequence, 256));
            (dropped, queue.len())
        };
        if dropped {
            counters
                .app_audio_queue_drops
                .fetch_add(1, Ordering::Relaxed);
        }
        counters
            .media_queue_high_water
            .fetch_max(depth as u64, Ordering::Relaxed);
        notify.notify_one();
        sequence = sequence.wrapping_add(1);
    }
    active_producers.fetch_sub(1, Ordering::Release);
    notify.notify_one();
}

async fn send_queued_media(
    connection: Connection,
    queue: Arc<Mutex<MediaQueue>>,
    notify: Arc<Notify>,
    active_producers: Arc<AtomicU64>,
    counters: Arc<DatagramCounters>,
) {
    loop {
        let notified = notify.notified();
        let next = queue.lock().await.pop_next();
        if let Some((lane, packet)) = next {
            let packet_len = packet.len() as u64;
            match connection.send_datagram(packet).await {
                Ok(()) if lane == VIDEO_LANE => {
                    counters.video_packets.fetch_add(1, Ordering::Relaxed);
                    counters
                        .video_bytes
                        .fetch_add(packet_len, Ordering::Relaxed);
                }
                Ok(()) if lane == AUDIO_LANE => {
                    counters.audio_packets.fetch_add(1, Ordering::Relaxed);
                }
                Ok(()) => {
                    counters.invalid_packets.fetch_add(1, Ordering::Relaxed);
                }
                Err(_) => {
                    counters.blocked_sends.fetch_add(1, Ordering::Relaxed);
                }
            }
            continue;
        }
        if active_producers.load(Ordering::Acquire) == 0 {
            break;
        }
        notified.await;
    }
}

async fn run_media_pipeline(
    connection: Connection,
    duration: Duration,
    bitrate_bps: u64,
    counters: Arc<DatagramCounters>,
) -> Result<()> {
    let max_datagram_size = connection
        .max_datagram_size()
        .ok_or_else(|| anyhow!("peer did not negotiate QUIC DATAGRAM support"))?;
    if max_datagram_size <= DATAGRAM_HEADER_SIZE {
        bail!("negotiated datagram size {max_datagram_size} is too small");
    }
    let packet_size = DATAGRAM_HEADER_SIZE + (max_datagram_size - DATAGRAM_HEADER_SIZE).min(1_184);
    let queue = Arc::new(Mutex::new(MediaQueue::default()));
    let notify = Arc::new(Notify::new());
    let active_producers = Arc::new(AtomicU64::new(2));

    let sender = tokio::spawn(send_queued_media(
        connection,
        queue.clone(),
        notify.clone(),
        active_producers.clone(),
        counters.clone(),
    ));
    let video = tokio::spawn(produce_video(
        queue.clone(),
        notify.clone(),
        active_producers.clone(),
        duration,
        bitrate_bps,
        packet_size,
        counters.clone(),
    ));
    let audio = tokio::spawn(produce_audio(
        queue,
        notify,
        active_producers,
        duration,
        counters,
    ));

    video.await??;
    audio.await?;
    sender.await?;
    Ok(())
}

async fn receive_server_datagrams(
    connection: Connection,
    stop: Arc<AtomicBool>,
    counters: Arc<DatagramCounters>,
) {
    let mut motion_sequences = SequenceTracker::default();
    while !stop.load(Ordering::Relaxed) {
        let result =
            tokio::time::timeout(Duration::from_millis(100), connection.read_datagram()).await;
        let Ok(Ok(packet)) = result else {
            continue;
        };
        match parse_datagram(&packet) {
            Ok(header) if header.lane == MOTION_LANE => {
                if motion_sequences.observe(header.sequence) {
                    counters.motion_packets.fetch_add(1, Ordering::Relaxed);
                }
            }
            _ => {
                counters.invalid_packets.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
    counters
        .motion_sequence_gaps
        .store(motion_sequences.gaps, Ordering::Relaxed);
    counters
        .stale_datagrams
        .fetch_add(motion_sequences.stale, Ordering::Relaxed);
}

async fn echo_critical_input(
    mut send: kynet::SendStream,
    mut recv: kynet::RecvStream,
) -> Result<u64> {
    let mut count = 0_u64;
    let mut record = [0_u8; INPUT_RECORD_SIZE];
    loop {
        match recv.read_exact(&mut record).await {
            Ok(_) => {
                send.write_all(&record).await?;
                send.flush().await?;
                count += 1;
            }
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(error) => return Err(error.into()),
        }
    }
    Ok(count)
}

async fn run_server(args: &[String]) -> Result<()> {
    if args.len() < 4 || args.len() > 6 {
        bail!(usage());
    }
    let bind_address: SocketAddr = args[0].parse().context("invalid bind address")?;
    let cert_path = Path::new(&args[1]);
    let key_path = Path::new(&args[2]);
    let expected_token = &args[3];
    let duration = Duration::from_secs(
        args.get(4)
            .map(|value| value.parse())
            .transpose()
            .context("invalid duration")?
            .unwrap_or(DEFAULT_DURATION_SECS),
    );
    let bitrate_bps = args
        .get(5)
        .map(|value| value.parse())
        .transpose()
        .context("invalid video bitrate")?
        .unwrap_or(DEFAULT_VIDEO_BITRATE_BPS);

    let certificate = kynet::cert::load_cert_from_pem_file(cert_path).await?;
    let private_key = kynet::cert::load_private_key_from_pem_file(key_path).await?;
    let options = kynet::common::CommonServerOptions {
        max_idle_timeout: Some(Duration::from_secs(10)),
        keep_alive_interval: Some(Duration::from_secs(2)),
        // Preserve the standalone probe's original transport behavior. Its
        // compile-time feature selects Quinn's default BBR or CUBIC factory,
        // its producer already paces the synthetic media rate, and Quinn owns
        // path-MTU selection for this generic probe.
        max_udp_payload_size: None,
        congestion_controller_factory: None,
    };
    let server =
        Connection::start_server_on_addr(bind_address, vec![certificate], private_key, &options)?;
    println!("status=listening address={bind_address}");

    let mut media = None;
    let mut interaction = None;
    for _ in 0..2 {
        let (role, connection, mut send, recv) =
            accept_auth_candidate(&server, expected_token).await?;
        match role {
            ConnectionRole::Media if media.is_some() => {
                connection.close(2, "duplicate connection role");
                bail!("duplicate media connection role");
            }
            ConnectionRole::Interaction if interaction.is_some() => {
                connection.close(2, "duplicate connection role");
                bail!("duplicate interaction connection role");
            }
            ConnectionRole::Media => {
                send.write_all(&[0]).await?;
                send.flush().await?;
                media = Some((connection, send, recv));
            }
            ConnectionRole::Interaction => {
                send.write_all(&[0]).await?;
                send.flush().await?;
                interaction = Some((connection, send, recv));
            }
        }
    }
    let (media_connection, _media_auth_send, _media_auth_recv) =
        media.ok_or_else(|| anyhow!("missing media connection role"))?;
    let (interaction_connection, input_send, input_recv) =
        interaction.ok_or_else(|| anyhow!("missing interaction connection role"))?;

    let counters = Arc::new(DatagramCounters::default());
    let stop = Arc::new(AtomicBool::new(false));
    let receive_task = tokio::spawn(receive_server_datagrams(
        interaction_connection.clone(),
        stop.clone(),
        counters.clone(),
    ));
    let echo_task = tokio::spawn(echo_critical_input(input_send, input_recv));
    let media_task = tokio::spawn(run_media_pipeline(
        media_connection.clone(),
        duration,
        bitrate_bps,
        counters.clone(),
    ));

    media_task.await??;
    tokio::time::sleep(Duration::from_millis(200)).await;
    stop.store(true, Ordering::Relaxed);
    receive_task.await?;
    let media_stats = media_connection.stats().await;
    let interaction_stats = interaction_connection.stats().await;
    media_connection.close(0, "probe complete");
    interaction_connection.close(0, "probe complete");
    let critical_input = tokio::time::timeout(Duration::from_secs(1), echo_task)
        .await
        .ok()
        .and_then(|result| result.ok())
        .and_then(|result| result.ok())
        .unwrap_or(0);

    println!(
        "status=complete role=server connections=2 congestion_control={CONGESTION_CONTROL} video_packets={} video_bytes={} audio_packets={} motion_packets={} critical_input={} blocked_sends={} invalid_packets={} app_video_queue_drops={} app_audio_queue_drops={} media_queue_high_water={} video_sequence_gaps={} audio_sequence_gaps={} motion_sequence_gaps={} stale_datagrams={} media_quic_rtt_us={} media_quic_packets_lost={} interaction_quic_rtt_us={} interaction_quic_packets_lost={} media_max_datagram_size={} interaction_max_datagram_size={}",
        counters.video_packets.load(Ordering::Relaxed),
        counters.video_bytes.load(Ordering::Relaxed),
        counters.audio_packets.load(Ordering::Relaxed),
        counters.motion_packets.load(Ordering::Relaxed),
        critical_input,
        counters.blocked_sends.load(Ordering::Relaxed),
        counters.invalid_packets.load(Ordering::Relaxed),
        counters.app_video_queue_drops.load(Ordering::Relaxed),
        counters.app_audio_queue_drops.load(Ordering::Relaxed),
        counters.media_queue_high_water.load(Ordering::Relaxed),
        counters.video_sequence_gaps.load(Ordering::Relaxed),
        counters.audio_sequence_gaps.load(Ordering::Relaxed),
        counters.motion_sequence_gaps.load(Ordering::Relaxed),
        counters.stale_datagrams.load(Ordering::Relaxed),
        media_stats.rtt.map(|value| value.as_micros()).unwrap_or(0),
        media_stats.packets_lost.unwrap_or(0),
        interaction_stats
            .rtt
            .map(|value| value.as_micros())
            .unwrap_or(0),
        interaction_stats.packets_lost.unwrap_or(0),
        media_connection.max_datagram_size().unwrap_or(0),
        interaction_connection.max_datagram_size().unwrap_or(0),
    );
    Ok(())
}

async fn receive_client_datagrams(
    connection: Connection,
    duration: Duration,
    counters: Arc<DatagramCounters>,
) {
    let deadline = tokio::time::Instant::now() + duration + Duration::from_millis(400);
    let mut video_sequences = SequenceTracker::default();
    let mut audio_sequences = SequenceTracker::default();
    while tokio::time::Instant::now() < deadline {
        let result =
            tokio::time::timeout(Duration::from_millis(100), connection.read_datagram()).await;
        let Ok(Ok(packet)) = result else {
            continue;
        };
        match parse_datagram(&packet) {
            Ok(header) if header.lane == VIDEO_LANE => {
                if video_sequences.observe(header.sequence) {
                    counters.video_packets.fetch_add(1, Ordering::Relaxed);
                    counters
                        .video_bytes
                        .fetch_add(packet.len() as u64, Ordering::Relaxed);
                }
            }
            Ok(header) if header.lane == AUDIO_LANE => {
                if audio_sequences.observe(header.sequence) {
                    counters.audio_packets.fetch_add(1, Ordering::Relaxed);
                }
            }
            _ => {
                counters.invalid_packets.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
    counters
        .video_sequence_gaps
        .store(video_sequences.gaps, Ordering::Relaxed);
    counters
        .audio_sequence_gaps
        .store(audio_sequences.gaps, Ordering::Relaxed);
    counters.stale_datagrams.store(
        video_sequences.stale.saturating_add(audio_sequences.stale),
        Ordering::Relaxed,
    );
}

async fn send_motion(connection: Connection, duration: Duration, counters: Arc<DatagramCounters>) {
    let started = Instant::now();
    let mut interval = tokio::time::interval(Duration::from_millis(1));
    let mut sequence = 0_u64;
    while started.elapsed() < duration {
        interval.tick().await;
        match connection
            .send_datagram(make_datagram(MOTION_LANE, sequence, 24))
            .await
        {
            Ok(()) => {
                counters.motion_packets.fetch_add(1, Ordering::Relaxed);
            }
            Err(_) => {
                counters.blocked_sends.fetch_add(1, Ordering::Relaxed);
            }
        }
        sequence = sequence.wrapping_add(1);
    }
}

async fn run_input_rtt(
    mut send: kynet::SendStream,
    mut recv: kynet::RecvStream,
    duration: Duration,
) -> Result<(u64, u64, u64)> {
    let sent_times = Arc::new(Mutex::new(HashMap::<u64, u64>::new()));
    let samples = Arc::new(Mutex::new(Vec::<u64>::new()));
    let receiver_times = sent_times.clone();
    let receiver_samples = samples.clone();
    let receiver = tokio::spawn(async move {
        let mut record = [0_u8; INPUT_RECORD_SIZE];
        loop {
            match recv.read_exact(&mut record).await {
                Ok(_) => {
                    let sequence = u64::from_be_bytes(record[..8].try_into().unwrap());
                    let sent_ns = u64::from_be_bytes(record[8..].try_into().unwrap());
                    receiver_times.lock().await.remove(&sequence);
                    receiver_samples
                        .lock()
                        .await
                        .push(now_ns().saturating_sub(sent_ns));
                }
                Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(error) => return Err(anyhow!(error)),
            }
        }
        Ok::<(), anyhow::Error>(())
    });

    let started = Instant::now();
    let mut interval = tokio::time::interval(Duration::from_millis(5));
    let mut sequence = 0_u64;
    while started.elapsed() < duration {
        interval.tick().await;
        let timestamp = now_ns();
        let mut record = [0_u8; INPUT_RECORD_SIZE];
        record[..8].copy_from_slice(&sequence.to_be_bytes());
        record[8..].copy_from_slice(&timestamp.to_be_bytes());
        sent_times.lock().await.insert(sequence, timestamp);
        send.write_all(&record).await?;
        send.flush().await?;
        sequence = sequence.wrapping_add(1);
    }
    send.finish().await?;
    tokio::time::timeout(Duration::from_secs(2), receiver).await???;

    let mut values = samples.lock().await.clone();
    if values.is_empty() {
        bail!("no critical-input RTT samples were echoed");
    }
    values.sort_unstable();
    let p50 = values[values.len() / 2];
    let p99 = values[(values.len() * 99 / 100).min(values.len() - 1)];
    Ok((values.len() as u64, p50, p99))
}

async fn run_client(args: &[String]) -> Result<()> {
    if args.len() < 4 || args.len() > 6 {
        bail!(usage());
    }
    let server_address: SocketAddr = args[0].parse().context("invalid server address")?;
    let server_name = &args[1];
    let certificate_hash = &args[2];
    hex::decode(certificate_hash).context("certificate SHA-256 is not valid hex")?;
    let token = &args[3];
    let duration = Duration::from_secs(
        args.get(4)
            .map(|value| value.parse())
            .transpose()
            .context("invalid duration")?
            .unwrap_or(DEFAULT_DURATION_SECS),
    );
    let role_order = args.get(5).map(String::as_str).unwrap_or("media-first");

    let options = kynet::quinn::QuinnClientOptions {
        max_idle_timeout: Some(Duration::from_secs(10)),
        keep_alive_interval: Some(Duration::from_secs(2)),
        max_udp_payload_size: None,
        certificate_hash: Some(certificate_hash.clone()),
        congestion_controller_factory: None,
    };
    if role_order == "duplicate-media" || role_order == "duplicate-interaction" {
        let duplicate_role = if role_order == "duplicate-media" {
            ConnectionRole::Media
        } else {
            ConnectionRole::Interaction
        };
        let _first =
            connect_authenticated(server_address, server_name, &options, token, duplicate_role)
                .await?;
        let _duplicate =
            connect_authenticated(server_address, server_name, &options, token, duplicate_role)
                .await?;
        bail!(
            "server unexpectedly accepted a duplicate {} role",
            duplicate_role.name()
        );
    }
    if role_order == "mismatched-token" {
        let _media = connect_authenticated(
            server_address,
            server_name,
            &options,
            token,
            ConnectionRole::Media,
        )
        .await?;
        let other_token = format!("{token}-other-session");
        let _interaction = connect_authenticated(
            server_address,
            server_name,
            &options,
            &other_token,
            ConnectionRole::Interaction,
        )
        .await?;
        bail!("server unexpectedly accepted mismatched session tokens");
    }
    if role_order == "unknown-role" {
        let _unknown = connect_with_role_code(
            server_address,
            server_name,
            &options,
            token,
            u8::MAX,
            "unknown",
        )
        .await?;
        bail!("server unexpectedly accepted an unknown role");
    }

    let (media, interaction) = match role_order {
        "media-first" => {
            let media = connect_authenticated(
                server_address,
                server_name,
                &options,
                token,
                ConnectionRole::Media,
            )
            .await?;
            let interaction = connect_authenticated(
                server_address,
                server_name,
                &options,
                token,
                ConnectionRole::Interaction,
            )
            .await?;
            (media, interaction)
        }
        "interaction-first" => {
            let interaction = connect_authenticated(
                server_address,
                server_name,
                &options,
                token,
                ConnectionRole::Interaction,
            )
            .await?;
            let media = connect_authenticated(
                server_address,
                server_name,
                &options,
                token,
                ConnectionRole::Media,
            )
            .await?;
            (media, interaction)
        }
        _ => bail!("unknown role order {role_order}"),
    };
    let (media_connection, _media_auth_send, _media_auth_recv) = media;
    let (interaction_connection, input_send, input_recv) = interaction;

    let counters = Arc::new(DatagramCounters::default());
    let receive_task = tokio::spawn(receive_client_datagrams(
        media_connection.clone(),
        duration,
        counters.clone(),
    ));
    let motion_task = tokio::spawn(send_motion(
        interaction_connection.clone(),
        duration,
        counters.clone(),
    ));
    let input_task = tokio::spawn(run_input_rtt(input_send, input_recv, duration));

    motion_task.await?;
    let (input_samples, input_rtt_p50_ns, input_rtt_p99_ns) = input_task.await??;
    receive_task.await?;
    let media_stats = media_connection.stats().await;
    let interaction_stats = interaction_connection.stats().await;
    media_connection.close(0, "probe complete");
    interaction_connection.close(0, "probe complete");

    let elapsed_seconds = duration.as_secs_f64();
    let received_bitrate =
        counters.video_bytes.load(Ordering::Relaxed) as f64 * 8.0 / elapsed_seconds;
    println!(
        "status=complete role=client connections=2 congestion_control={CONGESTION_CONTROL} video_packets={} video_bytes={} received_video_bitrate_bps={received_bitrate:.0} audio_packets={} motion_packets={} input_samples={} input_rtt_p50_us={:.1} input_rtt_p99_us={:.1} blocked_sends={} invalid_packets={} app_video_queue_drops={} app_audio_queue_drops={} media_queue_high_water={} video_sequence_gaps={} audio_sequence_gaps={} motion_sequence_gaps={} stale_datagrams={} media_quic_rtt_us={} media_quic_packets_lost={} interaction_quic_rtt_us={} interaction_quic_packets_lost={} media_max_datagram_size={} interaction_max_datagram_size={}",
        counters.video_packets.load(Ordering::Relaxed),
        counters.video_bytes.load(Ordering::Relaxed),
        counters.audio_packets.load(Ordering::Relaxed),
        counters.motion_packets.load(Ordering::Relaxed),
        input_samples,
        input_rtt_p50_ns as f64 / 1_000.0,
        input_rtt_p99_ns as f64 / 1_000.0,
        counters.blocked_sends.load(Ordering::Relaxed),
        counters.invalid_packets.load(Ordering::Relaxed),
        counters.app_video_queue_drops.load(Ordering::Relaxed),
        counters.app_audio_queue_drops.load(Ordering::Relaxed),
        counters.media_queue_high_water.load(Ordering::Relaxed),
        counters.video_sequence_gaps.load(Ordering::Relaxed),
        counters.audio_sequence_gaps.load(Ordering::Relaxed),
        counters.motion_sequence_gaps.load(Ordering::Relaxed),
        counters.stale_datagrams.load(Ordering::Relaxed),
        media_stats.rtt.map(|value| value.as_micros()).unwrap_or(0),
        media_stats.packets_lost.unwrap_or(0),
        interaction_stats
            .rtt
            .map(|value| value.as_micros())
            .unwrap_or(0),
        interaction_stats.packets_lost.unwrap_or(0),
        media_connection.max_datagram_size().unwrap_or(0),
        interaction_connection.max_datagram_size().unwrap_or(0),
    );
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    kynet::init_crypto();
    let args: Vec<String> = env::args().skip(1).collect();
    let Some((mode, remaining)) = args.split_first() else {
        bail!(usage());
    };
    match mode.as_str() {
        "server" => run_server(remaining).await,
        "client" => run_client(remaining).await,
        _ => bail!(usage()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datagram_header_round_trip() {
        let packet = make_datagram(MOTION_LANE, 0x0123_4567_89ab_cdef, 32);
        let header = parse_datagram(&packet).unwrap();
        assert_eq!(header.lane, MOTION_LANE);
        assert_eq!(header.sequence, 0x0123_4567_89ab_cdef);
        assert_eq!(packet.len(), DATAGRAM_HEADER_SIZE + 32);
    }

    #[test]
    fn short_datagram_is_rejected() {
        assert!(parse_datagram(&Bytes::from_static(b"DSM1")).is_err());
    }

    #[test]
    fn incorrect_magic_is_rejected() {
        let mut packet = make_datagram(VIDEO_LANE, 1, 0).to_vec();
        packet[0] = b'X';
        assert!(parse_datagram(&Bytes::from(packet)).is_err());
    }

    #[test]
    fn incorrect_header_size_is_rejected() {
        let mut packet = make_datagram(AUDIO_LANE, 2, 0).to_vec();
        packet[6..8].copy_from_slice(&15_u16.to_be_bytes());
        assert!(parse_datagram(&Bytes::from(packet)).is_err());
    }

    #[test]
    fn sequence_tracker_counts_gaps_and_rejects_stale_state() {
        let mut tracker = SequenceTracker::default();

        assert!(tracker.observe(10));
        assert!(tracker.observe(13));
        assert!(!tracker.observe(12));
        assert!(!tracker.observe(13));
        assert!(tracker.observe(14));

        assert_eq!(tracker.latest, Some(14));
        assert_eq!(tracker.gaps, 2);
        assert_eq!(tracker.stale, 2);
    }

    #[test]
    fn connection_roles_reject_unknown_values() {
        assert_eq!(ConnectionRole::try_from(1).unwrap(), ConnectionRole::Media);
        assert_eq!(
            ConnectionRole::try_from(2).unwrap(),
            ConnectionRole::Interaction
        );
        assert!(ConnectionRole::try_from(0).is_err());
        assert!(ConnectionRole::try_from(u8::MAX).is_err());
    }

    #[test]
    fn media_queue_is_bounded_fresh_and_audio_first() {
        let mut queue = MediaQueue::default();
        for sequence in 0..VIDEO_QUEUE_CAPACITY as u64 {
            assert!(!queue.push_video(make_datagram(VIDEO_LANE, sequence, 1)));
        }
        assert!(queue.push_video(make_datagram(VIDEO_LANE, VIDEO_QUEUE_CAPACITY as u64, 1)));
        assert!(!queue.push_audio(make_datagram(AUDIO_LANE, 77, 1)));

        let (lane, audio) = queue.pop_next().unwrap();
        assert_eq!(lane, AUDIO_LANE);
        assert_eq!(parse_datagram(&audio).unwrap().sequence, 77);

        let (lane, video) = queue.pop_next().unwrap();
        assert_eq!(lane, VIDEO_LANE);
        assert_eq!(parse_datagram(&video).unwrap().sequence, 1);
        assert_eq!(queue.len(), VIDEO_QUEUE_CAPACITY - 1);

        let mut audio_queue = MediaQueue::default();
        for sequence in 0..AUDIO_QUEUE_CAPACITY as u64 {
            assert!(!audio_queue.push_audio(make_datagram(AUDIO_LANE, sequence, 1)));
        }
        assert!(audio_queue.push_audio(make_datagram(AUDIO_LANE, AUDIO_QUEUE_CAPACITY as u64, 1)));
        let (_, first_audio) = audio_queue.pop_next().unwrap();
        assert_eq!(parse_datagram(&first_audio).unwrap().sequence, 1);
    }
}
