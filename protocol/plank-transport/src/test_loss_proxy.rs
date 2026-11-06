// SPDX-License-Identifier: AGPL-3.0-or-later

//! Test-only receiver-side loss injection. Keep socket draining independent of
//! forwarding and the Tokio workers doing encryption and FEC. A bounded ingress
//! FIFO absorbs bursts without changing product sockets or system limits.
//! Report unplanned kernel drops
//! separately: a pass with extra loss still proves recovery, but cannot be
//! described as an exact-loss measurement. Never relax frame assertions.

use std::collections::VecDeque;
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub(super) struct LossProxy {
    pub address: SocketAddr,
    pub loss_basis_points: Arc<AtomicU64>,
    pub forwarded: Arc<AtomicU64>,
    pub dropped: Arc<AtomicU64>,
    return_hold_until_ms: Arc<AtomicU64>,
    pub held_return_packets: Arc<AtomicU64>,
    epoch: Instant,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<io::Result<Option<u64>>>>,
}

// Also stop the scoped reader when forwarding unwinds, before scope joins it.
struct StopReader<'a>(&'a AtomicBool);
impl Drop for StopReader<'_> {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

fn receive_packets(
    socket: &UdpSocket,
    stop: &AtomicBool,
    queued: &AtomicUsize,
    ingress: mpsc::SyncSender<(SocketAddr, Vec<u8>)>,
) -> io::Result<Option<u64>> {
    const MAX_INGRESS_BYTES: usize = 8 * 1024 * 1024;
    let mut buffer = vec![0_u8; 65_535];
    while !stop.load(Ordering::Acquire) {
        let (size, source) = match socket.recv_from(&mut buffer) {
            Ok(packet) => packet,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error),
        };
        if queued.fetch_add(size, Ordering::AcqRel) + size > MAX_INGRESS_BYTES {
            queued.fetch_sub(size, Ordering::Release);
            return Err(io::Error::other(
                "loss proxy exceeded its ingress byte budget",
            ));
        }
        if ingress.try_send((source, buffer[..size].to_vec())).is_err() {
            queued.fetch_sub(size, Ordering::Release);
            if !stop.load(Ordering::Acquire) {
                return Err(io::Error::other("loss proxy ingress queue unavailable"));
            }
            break;
        }
    }
    kernel_drops(socket)
}

impl LossProxy {
    pub fn start(server: SocketAddr) -> io::Result<Self> {
        let socket = UdpSocket::bind("127.0.0.1:0")?;
        // This is solely the measurement proxy, not a product socket. Let the
        // OS cap the request; never change system-wide limits or require root.
        let socket_ref = socket2::SockRef::from(&socket);
        socket_ref.set_recv_buffer_size(4 * 1024 * 1024)?;
        eprintln!(
            "fec_loss_proxy_receive_buffer_bytes={}",
            socket_ref.recv_buffer_size()?
        );
        socket.set_read_timeout(Some(Duration::from_millis(2)))?;
        socket.set_write_timeout(Some(Duration::from_millis(100)))?;
        let address = socket.local_addr()?;
        let loss_basis_points = Arc::new(AtomicU64::new(0));
        let forwarded = Arc::new(AtomicU64::new(0));
        let dropped = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let epoch = Instant::now();
        let return_hold_until_ms = Arc::new(AtomicU64::new(0));
        let held_return_packets = Arc::new(AtomicU64::new(0));
        let hold = return_hold_until_ms.clone();
        let held = held_return_packets.clone();
        let (loss, sent, omitted, stopping) = (
            loss_basis_points.clone(),
            forwarded.clone(),
            dropped.clone(),
            stop.clone(),
        );
        let worker = thread::Builder::new()
            .name("loss-proxy".into())
            .spawn(move || {
                let queued = AtomicUsize::new(0);
                thread::scope(|scope| {
                    // Keep receiving while forwarding or draining held ACKs.
                    // This measurement-only FIFO avoids relying on the OS
                    // accepting our receive-buffer request. Both byte and
                    // packet bounds fail the test rather than hide omissions.
                    let (ingress, packets) = mpsc::sync_channel(4096);
                    let reader = thread::Builder::new()
                        .name("loss-proxy-receive".into())
                        .spawn_scoped(scope, || {
                            receive_packets(&socket, &stopping, &queued, ingress)
                        })?;
                    let stop_reader = StopReader(&stopping);
                    let result: io::Result<()> = (|| {
                        let mut client = None;
                        let mut sequence = 0_u64;
                        let mut pending: VecDeque<(u64, Vec<u8>)> = VecDeque::new();
                        let mut pending_bytes = 0;
                        while !stopping.load(Ordering::Acquire) {
                            let now = epoch.elapsed().as_millis() as u64;
                            while pending.front().is_some_and(|(until, _)| *until <= now) {
                                let (_, packet) = pending.pop_front().unwrap();
                                pending_bytes -= packet.len();
                                if socket.send_to(&packet, server)? != packet.len() {
                                    return Err(io::Error::other(
                                        "delay proxy truncated a return datagram",
                                    ));
                                }
                            }
                            let (source, buffer) =
                                match packets.recv_timeout(Duration::from_millis(2)) {
                                    Ok(packet) => packet,
                                    Err(mpsc::RecvTimeoutError::Timeout) => continue,
                                    Err(mpsc::RecvTimeoutError::Disconnected)
                                        if stopping.load(Ordering::Acquire) =>
                                    {
                                        break;
                                    }
                                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                                        return Err(io::Error::other(
                                            "loss proxy receive worker stopped",
                                        ));
                                    }
                                };
                            let size = buffer.len();
                            queued.fetch_sub(size, Ordering::Release);
                            let destination = if source == server {
                                let Some(client) = client else { continue };
                                sequence = sequence.wrapping_add(1);
                                let loss = loss.load(Ordering::Acquire);
                                // Same evenly distributed omissions as the original fixture;
                                // this is deliberately not a random WAN-loss model.
                                if (sequence % 10_000) * loss % 10_000 < loss {
                                    omitted.fetch_add(1, Ordering::Relaxed);
                                    continue;
                                }
                                client
                            } else {
                                client = Some(source);
                                let until = hold.load(Ordering::Acquire);
                                if until > epoch.elapsed().as_millis() as u64 || !pending.is_empty()
                                {
                                    if pending_bytes + size > 8 * 1024 * 1024 {
                                        return Err(io::Error::other(
                                            "delay proxy exceeded its bounded return queue",
                                        ));
                                    }
                                    let until = until.max(pending.back().map_or(0, |(at, _)| *at));
                                    pending.push_back((until, buffer));
                                    pending_bytes += size;
                                    held.fetch_add(1, Ordering::Relaxed);
                                    continue;
                                }
                                server
                            };
                            let written = socket.send_to(&buffer[..size], destination)?;
                            if written != size {
                                return Err(io::Error::other(
                                    "loss proxy truncated a UDP datagram",
                                ));
                            }
                            if source == server {
                                sent.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                        Ok(())
                    })();
                    drop(stop_reader);
                    let received = reader
                        .join()
                        .map_err(|_| io::Error::other("loss proxy receive worker panicked"))??;
                    result?;
                    Ok(received)
                })
            })?;
        Ok(Self {
            address,
            loss_basis_points,
            forwarded,
            dropped,
            return_hold_until_ms,
            held_return_packets,
            epoch,
            stop,
            worker: Some(worker),
        })
    }

    /// Hold encrypted return-direction packets without dropping or reordering
    /// them. QUIC control travels here too; this is not an ACK-frame parser.
    pub fn hold_return_for(&self, duration: Duration) {
        self.return_hold_until_ms.store(
            (self.epoch.elapsed() + duration).as_millis() as u64,
            Ordering::Release,
        );
    }

    fn join(&mut self) -> io::Result<Option<u64>> {
        self.stop.store(true, Ordering::Release);
        match self.worker.take() {
            Some(worker) => worker
                .join()
                .map_err(|_| io::Error::other("loss proxy panicked"))?,
            None => Ok(None),
        }
    }

    pub fn finish(&mut self) -> Option<u64> {
        let drops = self.join().expect("loss proxy failed");
        eprintln!(
            "fec_loss_proxy_kernel_drops={drops:?} controlled_loss_only={}",
            drops == Some(0)
        );
        drops
    }
}

impl Drop for LossProxy {
    fn drop(&mut self) {
        if self.worker.is_some() {
            // Also report socket drops during assertion unwinding, without a
            // second panic or a detached thread surviving the failed test.
            eprintln!("fec_loss_proxy_cleanup={:?}", self.join());
        }
    }
}

#[test]
fn saturated_ingress_fails_instead_of_silently_dropping() {
    let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    let sender = UdpSocket::bind("127.0.0.1:0").unwrap();
    sender
        .send_to(b"packet", socket.local_addr().unwrap())
        .unwrap();
    let (tx, _rx) = mpsc::sync_channel(0);
    let queued = AtomicUsize::new(0);
    let result = receive_packets(&socket, &AtomicBool::new(false), &queued, tx);
    assert!(
        result
            .unwrap_err()
            .to_string()
            .contains("ingress queue unavailable")
    );
    assert_eq!(queued.load(Ordering::Acquire), 0);
}

#[test]
fn idle_shutdown_joins_both_proxy_workers() {
    let server = UdpSocket::bind("127.0.0.1:0").unwrap();
    let (done, joined) = mpsc::channel();
    let worker = thread::spawn(move || {
        for _ in 0..20 {
            let mut proxy = LossProxy::start(server.local_addr().unwrap()).unwrap();
            // finish() must succeed, not merely join; Drop intentionally only
            // reports failures while unwinding another assertion.
            let _ = proxy.finish();
        }
        done.send(()).unwrap();
    });
    joined
        .recv_timeout(Duration::from_secs(1))
        .expect("proxy shutdown hung");
    worker.join().unwrap();
}

#[test]
fn return_hold_preserves_order_without_blocking_forward_packets() {
    let server = UdpSocket::bind("127.0.0.1:0").unwrap();
    server
        .set_read_timeout(Some(Duration::from_millis(20)))
        .unwrap();
    let client = UdpSocket::bind("127.0.0.1:0").unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut proxy = LossProxy::start(server.local_addr().unwrap()).unwrap();
    client.send_to(b"hello", proxy.address).unwrap();
    let mut buffer = [0; 16];
    server.recv_from(&mut buffer).unwrap();
    proxy.hold_return_for(Duration::from_millis(100));
    client.send_to(b"first", proxy.address).unwrap();
    client.send_to(b"second", proxy.address).unwrap();
    server.send_to(b"forward", proxy.address).unwrap();
    assert_eq!(client.recv_from(&mut buffer).unwrap().0, 7);
    assert_eq!(&buffer[..7], b"forward");
    assert!(matches!(
        server.recv_from(&mut buffer).unwrap_err().kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    ));
    server
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    for expected in [b"first".as_slice(), b"second".as_slice()] {
        let (size, _) = server.recv_from(&mut buffer).unwrap();
        assert_eq!(&buffer[..size], expected);
    }
    assert_eq!(proxy.held_return_packets.load(Ordering::Relaxed), 2);
    proxy.finish();
}

#[cfg(target_os = "linux")]
pub(super) fn kernel_drops(socket: &UdpSocket) -> io::Result<Option<u64>> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::MetadataExt;
    let inode = std::fs::metadata(format!("/proc/self/fd/{}", socket.as_raw_fd()))?.ino();
    let table = std::fs::read_to_string("/proc/net/udp")?;
    parse_kernel_drops(&table, inode).map(Some)
}

#[cfg(target_os = "linux")]
fn parse_kernel_drops(table: &str, inode: u64) -> io::Result<u64> {
    for line in table.lines().skip(1) {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.get(9).and_then(|field| field.parse::<u64>().ok()) == Some(inode) {
            // Linux /proc/net/udp combines the tx/rx and timer fields, leaving
            // the socket inode at column9 and receive drops at column12.
            return fields
                .get(12)
                .and_then(|field| field.parse().ok())
                .ok_or_else(|| io::Error::other("invalid UDP socket drop counter"));
        }
    }
    Err(io::Error::other("loss proxy missing from /proc/net/udp"))
}

#[cfg(not(target_os = "linux"))]
fn kernel_drops(_socket: &UdpSocket) -> io::Result<Option<u64>> {
    // Do not mislabel unavailable per-socket counters as zero on other OSes.
    Ok(None)
}

#[test]
fn proxy_preserves_both_directions_and_omits_exactly_one_in_twenty() {
    let server = UdpSocket::bind("127.0.0.1:0").unwrap();
    server
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let client = UdpSocket::bind("127.0.0.1:0").unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut proxy = LossProxy::start(server.local_addr().unwrap()).unwrap();
    proxy.loss_basis_points.store(500, Ordering::Release);
    client.send_to(b"hello", proxy.address).unwrap();
    let mut buffer = [0; 16];
    assert_eq!(server.recv_from(&mut buffer).unwrap().0, 5);
    assert_eq!(&buffer[..5], b"hello");
    for value in 1..=20_u8 {
        server.send_to(&[value], proxy.address).unwrap();
    }
    for value in 1..20_u8 {
        assert_eq!(client.recv_from(&mut buffer).unwrap().0, 1);
        assert_eq!(buffer[0], value);
    }
    // Finish drains the thread and reads its kernel counter before socket close.
    // Wait for the final deliberately omitted datagram to be observed first.
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while proxy.dropped.load(Ordering::Relaxed) == 0 {
        assert!(std::time::Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
    let drops = proxy.finish();
    #[cfg(target_os = "linux")]
    assert_eq!(drops, Some(0));
    #[cfg(not(target_os = "linux"))]
    assert_eq!(drops, None);
    assert_eq!(proxy.forwarded.load(Ordering::Relaxed), 19);
    assert_eq!(proxy.dropped.load(Ordering::Relaxed), 1);
}

#[cfg(target_os = "linux")]
#[test]
fn socket_counter_selects_exact_inode_and_rejects_missing_data() {
    let table = "header\n1: 0100007F:1234 00000000:0000 07 0:0 0:0 0 1000 0 123 2 0 17\n";
    assert_eq!(parse_kernel_drops(table, 123).unwrap(), 17);
    assert!(parse_kernel_drops(table, 124).is_err());
    assert!(parse_kernel_drops("header\n", 123).is_err());
}
