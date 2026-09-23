// SPDX-License-Identifier: AGPL-3.0-or-later
use super::*;
use std::net::{SocketAddr, UdpSocket};
use std::sync::mpsc;
use std::task::{Context as TaskContext, Poll, Waker};

const STOP_LIMIT: Duration = Duration::from_secs(2);
const TOKEN: &str = "cancellation-loopback-only";

fn options() -> super::super::RuntimeOptions {
    super::super::RuntimeOptions {
        handshake_timeout: Duration::from_secs(30),
        idle_timeout: Duration::from_secs(30),
        keep_alive_interval: Duration::from_secs(1),
        max_udp_payload_size: Some(1344),
        initial_video_bitrate_bps: 150_000_000,
    }
}

pub(super) fn endpoint(address: SocketAddr, host: bool, setup: bool) -> Box<PlankTransportNativeEndpoint> {
    let config = if host {
        EndpointConfig::Server {
            bind_address: address,
            certificate_path: std::env::var_os("SC_NATIVE_TEST_CERTIFICATE")
                .unwrap()
                .into(),
            private_key_path: std::env::var_os("SC_NATIVE_TEST_PRIVATE_KEY")
                .unwrap()
                .into(),
            session_token: TOKEN.into(),
            setup_mode: setup,
            options: options(),
        }
    } else {
        EndpointConfig::Client {
            remote_address: address,
            server_name: "localhost".into(),
            certificate_sha256: (!setup).then(|| {
                std::env::var("SC_NATIVE_TEST_CERTIFICATE_SHA256")
                    .unwrap_or_else(|_| "00".repeat(32))
            }),
            session_token: TOKEN.into(),
            setup_mode: setup,
            options: options(),
        }
    };
    Box::new(PlankTransportNativeEndpoint {
        config,
        mode: if host { 1 } else { 2 },
        shared: Arc::new(NativeShared::new(setup && !host, setup, 150_000_000)),
        worker: Mutex::new(None),
    })
}

fn start(endpoint: &mut PlankTransportNativeEndpoint) {
    assert_eq!(
        unsafe { plank_transport_native_endpoint_start(endpoint) },
        PLANK_TRANSPORT_OK
    );
}

fn stop_checked(mut endpoint: Box<PlankTransportNativeEndpoint>, phase: &str) {
    let (tx, rx) = mpsc::channel();
    let began = Instant::now();
    let worker = std::thread::spawn(move || {
        let result = unsafe { plank_transport_native_endpoint_stop(&mut *endpoint) };
        tx.send((result, endpoint)).unwrap();
    });
    let (result, mut endpoint) = rx
        .recv_timeout(STOP_LIMIT)
        .expect("stop waited for handshake timeout");
    worker.join().unwrap();
    assert_eq!(result, PLANK_TRANSPORT_OK);
    assert_eq!(endpoint.shared.state(), EndpointState::Stopped);
    assert!(endpoint.shared.status.lock().unwrap().error.is_empty());
    assert!(endpoint.worker.lock().unwrap().is_none());
    assert_eq!(
        unsafe { plank_transport_native_endpoint_stop(&mut *endpoint) },
        PLANK_TRANSPORT_OK
    );
    eprintln!(
        "native_cancel_phase={phase} stop_us={}",
        began.elapsed().as_micros()
    );
}

#[tokio::test]
async fn cancellation_is_durable_and_ignores_spurious_notifications() {
    let shared = NativeShared::new(false, false, 150_000_000);
    let mut wait = std::pin::pin!(shared.shutdown_requested());
    let mut cx = TaskContext::from_waker(Waker::noop());
    shared.notify_all();
    assert!(matches!(wait.as_mut().poll(&mut cx), Poll::Pending));
    shared.notify_all();
    assert!(matches!(wait.as_mut().poll(&mut cx), Poll::Pending));
    shared.stop.store(true, Ordering::Release);
    shared.notify_all();
    assert!(matches!(wait.as_mut().poll(&mut cx), Poll::Ready(())));
    // Stop happened before the next phase even created its future.
    shared
        .until_shutdown(async {
            panic!("operation must not be polled after cancellation");
            #[allow(unreachable_code)]
            Ok::<(), anyhow::Error>(())
        })
        .await
        .unwrap();
}

#[tokio::test]
async fn cancellation_drops_the_in_flight_operation() {
    struct Dropped<'a>(&'a AtomicBool);
    impl Drop for Dropped<'_> {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Release);
        }
    }
    let shared = NativeShared::new(false, false, 150_000_000);
    let dropped = AtomicBool::new(false);
    let (tx, rx) = tokio::sync::oneshot::channel();
    let operation = async {
        let _guard = Dropped(&dropped);
        tx.send(()).unwrap();
        std::future::pending::<Result<()>>().await
    };
    let cancel = async {
        rx.await.unwrap();
        shared.stop.store(true, Ordering::Release);
        shared.notify_all();
    };
    let (result, ()) = tokio::join!(shared.until_shutdown(operation), cancel);
    assert!(result.unwrap().is_none());
    assert!(dropped.load(Ordering::Acquire));
}

#[tokio::test]
async fn failure_also_cancels_setup_and_preserves_the_original_error() {
    let shared = NativeShared::new(false, false, 150_000_000);
    shared.fail("original queue failure");
    assert!(
        shared
            .until_shutdown(std::future::pending::<Result<()>>())
            .await
            .unwrap()
            .is_none()
    );
    finish_worker(&shared, Ok(()));
    shared.set_state(EndpointState::Ready);
    assert_eq!(shared.state(), EndpointState::Failed);
    assert_eq!(
        shared.status.lock().unwrap().error,
        "original queue failure"
    );
    let shared = NativeShared::new(false, false, 150_000_000);
    shared.set_state(EndpointState::Stopping);
    shared.set_state(EndpointState::Ready);
    assert_eq!(shared.state(), EndpointState::Stopping);
    shared.set_state(EndpointState::Stopped);
    shared.set_state(EndpointState::Starting);
    assert_eq!(shared.state(), EndpointState::Stopped);
}

#[test]
fn stop_and_destroy_interrupt_real_silent_quic_handshakes() {
    for setup in [false, true] {
        let blackhole = UdpSocket::bind("127.0.0.1:0").unwrap();
        blackhole
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut endpoint = endpoint(blackhole.local_addr().unwrap(), false, setup);
        start(&mut endpoint);
        let mut packet = [0; 2048];
        blackhole
            .recv_from(&mut packet)
            .expect("client did not send its QUIC Initial");
        assert_eq!(endpoint.shared.state(), EndpointState::Starting);
        stop_checked(
            endpoint,
            if setup {
                "setup-client-tls"
            } else {
                "client-tls"
            },
        );

        let mut endpoint = self::endpoint(blackhole.local_addr().unwrap(), false, setup);
        let shared = Arc::downgrade(&endpoint.shared);
        start(&mut endpoint);
        let (tx, rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            unsafe {
                plank_transport_native_endpoint_destroy(Box::into_raw(endpoint));
            }
            tx.send(()).unwrap();
        });
        rx.recv_timeout(STOP_LIMIT)
            .expect("destroy waited for handshake timeout");
        worker.join().unwrap();
        assert!(
            shared.upgrade().is_none(),
            "destroy left the transport worker alive"
        );
    }
}

#[test]
fn simultaneous_start_and_stop_cannot_leave_an_unjoined_worker() {
    let blackhole = UdpSocket::bind("127.0.0.1:0").unwrap();
    for _ in 0..32 {
        let endpoint: Arc<PlankTransportNativeEndpoint> =
            Arc::from(endpoint(blackhole.local_addr().unwrap(), false, true));
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let started = endpoint.clone();
        let start_barrier = barrier.clone();
        let starter = std::thread::spawn(move || {
            start_barrier.wait();
            unsafe { plank_transport_native_endpoint_start(Arc::as_ptr(&started).cast_mut()) }
        });
        let stopped = endpoint.clone();
        let (tx, rx) = mpsc::channel();
        let stopper = std::thread::spawn(move || {
            barrier.wait();
            tx.send(stop_endpoint(&stopped)).unwrap();
        });
        assert_eq!(rx.recv_timeout(STOP_LIMIT).unwrap(), PLANK_TRANSPORT_OK);
        assert!(matches!(
            starter.join().unwrap(),
            PLANK_TRANSPORT_OK | PLANK_TRANSPORT_ERROR_INVALID_STATE
        ));
        stopper.join().unwrap();
        assert_eq!(endpoint.shared.state(), EndpointState::Stopped);
        assert!(endpoint.worker.lock().unwrap().is_none());
    }
}

fn unused_address() -> SocketAddr {
    UdpSocket::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
}

pub(super) async fn wait_state(endpoint: &PlankTransportNativeEndpoint, expected: EndpointState) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let state = endpoint.shared.state();
            assert_ne!(
                state,
                EndpointState::Failed,
                "{}",
                endpoint.shared.status.lock().unwrap().error
            );
            if state == expected {
                break;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .expect("expected endpoint phase was not reached");
}

pub(super) async fn wait_bound(address: SocketAddr, endpoint: &PlankTransportNativeEndpoint) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while UdpSocket::bind(address).is_ok() {
            assert_ne!(endpoint.shared.state(), EndpointState::Failed);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "run through scripts/test/run-plank-transport-native-loopback.sh"]
async fn cancellation_interrupts_real_auth_endpoints_and_promotion() {
    use kynet::Server;

    init_crypto_once();
    let hash = std::env::var("SC_NATIVE_TEST_CERTIFICATE_SHA256").unwrap();
    for setup in [false, true] {
        // Listener waiting for its first peer; the address is reusable on stop.
        let address = unused_address();
        let mut host = endpoint(address, true, setup);
        start(&mut host);
        wait_bound(address, &host).await;
        stop_checked(host, "server-accept");
        drop(UdpSocket::bind(address).expect("stopped server retained its UDP socket"));

        for authenticate in [false, true] {
            // TLS has completed, but the peer withholds either the KyProto
            // authentication record or all endpoint-ready acknowledgements.
            let address = unused_address();
            let mut host = endpoint(address, true, setup);
            start(&mut host);
            wait_bound(address, &host).await;
            let raw = tokio::time::timeout(
                Duration::from_secs(5),
                kynet::Connection::quinn_connect(
                    address,
                    "localhost",
                    None,
                    &kynet::quinn::QuinnClientOptions {
                        certificate_hash: Some(hash.clone()),
                        ..Default::default()
                    },
                ),
            )
            .await
            .unwrap()
            .unwrap();
            let authenticated = if authenticate {
                Some(
                    tokio::time::timeout(
                        Duration::from_secs(5),
                        kyproto::Connection::connect_with_auth(
                            raw.clone(),
                            &kyproto::ClientAuth::new(TOKEN).unwrap(),
                        ),
                    )
                    .await
                    .unwrap()
                    .unwrap(),
                )
            } else {
                None
            };
            stop_checked(
                host,
                if authenticate {
                    "server-endpoint-ready"
                } else {
                    "server-auth"
                },
            );
            // Proves cancellation didn't skip the Host close drain.
            tokio::time::timeout(STOP_LIMIT, raw.closed())
                .await
                .expect("peer did not receive close")
                .ok();
            drop(authenticated);
            drop(UdpSocket::bind(address).expect("stopped server retained its UDP socket"));
        }

        for authenticate in [false, true] {
            // The client also needs to stop promptly after TLS, whether the
            // server withholds authentication or endpoint registration.
            let address = unused_address();
            let certificate = kynet::cert::load_cert_from_pem_file(Path::new(
                &std::env::var("SC_NATIVE_TEST_CERTIFICATE").unwrap(),
            ))
            .await
            .unwrap();
            let key = kynet::cert::load_private_key_from_pem_file(Path::new(
                &std::env::var("SC_NATIVE_TEST_PRIVATE_KEY").unwrap(),
            ))
            .await
            .unwrap();
            let server = kynet::Connection::start_server_on_addr(
                address,
                vec![certificate],
                key,
                &Default::default(),
            )
            .unwrap();
            let mut client = endpoint(address, false, setup);
            start(&mut client);
            let raw = tokio::time::timeout(Duration::from_secs(5), server.accept())
                .await
                .unwrap()
                .unwrap()
                .expect("test server stopped before accepting client");
            let pending = tokio::time::timeout(
                Duration::from_secs(5),
                kyproto::Connection::accept_with_auth(raw),
            )
            .await
            .unwrap()
            .unwrap();
            // Receiving the auth record proves that TLS completed and the
            // client is now blocked waiting for our response.
            let authenticated = if authenticate {
                Some(pending.accept_authentication().await.unwrap())
            } else {
                None
            };
            stop_checked(
                client,
                if authenticate {
                    "client-endpoint-ready"
                } else {
                    "client-auth"
                },
            );
            drop(authenticated);
            server.close(0, "cancellation test complete");
            drain_server(&server).await;
        }
    }

    for stop_host in [false, true] {
        let address = unused_address();
        let mut host = endpoint(address, true, true);
        let mut client = endpoint(address, false, true);
        start(&mut host);
        wait_bound(address, &host).await;
        start(&mut client);
        wait_state(&client, EndpointState::PeerValidation).await;
        if !stop_host {
            stop_checked(client, "peer-certificate-approval");
            // Peer closure may legitimately have failed the other endpoint.
            stop_endpoint(&host);
            continue;
        }
        assert_eq!(
            unsafe { plank_transport_native_endpoint_approve_peer_certificate(&mut *client) },
            PLANK_TRANSPORT_OK
        );
        wait_state(&client, EndpointState::SetupReady).await;
        wait_state(&host, EndpointState::SetupReady).await;
        // Authorize only one side, so promotion cannot finish.
        assert_eq!(
            unsafe { plank_transport_native_endpoint_authorize_session(&mut *host) },
            PLANK_TRANSPORT_OK
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
        stop_checked(host, "server-promotion");
        stop_endpoint(&client);
    }

    // The client promotion path must also observe cancellation.
    let address = unused_address();
    let mut host = endpoint(address, true, true);
    let mut client = endpoint(address, false, true);
    start(&mut host);
    wait_bound(address, &host).await;
    start(&mut client);
    wait_state(&client, EndpointState::PeerValidation).await;
    assert_eq!(
        unsafe { plank_transport_native_endpoint_approve_peer_certificate(&mut *client) },
        PLANK_TRANSPORT_OK
    );
    wait_state(&client, EndpointState::SetupReady).await;
    assert_eq!(
        unsafe { plank_transport_native_endpoint_authorize_session(&mut *client) },
        PLANK_TRANSPORT_OK
    );
    tokio::time::sleep(Duration::from_millis(50)).await;
    stop_checked(client, "client-promotion");
    stop_endpoint(&host);
}
