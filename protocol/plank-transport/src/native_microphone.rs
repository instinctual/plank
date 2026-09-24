// SPDX-License-Identifier: AGPL-3.0-or-later
//! Optional, session-bound reverse audio. Failure disables only the microphone.
use super::*;
use crate::microphone::{self, FRAME_SAMPLES, MAX_OPUS_BYTES, Packet};

// SDL/PipeWire can deliver several 10 ms packets in one capture callback. The
// Client drains at most six per batch; accept that complete batch without
// requiring the async sender to be scheduled between adjacent FFI calls.
// This is capacity, not a playout delay: the sender drains immediately.
const SEND_PACKETS: usize = 6;
const RECEIVE_PACKETS: usize = 8;
const MAX_AGE: Duration = Duration::from_millis(100);

#[derive(Default)]
struct State {
    enabled: bool,
    status: u32, // 0 unavailable/not negotiated, 1 opening, 2 ready, 3 failed
    generation: u64,
    last_generation: u64,
    last_sample: Option<u64>,
    packets: VecDeque<(Instant, Packet)>,
}

#[derive(Default)]
pub(super) struct Microphone {
    state: Mutex<State>,
    changed: tokio::sync::Notify,
    allocated: AtomicBool,
    allocation_changed: tokio::sync::Notify,
}

impl Microphone {
    pub(super) fn negotiated(&self) -> bool {
        self.state.lock().unwrap().enabled
    }

    // Camera allocation follows microphone allocation, not microphone ready.
    // A missing microphone consumer cannot indefinitely block camera setup.
    pub(super) async fn wait_for_allocation(&self) -> Result<()> {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let notified = self.allocation_changed.notified();
                if self.allocated.load(Ordering::Acquire) {
                    break;
                }
                notified.await;
            }
        })
        .await
        .context("camera waited too long for microphone allocation")
    }
    fn activate(&self, generation: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        if !state.enabled || state.status == 3 {
            return false;
        }
        if generation != 0 && generation <= state.last_generation {
            return false;
        }
        state.generation = generation;
        if generation != 0 {
            state.last_generation = generation;
        }
        state.last_sample = None;
        state.packets.clear();
        true
    }

    fn push(&self, packet: Packet, capacity: usize) -> i32 {
        let mut state = self.state.lock().unwrap();
        if state.status != 2
            || state.generation == 0
            || packet.generation != state.generation
            || state
                .last_sample
                .is_some_and(|last| packet.sample_time <= last)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        state.last_sample = Some(packet.sample_time);
        let dropped = state.packets.len() == capacity;
        if dropped {
            state.packets.pop_front();
        }
        state.packets.push_back((Instant::now(), packet));
        drop(state);
        self.changed.notify_one();
        if dropped {
            PLANK_TRANSPORT_DROPPED
        } else {
            PLANK_TRANSPORT_OK
        }
    }

    fn pop(&self) -> Option<Packet> {
        let mut state = self.state.lock().unwrap();
        while let Some((when, packet)) = state.packets.pop_front() {
            if state.generation != 0
                && packet.generation == state.generation
                && when.elapsed() <= MAX_AGE
            {
                return Some(packet);
            }
        }
        None
    }
}

async fn source(shared: &NativeShared, connection: &kyproto::Connection) -> Result<()> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let endpoint = microphone::register_source(connection, Duration::from_secs(3)).await?;
    shared.microphone.allocated.store(true, Ordering::Release);
    shared.microphone.allocation_changed.notify_one();
    let mut protocol = tokio::time::timeout_at(deadline, endpoint.ready())
        .await
        .context("microphone source readiness timed out")??;
    protocol
        .send
        .send(AVPacket::Codec(CodecPacket {
            header: CodecPacketHeader {
                codec: AUDIO_CODEC_OPUS,
                rotation: 0,
                frame_size: FRAME_SAMPLES,
            },
        }))
        .await?;
    protocol
        .send
        .send(AVPacket::Media(MediaPacket {
            header: MediaPacketHeader {
                is_config: true,
                is_key: true,
                pts: 0,
                size: 0,
            },
            payload: Bytes::new(),
        }))
        .await?;
    shared.microphone.state.lock().unwrap().status = 2;
    loop {
        let notified = shared.microphone.changed.notified();
        if let Some(packet) = shared.microphone.pop() {
            let pts = packet.sample_time / 48;
            // KyProto audio timestamps have a bounded 61-bit representation.
            anyhow::ensure!(pts < (1u64 << 61), "invalid microphone timestamp");
            let payload = packet.encode()?;
            protocol
                .send
                .send(AVPacket::Media(MediaPacket {
                    header: MediaPacketHeader {
                        is_config: false,
                        is_key: false,
                        pts,
                        size: payload.len() as u32,
                    },
                    payload,
                }))
                .await?;
        } else {
            notified.await;
        }
    }
}

async fn sink(shared: &NativeShared, connection: &kyproto::Connection) -> Result<()> {
    let mut protocol = microphone::open_sink(connection, Duration::from_secs(3)).await?;
    shared.microphone.state.lock().unwrap().status = 2;
    let mut format_valid = false;
    while let Some(packet) = protocol.recv.recv().await? {
        match packet {
            AVPacket::Codec(packet) => {
                anyhow::ensure!(
                    packet.header.codec == AUDIO_CODEC_OPUS
                        && packet.header.frame_size == FRAME_SAMPLES
                        && packet.header.rotation == 0,
                    "invalid microphone codec"
                );
                format_valid = true;
            }
            AVPacket::Media(packet) if !packet.header.is_config => {
                anyhow::ensure!(format_valid, "missing microphone codec");
                let packet = Packet::decode(packet.payload)?;
                // In-flight pre-mute packets are expected, not a session error.
                shared.microphone.push(packet, RECEIVE_PACKETS);
            }
            AVPacket::Media(packet) => {
                anyhow::ensure!(
                    format_valid && packet.payload.is_empty(),
                    "invalid microphone configuration"
                );
            }
            AVPacket::Hole(_) => {} // Sample timestamps expose gaps to the decoder.
        }
    }
    anyhow::bail!("microphone lane ended")
}

pub(super) async fn run(shared: Arc<NativeShared>, connection: &kyproto::Connection, client: bool) {
    loop {
        let notified = shared.microphone.changed.notified();
        if shared.microphone.state.lock().unwrap().enabled {
            break;
        }
        notified.await;
    }
    let result = if client {
        source(&shared, connection).await
    } else {
        sink(&shared, connection).await
    };
    if result.is_err() {
        let mut state = shared.microphone.state.lock().unwrap();
        state.status = 3;
        state.generation = 0;
        state.packets.clear();
    }
    // A missing/failed microphone must not terminate otherwise healthy media.
    std::future::pending::<()>().await;
}

/// # Safety
/// Endpoint must be null or live. Call only after authenticated capability agreement.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_microphone_enable(
    endpoint: *mut PlankTransportNativeEndpoint,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        let _allocation = endpoint.shared.reverse_allocation.lock().unwrap();
        if endpoint.shared.camera.negotiated() {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        if !matches!(
            endpoint.shared.state(),
            EndpointState::SetupReady | EndpointState::Ready
        ) {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let mut state = endpoint.shared.microphone.state.lock().unwrap();
        if state.enabled {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        state.enabled = true;
        state.status = 1;
        drop(state);
        endpoint.shared.microphone.changed.notify_one();
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// Endpoint must be null or live. Zero mutes; nonzero generations must increase.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_microphone_activate(
    endpoint: *mut PlankTransportNativeEndpoint,
    generation: u64,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.shared.state() != EndpointState::Ready
            || !endpoint.shared.microphone.activate(generation)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// Endpoint must be null or live. Returns 0 unavailable, 1 opening, 2 ready, 3 failed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_microphone_state(
    endpoint: *const PlankTransportNativeEndpoint,
) -> u32 {
    let result = catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return 0;
        };
        if endpoint.shared.state() != EndpointState::Ready {
            return 0;
        }
        endpoint.shared.microphone.state.lock().unwrap().status as i32
    });
    if result < 0 { 3 } else { result as u32 }
}

/// # Safety
/// Endpoint must be live; data must reference length readable bytes for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_microphone_send(
    endpoint: *mut PlankTransportNativeEndpoint,
    generation: u64,
    sample_time: u64,
    data: *const u8,
    length: usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 2 || endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        if data.is_null() || !(1..=MAX_OPUS_BYTES).contains(&length) {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let packet = Packet {
            generation,
            sample_time,
            opus: Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(data, length) }),
        };
        if packet.encode().is_err() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        endpoint.shared.microphone.push(packet, SEND_PACKETS)
    })
}

/// # Safety
/// Endpoint must be live. All outputs must reference writable storage. Nonblocking;
/// insufficient capacity preserves the same queued packet under its queue lock.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_microphone_receive(
    endpoint: *mut PlankTransportNativeEndpoint,
    generation: *mut u64,
    sample_time: *mut u64,
    data: *mut u8,
    capacity: usize,
    length: *mut usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 1 || endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        if generation.is_null() || sample_time.is_null() || length.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let mut state = endpoint.shared.microphone.state.lock().unwrap();
        while state
            .packets
            .front()
            .is_some_and(|(when, _)| when.elapsed() > MAX_AGE)
        {
            state.packets.pop_front();
        }
        let Some((_, front)) = state.packets.front() else {
            unsafe { *length = 0 };
            return PLANK_TRANSPORT_TIMEOUT;
        };
        let result = validate_bytes_out(front.opus.len(), data, capacity, length);
        if result != PLANK_TRANSPORT_OK {
            return result;
        }
        let (_, packet) = state.packets.pop_front().unwrap();
        // Copy while holding this small independent queue lock so mute cannot
        // complete while a previously claimed generation is still being copied.
        unsafe {
            *generation = packet.generation;
            *sample_time = packet.sample_time;
            ptr::copy_nonoverlapping(packet.opus.as_ptr(), data, packet.opus.len());
        }
        PLANK_TRANSPORT_OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn packet(generation: u64, n: u64) -> Packet {
        Packet {
            generation,
            sample_time: n * 480,
            opus: Bytes::from_static(&[1]),
        }
    }
    #[test]
    fn capture_batch_survives_sender_scheduling_delay() {
        let microphone = Microphone::default();
        {
            let mut state = microphone.state.lock().unwrap();
            state.enabled = true;
            state.status = 2;
        }
        assert!(microphone.activate(1));
        // Match one maximum Client capture drain, with no sender scheduled yet.
        for index in 0..6 {
            assert_eq!(microphone.push(packet(1, index), SEND_PACKETS), PLANK_TRANSPORT_OK);
        }
        for index in 0..6 {
            assert_eq!(microphone.pop().unwrap().sample_time, index * 480);
        }
        assert!(microphone.pop().is_none());
        // A genuine stall still bounds memory and discards the oldest audio.
        for index in 6..12 {
            assert_eq!(microphone.push(packet(1, index), SEND_PACKETS), PLANK_TRANSPORT_OK);
        }
        assert_eq!(microphone.push(packet(1, 12), SEND_PACKETS), PLANK_TRANSPORT_DROPPED);
        assert_eq!(microphone.pop().unwrap().sample_time, 7 * 480);
        assert!(microphone.activate(0));
        assert!(microphone.pop().is_none());
    }
    #[test]
    fn bounded_queues_mute_generation_order_and_age() {
        let microphone = Microphone::default();
        assert!(!microphone.activate(1));
        {
            let mut state = microphone.state.lock().unwrap();
            state.enabled = true;
            state.status = 2;
        }
        assert!(microphone.activate(1));
        assert_eq!(microphone.push(packet(1, 0), 2), PLANK_TRANSPORT_OK);
        assert_eq!(
            microphone.push(packet(1, 0), 2),
            PLANK_TRANSPORT_ERROR_INVALID_STATE
        );
        assert_eq!(microphone.push(packet(1, 1), 2), PLANK_TRANSPORT_OK);
        assert_eq!(microphone.push(packet(1, 2), 2), PLANK_TRANSPORT_DROPPED);
        assert_eq!(microphone.pop().unwrap().sample_time, 480);
        assert!(microphone.activate(0));
        assert!(microphone.pop().is_none());
        assert!(!microphone.activate(1));
        assert!(microphone.activate(2));
        assert_eq!(
            microphone.push(packet(1, 3), 2),
            PLANK_TRANSPORT_ERROR_INVALID_STATE
        );
        assert_eq!(microphone.push(packet(2, 0), 2), PLANK_TRANSPORT_OK);
        microphone
            .state
            .lock()
            .unwrap()
            .packets
            .front_mut()
            .unwrap()
            .0 = Instant::now() - MAX_AGE - Duration::from_millis(1);
        assert!(microphone.pop().is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "run through scripts/test/run-plank-transport-native-loopback.sh"]
    async fn encrypted_ffi_microphone_mute_reopen_and_bounds() {
        use super::super::cancellation_tests::{endpoint, wait_bound, wait_state};
        use std::net::UdpSocket;
        for setup in [false, true] {
            let address = UdpSocket::bind("127.0.0.1:0")
                .unwrap()
                .local_addr()
                .unwrap();
            let mut host = endpoint(address, true, setup);
            let mut client = endpoint(address, false, setup);
            unsafe {
                assert_eq!(
                    plank_transport_native_microphone_enable(&mut *client),
                    PLANK_TRANSPORT_ERROR_INVALID_STATE
                );
                assert_eq!(
                    plank_transport_native_endpoint_start(&mut *host),
                    PLANK_TRANSPORT_OK
                );
                wait_bound(address, &host).await;
                assert_eq!(
                    plank_transport_native_endpoint_start(&mut *client),
                    PLANK_TRANSPORT_OK
                );
                if setup {
                    wait_state(&client, EndpointState::PeerValidation).await;
                    assert_eq!(
                        plank_transport_native_endpoint_approve_peer_certificate(&mut *client),
                        PLANK_TRANSPORT_OK
                    );
                    wait_state(&host, EndpointState::SetupReady).await;
                    wait_state(&client, EndpointState::SetupReady).await;
                    assert_eq!(
                        plank_transport_native_endpoint_authorize_session(&mut *host),
                        PLANK_TRANSPORT_OK
                    );
                    assert_eq!(
                        plank_transport_native_endpoint_authorize_session(&mut *client),
                        PLANK_TRANSPORT_OK
                    );
                }
                wait_state(&host, EndpointState::Ready).await;
                wait_state(&client, EndpointState::Ready).await;
                assert_eq!(
                    plank_transport_native_microphone_enable(&mut *host),
                    PLANK_TRANSPORT_OK
                );
                assert_eq!(
                    plank_transport_native_microphone_enable(&mut *client),
                    PLANK_TRANSPORT_OK
                );
                tokio::time::timeout(Duration::from_secs(5), async {
                    while plank_transport_native_microphone_state(&*host) != 2
                        || plank_transport_native_microphone_state(&*client) != 2
                    {
                        assert_ne!(plank_transport_native_microphone_state(&*host), 3);
                        assert_ne!(plank_transport_native_microphone_state(&*client), 3);
                        tokio::time::sleep(Duration::from_millis(1)).await;
                    }
                })
                .await
                .unwrap();
                for generation in [1, 2] {
                    assert_eq!(
                        plank_transport_native_microphone_activate(&mut *host, generation),
                        PLANK_TRANSPORT_OK
                    );
                    assert_eq!(
                        plank_transport_native_microphone_activate(&mut *client, generation),
                        PLANK_TRANSPORT_OK
                    );
                    let input = [0xf4, 0xff, 0xfe];
                    assert_eq!(
                        plank_transport_native_microphone_send(
                            &mut *client,
                            generation,
                            0,
                            input.as_ptr(),
                            MAX_OPUS_BYTES + 1
                        ),
                        PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT
                    );
                    assert_eq!(
                        plank_transport_native_microphone_send(
                            &mut *client,
                            generation,
                            0,
                            input.as_ptr(),
                            input.len()
                        ),
                        PLANK_TRANSPORT_OK
                    );
                    tokio::time::timeout(Duration::from_secs(3), async {
                        loop {
                            let mut received_generation = 0;
                            let mut timestamp = 99;
                            let mut size = 0;
                            let mut output = [0; 3];
                            let result = plank_transport_native_microphone_receive(
                                &mut *host,
                                &mut received_generation,
                                &mut timestamp,
                                output.as_mut_ptr(),
                                1,
                                &mut size,
                            );
                            if result == PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL {
                                assert_eq!(size, 3);
                                assert_eq!(
                                    plank_transport_native_microphone_receive(
                                        &mut *host,
                                        &mut received_generation,
                                        &mut timestamp,
                                        output.as_mut_ptr(),
                                        output.len(),
                                        &mut size
                                    ),
                                    PLANK_TRANSPORT_OK
                                );
                                assert_eq!(received_generation, generation);
                                assert_eq!(timestamp, 0);
                                assert_eq!(output, input);
                                break;
                            }
                            assert_eq!(result, PLANK_TRANSPORT_TIMEOUT);
                            tokio::time::sleep(Duration::from_millis(1)).await;
                        }
                    })
                    .await
                    .unwrap();
                    assert_eq!(
                        plank_transport_native_microphone_activate(&mut *host, 0),
                        PLANK_TRANSPORT_OK
                    );
                    assert_eq!(
                        plank_transport_native_microphone_activate(&mut *client, 0),
                        PLANK_TRANSPORT_OK
                    );
                    assert_eq!(
                        plank_transport_native_microphone_send(
                            &mut *client,
                            generation,
                            480,
                            input.as_ptr(),
                            input.len()
                        ),
                        PLANK_TRANSPORT_ERROR_INVALID_STATE
                    );
                }
                assert_eq!(
                    plank_transport_native_endpoint_stop(&mut *client),
                    PLANK_TRANSPORT_OK
                );
                assert_eq!(
                    plank_transport_native_endpoint_stop(&mut *host),
                    PLANK_TRANSPORT_OK
                );
            }
        }
    }
}
