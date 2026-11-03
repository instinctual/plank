// SPDX-License-Identifier: AGPL-3.0-or-later

use super::*;

// Exercise the actual encrypted data lane and the FFI consumer in both
// directions. A bounded application queue must survive a delivery burst and
// preserve FIFO order after the consumer resumes, rather than fail the session.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "run through scripts/test/run-plank-transport-native-loopback.sh"]
async fn reliable_data_backpressure_recovers_both_receivers() {
    init_crypto_once();
    let certificate_path = std::env::var("SC_NATIVE_TEST_CERTIFICATE").unwrap();
    let private_key_path = std::env::var("SC_NATIVE_TEST_PRIVATE_KEY").unwrap();
    for receiving_host in [true, false] {
        for payload_size in [32, MAX_DATA_PACKET_SIZE] {
            let certificate = kynet::cert::load_cert_from_pem_file(Path::new(&certificate_path))
                .await
                .unwrap();
            let key = kynet::cert::load_private_key_from_pem_file(Path::new(&private_key_path))
                .await
                .unwrap();
            let reservation = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
            let address = reservation.local_addr().unwrap();
            drop(reservation);
            let options = NativeOptions {
                handshake_timeout: Duration::from_secs(5),
                idle_timeout: Duration::from_secs(10),
                keep_alive_interval: Duration::from_secs(1),
                max_udp_payload_size: Some(1344),
            };
            let server = kynet::Connection::start_server_on_addr(
                address,
                vec![certificate],
                key,
                &Default::default(),
            )
            .unwrap();
            let (host, client) = tokio::join!(
                native::accept_setup_server(&server, "data-pressure-test", options),
                native::connect_setup_client(address, "localhost", "data-pressure-test", options),
            );
            let (host_connection, host_data) = host.unwrap().into_parts();
            let (client_connection, client_data, _) = client.unwrap().into_parts();
            let (mut send, recv) = if receiving_host {
                (client_data.0, host_data.1)
            } else {
                (host_data.0, client_data.1)
            };
            let mut endpoint = endpoint(EndpointState::SetupReady);
            let shared = endpoint.shared.clone();
            let receiving = shared.clone();
            let receiver = tokio::spawn(async move {
                receiving
                    .until_shutdown(receive_data(receiving.clone(), recv))
                    .await
            });
            let capacity = DATA_QUEUE_PACKET_CAPACITY.min(DATA_QUEUE_BYTE_CAPACITY / payload_size);
            let count = capacity + 12;
            let sender = tokio::spawn(async move {
                for tag in 0..count {
                    send.send(DataPacket {
                        payload: Bytes::from(vec![tag as u8; payload_size]),
                    })
                    .await
                    .unwrap();
                }
                send
            });
            tokio::time::timeout(Duration::from_secs(10), async {
                while shared.queues.lock().unwrap().data_receive.packets.len() != capacity {
                    assert!(!receiver.is_finished(), "receiver rejected a valid burst");
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await
            .expect("receiver did not fill its bounded queue");
            // Exceed the former input-lane stall deadline as well: ordinary
            // reliable-data pressure has no arbitrary disconnect timer.
            tokio::time::sleep(Duration::from_millis(2100)).await;
            assert!(!receiver.is_finished());
            assert_eq!(shared.state(), EndpointState::SetupReady);
            {
                let queues = shared.queues.lock().unwrap();
                assert_eq!(queues.data_receive.packets.len(), capacity);
                assert_eq!(queues.data_receive.bytes, capacity * payload_size);
            }
            let mut output = vec![0; payload_size];
            tokio::time::timeout(Duration::from_secs(10), async {
                for tag in 0..count {
                    loop {
                        let mut size = 0;
                        let result = unsafe {
                            plank_transport_native_data_receive(
                                &mut endpoint,
                                output.as_mut_ptr(),
                                output.len(),
                                &mut size,
                                0,
                            )
                        };
                        if result == PLANK_TRANSPORT_TIMEOUT {
                            assert!(!receiver.is_finished());
                            tokio::time::sleep(Duration::from_millis(1)).await;
                            continue;
                        }
                        assert_eq!(result, PLANK_TRANSPORT_OK);
                        assert_eq!(size, payload_size);
                        assert!(output.iter().all(|value| *value == tag as u8));
                        break;
                    }
                }
            })
            .await
            .expect("consumer did not release reliable-data backpressure");
            let _send = sender.await.unwrap();
            assert_eq!(
                shared.stats.data_packets_received.load(Ordering::Relaxed),
                count as u64
            );
            assert_eq!(shared.queues.lock().unwrap().data_receive.bytes, 0);
            shared.stop.store(true, Ordering::Release);
            shared.notify_all();
            tokio::time::timeout(Duration::from_secs(1), receiver)
                .await
                .expect("receiver ignored stop")
                .unwrap()
                .unwrap();
            host_connection.close();
            client_connection.close();
            server.close(0, "data-pressure test completed");
            let _ = tokio::time::timeout(Duration::from_secs(1), server.wait_idle()).await;
        }
    }
}

fn endpoint(phase: EndpointState) -> PlankTransportNativeEndpoint {
    let shared = Arc::new(NativeShared::new(false, true, 150_000_000));
    shared.set_state(phase);
    PlankTransportNativeEndpoint {
        config: EndpointConfig::Client {
            remote_address: "127.0.0.1:28989".parse().unwrap(),
            server_name: "localhost".into(),
            certificate_sha256: None,
            session_token: "test-only".into(),
            setup_mode: true,
            options: super::super::RuntimeOptions {
                handshake_timeout: Duration::from_secs(5),
                idle_timeout: Duration::from_secs(5),
                keep_alive_interval: Duration::from_secs(1),
                max_udp_payload_size: None,
                initial_video_bitrate_bps: 150_000_000,
            },
        },
        mode: 2,
        shared,
        worker: Mutex::new(None),
    }
}

#[test]
fn data_queue_enforces_byte_limit_and_releases_exact_charges() {
    let mut queue = NativeDataQueue::default();
    for tag in 0..8 {
        assert!(queue.push_back(Bytes::from(vec![tag; MAX_DATA_PACKET_SIZE])));
    }
    assert_eq!(queue.bytes, DATA_QUEUE_BYTE_CAPACITY);
    assert!(!queue.push_back(Bytes::from_static(b"x")));
    assert_eq!(queue.packets.len(), 8); // Below packet-count limit.
    for tag in 0..8 {
        let packet = queue.pop_front().unwrap();
        assert_eq!(packet[0], tag);
        assert_eq!(queue.bytes, (7 - usize::from(tag)) * MAX_DATA_PACKET_SIZE);
    }
    assert!(queue.pop_front().is_none());
    assert_eq!(queue.bytes, 0);
    assert!(queue.push_back(Bytes::from_static(b"retry")));
    assert_eq!(queue.bytes, 5);
}

#[test]
fn data_queue_keeps_packet_limit_and_rejects_invalid_sizes() {
    let mut queue = NativeDataQueue::default();
    for size in [0, MAX_DATA_PACKET_SIZE + 1, usize::MAX] {
        assert!(!queue.can_push(size));
    }
    assert!(!queue.push_back(Bytes::new()));
    for _ in 0..DATA_QUEUE_PACKET_CAPACITY {
        assert!(queue.push_back(Bytes::from_static(b"x")));
    }
    assert!(!queue.push_back(Bytes::from_static(b"y")));
    assert_eq!(queue.bytes, DATA_QUEUE_PACKET_CAPACITY);
    queue.pop_front();
    assert!(queue.push_back(Bytes::from_static(b"z")));
}

#[test]
fn data_send_pressure_is_retryable_in_setup_and_active_phases() {
    for phase in [EndpointState::SetupReady, EndpointState::Ready] {
        let mut endpoint = endpoint(phase);
        let payload = vec![1; MAX_DATA_PACKET_SIZE];
        for _ in 0..8 {
            assert_eq!(
                unsafe {
                    plank_transport_native_data_send(&mut endpoint, payload.as_ptr(), payload.len())
                },
                PLANK_TRANSPORT_OK
            );
        }
        assert_eq!(
            unsafe {
                plank_transport_native_data_send(&mut endpoint, payload.as_ptr(), payload.len())
            },
            PLANK_TRANSPORT_TIMEOUT
        );
        assert_eq!(
            endpoint.shared.queues.lock().unwrap().data_send.bytes,
            DATA_QUEUE_BYTE_CAPACITY
        );
        endpoint.shared.queues.lock().unwrap().data_send.pop_front();
        assert_eq!(
            unsafe {
                plank_transport_native_data_send(&mut endpoint, payload.as_ptr(), payload.len())
            },
            PLANK_TRANSPORT_OK
        );
        assert_eq!(endpoint.shared.state(), phase);
    }
}

#[test]
fn short_receive_buffers_preserve_packet_and_byte_charge() {
    let mut endpoint = endpoint(EndpointState::Ready);
    assert!(
        endpoint
            .shared
            .queues
            .lock()
            .unwrap()
            .data_receive
            .push_back(Bytes::from_static(b"first"))
    );
    assert!(
        endpoint
            .shared
            .queues
            .lock()
            .unwrap()
            .data_receive
            .push_back(Bytes::from_static(b"second"))
    );
    let mut size = 0;
    assert_eq!(
        unsafe {
            plank_transport_native_data_receive(&mut endpoint, ptr::null_mut(), 0, &mut size, 0)
        },
        PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL
    );
    assert_eq!(size, 5);
    assert_eq!(
        endpoint.shared.queues.lock().unwrap().data_receive.bytes,
        11
    );
    assert_eq!(
        unsafe {
            plank_transport_native_data_receive(&mut endpoint, ptr::null_mut(), 32, &mut size, 0)
        },
        PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT
    );
    assert_eq!(
        endpoint.shared.queues.lock().unwrap().data_receive.bytes,
        11
    );
    let mut output = [0; 32];
    for expected in [b"first".as_slice(), b"second".as_slice()] {
        assert_eq!(
            unsafe {
                plank_transport_native_data_receive(
                    &mut endpoint,
                    output.as_mut_ptr(),
                    output.len(),
                    &mut size,
                    0,
                )
            },
            PLANK_TRANSPORT_OK
        );
        assert_eq!(&output[..size], expected);
    }
    assert_eq!(endpoint.shared.queues.lock().unwrap().data_receive.bytes, 0);
    assert_eq!(
        unsafe {
            plank_transport_native_data_receive(
                &mut endpoint,
                output.as_mut_ptr(),
                output.len(),
                &mut size,
                0,
            )
        },
        PLANK_TRANSPORT_TIMEOUT
    );
}

#[test]
fn concurrent_readers_do_not_duplicate_or_uncharge_the_wrong_record() {
    let endpoint = Arc::new(endpoint(EndpointState::Ready));
    for tag in 0..DATA_QUEUE_PACKET_CAPACITY as u8 {
        assert!(
            endpoint
                .shared
                .queues
                .lock()
                .unwrap()
                .data_receive
                .push_back(Bytes::from(vec![tag]))
        );
    }
    let mut readers = Vec::new();
    for _ in 0..4 {
        let endpoint = endpoint.clone();
        readers.push(std::thread::spawn(move || {
            let mut received = Vec::new();
            let mut output = [0; 1];
            let mut size = 0;
            loop {
                let result = unsafe {
                    plank_transport_native_data_receive(
                        Arc::as_ptr(&endpoint).cast_mut(),
                        output.as_mut_ptr(),
                        output.len(),
                        &mut size,
                        0,
                    )
                };
                if result == PLANK_TRANSPORT_TIMEOUT {
                    break;
                }
                assert_eq!(result, PLANK_TRANSPORT_OK);
                assert_eq!(size, 1);
                received.push(output[0]);
            }
            received
        }));
    }
    let mut received: Vec<u8> = readers
        .into_iter()
        .flat_map(|reader| reader.join().unwrap())
        .collect();
    received.sort_unstable();
    assert_eq!(
        received,
        (0..DATA_QUEUE_PACKET_CAPACITY as u8).collect::<Vec<_>>()
    );
    assert_eq!(endpoint.shared.queues.lock().unwrap().data_receive.bytes, 0);
}

#[test]
fn queue_accounting_survives_many_variable_sized_cycles() {
    let mut queue = NativeDataQueue::default();
    for cycle in 0..2000 {
        let payload = Bytes::from(vec![3; (cycle * 1777 % 65535) + 1]);
        if !queue.push_back(payload) {
            queue.pop_front().unwrap();
        }
        if cycle % 3 == 0 {
            queue.pop_front();
        }
        assert_eq!(
            queue.bytes,
            queue.packets.iter().map(Bytes::len).sum::<usize>()
        );
        assert!(queue.bytes <= DATA_QUEUE_BYTE_CAPACITY);
        assert!(queue.packets.len() <= DATA_QUEUE_PACKET_CAPACITY);
    }
}

#[tokio::test]
async fn data_pressure_waits_for_a_successful_ffi_drain() {
    use std::task::{Context, Poll, Waker};
    for size in [8, MAX_DATA_PACKET_SIZE] {
        let mut endpoint = endpoint(EndpointState::Ready);
        let capacity = DATA_QUEUE_PACKET_CAPACITY.min(DATA_QUEUE_BYTE_CAPACITY / size);
        let shared = endpoint.shared.clone();
        for tag in 0..capacity {
            assert!(
                shared
                    .queues
                    .lock()
                    .unwrap()
                    .data_receive
                    .push_back(Bytes::from(vec![tag as u8; size]))
            );
        }
        let mut pending = std::pin::pin!(push_data_receive(&shared, Bytes::from(vec![255; size])));
        let mut cx = Context::from_waker(Waker::noop());
        assert!(matches!(pending.as_mut().poll(&mut cx), Poll::Pending));
        shared.data_receive_space.notify_one(); // A spurious wake changes nothing.
        assert!(matches!(pending.as_mut().poll(&mut cx), Poll::Pending));
        let mut actual = 0;
        assert_eq!(
            unsafe {
                plank_transport_native_data_receive(
                    &mut endpoint,
                    ptr::null_mut(),
                    0,
                    &mut actual,
                    0,
                )
            },
            PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL
        );
        assert_eq!(actual, size);
        assert!(matches!(pending.as_mut().poll(&mut cx), Poll::Pending));
        let mut output = vec![0; size];
        assert_eq!(
            unsafe {
                plank_transport_native_data_receive(
                    &mut endpoint,
                    output.as_mut_ptr(),
                    output.len(),
                    &mut actual,
                    0,
                )
            },
            PLANK_TRANSPORT_OK
        );
        assert!(output.iter().all(|v| *v == 0));
        assert!(matches!(
            pending.as_mut().poll(&mut cx),
            Poll::Ready(Ok(true))
        ));
        let mut queues = shared.queues.lock().unwrap();
        assert_eq!(queues.data_receive.packets.len(), capacity);
        assert_eq!(queues.data_receive.bytes, size * capacity);
        for tag in 1..capacity {
            assert_eq!(queues.data_receive.pop_front().unwrap()[0], tag as u8);
        }
        assert_eq!(queues.data_receive.pop_front().unwrap()[0], 255);
        assert_eq!(queues.data_receive.bytes, 0);
        assert_eq!(shared.state(), EndpointState::Ready);
    }
}

#[tokio::test]
async fn cancelling_a_full_data_queue_is_prompt_and_preserves_queued_records() {
    use std::task::{Context, Poll, Waker};
    for failure in [false, true] {
        let shared = NativeShared::new(false, false, 150_000_000);
        shared.set_state(EndpointState::Ready);
        for _ in 0..DATA_QUEUE_PACKET_CAPACITY {
            assert!(
                shared
                    .queues
                    .lock()
                    .unwrap()
                    .data_receive
                    .push_back(Bytes::from_static(b"held"))
            );
        }
        let mut pending =
            std::pin::pin!(push_data_receive(&shared, Bytes::from_static(b"waiting")));
        let mut cx = Context::from_waker(Waker::noop());
        assert!(matches!(pending.as_mut().poll(&mut cx), Poll::Pending));
        if failure {
            shared.fail("test failure");
        } else {
            shared.stop.store(true, Ordering::Release);
            shared.notify_all();
        }
        assert!(matches!(
            pending.as_mut().poll(&mut cx),
            Poll::Ready(Ok(false))
        ));
        assert_eq!(
            shared.queues.lock().unwrap().data_receive.packets.len(),
            DATA_QUEUE_PACKET_CAPACITY
        );
        assert_eq!(
            shared.stats.data_packets_received.load(Ordering::Relaxed),
            0
        );
    }
}

#[tokio::test]
async fn invalid_data_sizes_are_rejected_without_waiting_or_allocation_in_the_queue() {
    let shared = NativeShared::new(false, false, 150_000_000);
    for size in [0, MAX_DATA_PACKET_SIZE + 1] {
        assert!(
            push_data_receive(&shared, Bytes::from(vec![0; size]))
                .await
                .is_err()
        );
        assert_eq!(shared.queues.lock().unwrap().data_receive.bytes, 0);
    }
}
