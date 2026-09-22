// SPDX-License-Identifier: AGPL-3.0-or-later

use super::*;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "run through scripts/test/run-plank-transport-native-loopback.sh"]
async fn reliable_data_overflow_fails_both_receivers() {
    init_crypto_once();
    let certificate_path = std::env::var("SC_NATIVE_TEST_CERTIFICATE").unwrap();
    let private_key_path = std::env::var("SC_NATIVE_TEST_PRIVATE_KEY").unwrap();
    for receiving_host in [true, false] {
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
            native::accept_setup_server(&server, "data-limit-test", options),
            native::connect_setup_client(address, "localhost", "data-limit-test", options),
        );
        let (host_connection, host_data) = host.unwrap().into_parts();
        let (client_connection, client_data, _) = client.unwrap().into_parts();
        let (mut send, recv) = if receiving_host {
            (client_data.send, host_data.recv)
        } else {
            (host_data.send, client_data.recv)
        };
        let shared = Arc::new(NativeShared::new(false, true, 150_000_000));
        shared.set_state(EndpointState::SetupReady);
        let send_packets = async {
            for tag in 0..8 {
                send.send(DataPacket {
                    payload: Bytes::from(vec![tag; MAX_DATA_PACKET_SIZE]),
                })
                .await
                .unwrap();
            }
            send.send(DataPacket {
                payload: Bytes::from_static(b"over budget"),
            })
            .await
            .unwrap();
        };
        let (_, received) = tokio::time::timeout(Duration::from_secs(10), async {
            tokio::join!(send_packets, receive_data(shared.clone(), recv))
        })
        .await
        .expect("queue overflow must fail promptly");
        let error = received.expect_err("peer flood was accepted");
        assert!(
            error
                .to_string()
                .contains("receive queue size limit exceeded")
        );
        finish_worker(&shared, Err(error));
        assert_eq!(shared.state(), EndpointState::Failed);
        assert_eq!(
            shared.stats.data_packets_received.load(Ordering::Relaxed),
            8
        );
        {
            let mut queues = shared.queues.lock().unwrap();
            assert_eq!(queues.data_receive.bytes, DATA_QUEUE_BYTE_CAPACITY);
            for tag in 0..8 {
                assert_eq!(queues.data_receive.pop_front().unwrap()[0], tag);
            }
            assert_eq!(queues.data_receive.bytes, 0);
        }
        host_connection.close();
        client_connection.close();
        server.close(0, "data-limit test completed");
        let _ = tokio::time::timeout(Duration::from_secs(1), server.wait_idle()).await;
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
