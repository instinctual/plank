// SPDX-License-Identifier: AGPL-3.0-or-later

//! Isolated, encrypted Quinn comparisons. No product sockets, GPU, credentials,
//! system networking changes or live sessions are involved. The offered load
//! includes equivalent 30% FEC overhead, but this fixture does not run a codec
//! or claim RaptorQ recovery. The native KyProto loss tests cover that separately.

use super::loss_proxy::LossProxy;
use crate::rate_control::{PlankRateControllerFactory, TransportRatePolicy};
use bytes::Bytes;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug)]
enum Stall {
    ReturnPath,
    Consumer,
}

#[derive(Debug)]
struct Received {
    packets: u64,
    last_sequence: u64,
    last_received: Duration,
    maximum_gap: Duration,
    tail_max_latency: Duration,
}

async fn exercise_stall(video_bps: u64, stall: Stall, hold: Duration) {
    crate::init_crypto_once();
    let certificate =
        kynet::cert::load_cert_from_pem_file(std::env::var("SC_NATIVE_TEST_CERTIFICATE").unwrap())
            .await
            .unwrap();
    let key = kynet::cert::load_private_key_from_pem_file(
        std::env::var("SC_NATIVE_TEST_PRIVATE_KEY").unwrap(),
    )
    .await
    .unwrap();
    let mut server_config =
        quinn::ServerConfig::with_single_cert(vec![certificate.clone()], key).unwrap();
    let mut transport = quinn::TransportConfig::default();
    transport.datagram_send_buffer_size(kynet::quinn::DATAGRAM_SEND_BUFFER_BYTES);
    transport
        .initial_mtu(1344)
        .min_mtu(1344)
        .mtu_discovery_config(None);
    transport.max_idle_timeout(Some(Duration::from_secs(10).try_into().unwrap()));
    transport.congestion_controller_factory(PlankRateControllerFactory::new(
        TransportRatePolicy::new(video_bps),
    ));
    server_config.transport_config(Arc::new(transport));
    let server = quinn::Endpoint::server(server_config, "127.0.0.1:0".parse().unwrap()).unwrap();
    let mut proxy = LossProxy::start(server.local_addr().unwrap()).unwrap();
    let mut roots = rustls::RootCertStore::empty();
    roots.add(certificate).unwrap();
    let mut client_config = quinn::ClientConfig::with_root_certificates(Arc::new(roots)).unwrap();
    let mut transport = quinn::TransportConfig::default();
    transport.datagram_send_buffer_size(kynet::quinn::DATAGRAM_SEND_BUFFER_BYTES);
    transport
        .initial_mtu(1344)
        .min_mtu(1344)
        .mtu_discovery_config(None);
    transport.max_idle_timeout(Some(Duration::from_secs(10).try_into().unwrap()));
    client_config.transport_config(Arc::new(transport));
    let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
    client.set_default_client_config(client_config);
    let (sender, receiver) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(
            async { server.accept().await.unwrap().await.unwrap() },
            async {
                client
                    .connect(proxy.address, "localhost")
                    .unwrap()
                    .await
                    .unwrap()
            }
        )
    })
    .await
    .expect("test handshake timed out");

    let epoch = Instant::now();
    let done = Arc::new(AtomicBool::new(false));
    let pause_until_ms = Arc::new(AtomicU64::new(0));
    let read_connection = receiver.clone();
    let read_done = done.clone();
    let read_pause = pause_until_ms.clone();
    let reader = tokio::spawn(async move {
        let mut result = Received {
            packets: 0,
            last_sequence: 0,
            last_received: Duration::ZERO,
            maximum_gap: Duration::ZERO,
            tail_max_latency: Duration::ZERO,
        };
        while !read_done.load(Ordering::Acquire) {
            let pause = Duration::from_millis(read_pause.load(Ordering::Acquire));
            let remaining = pause.saturating_sub(epoch.elapsed());
            if !remaining.is_zero() {
                tokio::time::sleep(remaining).await;
            }
            match tokio::time::timeout(Duration::from_millis(100), read_connection.read_datagram())
                .await
            {
                Err(_) => continue,
                Ok(Err(error)) => panic!("test connection unexpectedly closed: {error}"),
                Ok(Ok(packet)) => {
                    assert!(packet.len() >= 16 && packet[packet.len() - 1] == 0x5a);
                    let sequence = u64::from_le_bytes(packet[..8].try_into().unwrap());
                    let scheduled = Duration::from_micros(u64::from_le_bytes(
                        packet[8..16].try_into().unwrap(),
                    ));
                    let now = epoch.elapsed();
                    if result.packets > 0 {
                        assert!(
                            sequence > result.last_sequence,
                            "proxy unexpectedly reordered data"
                        );
                        result.maximum_gap = result.maximum_gap.max(now - result.last_received);
                    }
                    if scheduled >= Duration::from_millis(3500) {
                        result.tail_max_latency =
                            result.tail_max_latency.max(now.saturating_sub(scheduled));
                    }
                    result.packets += 1;
                    result.last_sequence = sequence;
                    result.last_received = now;
                }
            }
        }
        result
    });

    let mut sequence = 0_u64;
    let mut before = None;
    let mut queue_max = 0;
    let mut submission_lag = Duration::ZERO;
    // 4s at 60Hz. Submit complete frame-sized bursts without slowing the
    // offered schedule when Quinn's existing bounded queue fills.
    let per_frame = (video_bps * 13 / 10 / 8 / 60) as usize;
    for frame in 0..240_u64 {
        let scheduled = Duration::from_nanos(frame * 1_000_000_000 / 60);
        tokio::time::sleep_until((epoch + scheduled).into()).await;
        if frame == 90 {
            before = Some(sender.stats());
            match stall {
                Stall::ReturnPath => proxy.hold_return_for(hold),
                Stall::Consumer => pause_until_ms.store(
                    (epoch.elapsed() + hold).as_millis() as u64,
                    Ordering::Release,
                ),
            }
        }
        let mut remaining = per_frame;
        while remaining > 0 {
            let size = remaining.min(1200);
            // Keep a full header even in the final fragment; its few extra
            // bytes are counted in sent-byte telemetry, not hidden as FEC.
            let mut packet = vec![0x5a; size.max(17)];
            packet[..8].copy_from_slice(&sequence.to_le_bytes());
            packet[8..16].copy_from_slice(&(scheduled.as_micros() as u64).to_le_bytes());
            sender.send_datagram(Bytes::from(packet)).unwrap();
            sequence += 1;
            remaining -= size;
        }
        submission_lag = submission_lag.max(epoch.elapsed().saturating_sub(scheduled));
        queue_max = queue_max.max(sender.stats().plank_telemetry.unwrap().queue_memory_bytes);
    }
    tokio::time::sleep(Duration::from_millis(400)).await;
    done.store(true, Ordering::Release);
    let received = tokio::time::timeout(Duration::from_secs(1), reader)
        .await
        .unwrap()
        .unwrap();
    let before = before.unwrap();
    let stats = sender.stats();
    let receive_stats = receiver.stats();
    let queue = stats.plank_telemetry.unwrap();
    let dropped_before = before.plank_telemetry.unwrap().queue_evicted_datagrams;
    let kernel_drops = proxy.finish();
    sender.close(0_u32.into(), b"diagnostic complete");
    receiver.close(0_u32.into(), b"diagnostic complete");
    server.close(0_u32.into(), b"diagnostic complete");
    client.close(0_u32.into(), b"diagnostic complete");

    eprintln!(
        "stall_comparison mode={stall:?} video_bps={video_bps} hold_ms={} pre_rtt_us={} pre_cwnd={} pre_evicted={dropped_before} evicted={} queue_max={queue_max} queue_limit={} sent={sequence} received={} missing={} transmitted={} arrived={} receiver_discarded={} max_gap_ms={} tail_latency_max_ms={} submit_lag_ms={} held_return={} quic_lost={} proxy_kernel_drops={kernel_drops:?}",
        hold.as_millis(),
        before.path.rtt.as_micros(),
        before.path.cwnd,
        queue.queue_evicted_datagrams,
        queue.queue_limit_bytes,
        received.packets,
        sequence - received.packets,
        stats.frame_tx.datagram,
        receive_stats.frame_rx.datagram,
        receive_stats.frame_rx.datagram - received.packets,
        received.maximum_gap.as_millis(),
        received.tail_max_latency.as_millis(),
        submission_lag.as_millis(),
        proxy.held_return_packets.load(Ordering::Relaxed),
        stats.path.lost_packets
    );
    assert_eq!(
        kernel_drops,
        Some(0),
        "proxy overload invalidated the comparison"
    );
    assert_eq!(proxy.dropped.load(Ordering::Relaxed), 0);
    assert_eq!(
        stats.frame_tx.datagram + queue.queue_evicted_datagrams,
        sequence,
        "submitted datagrams remain unaccounted for after recovery"
    );
    assert_eq!(
        stats.frame_tx.datagram, receive_stats.frame_rx.datagram,
        "unplanned loopback packet loss invalidated the comparison"
    );
    assert_eq!(dropped_before, 0, "clean warm-up already overflowed");
    assert!(before.path.cwnd >= 2 * 1024 * 1024);
    match stall {
        Stall::ReturnPath if hold <= Duration::from_millis(200) => {
            assert_eq!(
                queue.queue_evicted_datagrams, 0,
                "brief ACK hold overflowed"
            );
            assert_eq!(received.packets, sequence, "brief ACK hold lost data");
        }
        Stall::ReturnPath => {
            // A long interruption must actually fill the bounded send queue,
            // so the resumption checks below exercise overflow recovery.
            assert!(queue.queue_evicted_datagrams > 0);
            assert_eq!(receive_stats.frame_rx.datagram, received.packets);
        }
        Stall::Consumer => {
            // A blocked application is a distinct receiver-queue failure. Its
            // QUIC worker still ACKs; increasing the sender window cannot fix it.
            assert_eq!(queue.queue_evicted_datagrams, 0);
            assert!(receive_stats.frame_rx.datagram > received.packets);
        }
    }
    assert!(
        submission_lag < Duration::from_millis(100),
        "sender did not maintain offered load"
    );
    assert_eq!(
        received.last_sequence,
        sequence - 1,
        "connection failed to resume without reconnect"
    );
    assert!(
        received.tail_max_latency < Duration::from_millis(100),
        "backlog persisted after the stall"
    );
    assert_eq!(
        queue.queue_limit_bytes,
        4 * 1024 * 1024,
        "outgoing queue differs from the qualified 4 MiB policy"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "run through scripts/test/run-plank-transport-stalls.sh"]
async fn bounded_window_survives_ack_holds_and_recovers_from_stalls() {
    for (bps, stall, hold_ms) in [
        (50_000_000, Stall::ReturnPath, 200),
        (150_000_000, Stall::ReturnPath, 100),
        (50_000_000, Stall::ReturnPath, 1500),
        (50_000_000, Stall::Consumer, 250),
    ] {
        exercise_stall(bps, stall, Duration::from_millis(hold_ms)).await;
    }
}
