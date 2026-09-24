// SPDX-License-Identifier: AGPL-3.0-or-later
//! Session-bound native camera lane. Failure disables camera, not desktop media.
use super::*;
use crate::camera::{self, DISCONTINUITY, H264, HEADER_BYTES, KEY_FRAME, MAX_FRAME_BYTES, Packet};

const SEND_FRAMES: usize = 2;
const RECEIVE_FRAMES: usize = 3;
const MAX_AGE: Duration = Duration::from_millis(150);

#[derive(Default)]
struct State {
    enabled: bool,
    microphone_negotiated: bool,
    status: u32,
    generation: u64,
    last_generation: u64,
    last_sequence: Option<u64>,
    last_capture_time: u64,
    format: Option<camera::Format>,
    waiting_for_key: bool,
    request_key: bool,
    discontinuity: bool,
    packets: VecDeque<(Instant, Packet)>,
}
impl State {
    fn gap(&mut self) {
        self.packets.clear();
        self.discontinuity = true;
        if self.format.is_none_or(|format| format.codec == H264) {
            self.waiting_for_key = true;
            self.request_key = true;
        }
    }
    fn prune(&mut self) {
        if self
            .packets
            .front()
            .is_some_and(|(when, _)| when.elapsed() > MAX_AGE)
        {
            // Never deliver dependent H.264 after throwing away its reference.
            // Keep the newest queued independent frame, if one exists.
            let mut dropped = false;
            while self.packets.front().is_some_and(|(when, packet)| {
                when.elapsed() > MAX_AGE
                    || (dropped && packet.format.codec == H264 && packet.flags & KEY_FRAME == 0)
            }) {
                self.packets.pop_front();
                dropped = true;
            }
            if self.packets.is_empty() {
                self.gap();
            } else if dropped {
                self.packets.front_mut().unwrap().1.flags |= DISCONTINUITY;
            }
        }
    }
}

#[derive(Default)]
pub(super) struct Camera {
    state: Mutex<State>,
    changed: tokio::sync::Notify,
}
impl Camera {
    pub(super) fn negotiated(&self) -> bool {
        self.state.lock().unwrap().enabled
    }
    fn activate(&self, generation: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        if !state.enabled
            || state.status == 3
            || (generation != 0 && generation <= state.last_generation)
        {
            return false;
        }
        state.generation = generation;
        if generation != 0 {
            state.last_generation = generation;
        }
        state.last_sequence = None;
        state.last_capture_time = 0;
        state.format = None;
        state.packets.clear();
        state.waiting_for_key = true;
        state.request_key = generation != 0;
        state.discontinuity = true;
        true
    }
    fn push(&self, mut packet: Packet, capacity: usize) -> i32 {
        let mut state = self.state.lock().unwrap();
        if state.status != 2
            || state.generation == 0
            || packet.generation != state.generation
            || state
                .last_sequence
                .is_some_and(|last| packet.sequence <= last)
            || packet.capture_time_us <= state.last_capture_time
        {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        if state.format.is_some_and(|format| format != packet.format) {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        state.format = Some(packet.format);
        let missing = state
            .last_sequence
            .is_some_and(|last| packet.sequence != last + 1);
        let overflow = state.packets.len() == capacity;
        let gap = missing || packet.flags & DISCONTINUITY != 0 || overflow;
        let dropped = missing || overflow || (gap && !state.packets.is_empty());
        state.last_sequence = Some(packet.sequence);
        state.last_capture_time = packet.capture_time_us;
        if gap {
            state.gap();
            packet.flags |= DISCONTINUITY;
        }
        if packet.format.codec == H264 && state.waiting_for_key && packet.flags & KEY_FRAME == 0 {
            state.request_key = true;
            return PLANK_TRANSPORT_DROPPED;
        }
        if packet.flags & KEY_FRAME != 0 {
            state.waiting_for_key = false;
            state.request_key = false;
        }
        if state.discontinuity {
            packet.flags |= DISCONTINUITY;
            state.discontinuity = false;
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
        state.prune();
        state.packets.pop_front().map(|(_, packet)| packet)
    }
}

async fn source(shared: &NativeShared, connection: &kyproto::Connection) -> Result<()> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let microphone = shared.camera.state.lock().unwrap().microphone_negotiated;
    if microphone {
        shared.microphone.wait_for_allocation().await?;
    }
    let mut protocol = tokio::time::timeout_at(
        deadline,
        camera::open_source(connection, microphone, Duration::from_secs(3)),
    )
    .await
    .context("camera allocation/readiness timed out")??;
    protocol
        .send
        .send(AVPacket::Codec(CodecPacket {
            header: CodecPacketHeader {
                codec: camera::LANE_CODEC,
                rotation: 0,
                frame_size: 0,
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
    shared.camera.state.lock().unwrap().status = 2;
    loop {
        let notified = shared.camera.changed.notified();
        if let Some(packet) = shared.camera.pop() {
            let payload = packet.encode()?;
            protocol
                .send
                .send(AVPacket::Media(MediaPacket {
                    header: MediaPacketHeader {
                        is_config: false,
                        is_key: packet.flags & KEY_FRAME != 0,
                        pts: packet.capture_time_us,
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
    let microphone = shared.camera.state.lock().unwrap().microphone_negotiated;
    let mut protocol = camera::open_sink(connection, microphone, Duration::from_secs(3)).await?;
    shared.camera.state.lock().unwrap().status = 2;
    let mut format_valid = false;
    while let Some(packet) = protocol.recv.recv().await? {
        match packet {
            AVPacket::Codec(packet) => {
                anyhow::ensure!(
                    packet.header.codec == camera::LANE_CODEC
                        && packet.header.frame_size == 0
                        && packet.header.rotation == 0,
                    "invalid camera lane codec"
                );
                format_valid = true;
            }
            AVPacket::Media(packet) if !packet.header.is_config => {
                anyhow::ensure!(format_valid, "missing camera lane codec");
                let record = Packet::decode(packet.payload)?;
                anyhow::ensure!(
                    packet.header.pts == record.capture_time_us
                        && packet.header.is_key == (record.flags & KEY_FRAME != 0),
                    "inconsistent camera record"
                );
                let status = shared.camera.push(record, RECEIVE_FRAMES);
                anyhow::ensure!(
                    status != PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT,
                    "camera format changed without reactivation"
                );
                // Stale generations and out-of-order in-flight frames are drops.
            }
            AVPacket::Media(packet) => {
                anyhow::ensure!(
                    format_valid && packet.payload.is_empty(),
                    "invalid camera configuration"
                );
            }
            AVPacket::Hole(_) => shared.camera.state.lock().unwrap().gap(),
        }
    }
    anyhow::bail!("camera lane ended")
}

pub(super) async fn run(shared: Arc<NativeShared>, connection: &kyproto::Connection, client: bool) {
    loop {
        let notified = shared.camera.changed.notified();
        if shared.camera.state.lock().unwrap().enabled {
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
        let mut state = shared.camera.state.lock().unwrap();
        state.status = 3;
        state.generation = 0;
        state.packets.clear();
        state.request_key = false;
    }
    std::future::pending::<()>().await;
}

/// # Safety
/// Endpoint is null or live. Call only after authenticated capability agreement;
/// enable the negotiated microphone first. This fixes allocation for the session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_camera_enable(
    endpoint: *mut PlankTransportNativeEndpoint,
    microphone_negotiated: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        let _allocation = endpoint.shared.reverse_allocation.lock().unwrap();
        if microphone_negotiated > 1 {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if !matches!(
            endpoint.shared.state(),
            EndpointState::SetupReady | EndpointState::Ready
        ) || endpoint.shared.microphone.negotiated() != (microphone_negotiated != 0)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let mut state = endpoint.shared.camera.state.lock().unwrap();
        if state.enabled {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        state.enabled = true;
        state.status = 1;
        state.microphone_negotiated = microphone_negotiated != 0;
        drop(state);
        endpoint.shared.camera.changed.notify_one();
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// Endpoint is null or live. Zero disables, nonzero activation generations increase.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_camera_activate(
    endpoint: *mut PlankTransportNativeEndpoint,
    generation: u64,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.shared.state() != EndpointState::Ready
            || !endpoint.shared.camera.activate(generation)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// Endpoint is null or live. Same 0/1/2/3 availability states as microphone.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_camera_state(
    endpoint: *const PlankTransportNativeEndpoint,
) -> u32 {
    let result = catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return 0;
        };
        if endpoint.shared.state() != EndpointState::Ready {
            return 0;
        }
        endpoint.shared.camera.state.lock().unwrap().status as i32
    });
    if result < 0 { 3 } else { result as u32 }
}

/// # Safety
/// Endpoint is null or live. Returns current activation needing an independent
/// frame, or zero. Level-triggered: caller rate-limits requests until a key arrives.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_camera_keyframe_needed(
    endpoint: *const PlankTransportNativeEndpoint,
) -> u64 {
    if endpoint.is_null() {
        return 0;
    }
    std::panic::catch_unwind(|| {
        let endpoint = unsafe { &*endpoint };
        if endpoint.shared.state() != EndpointState::Ready {
            return 0;
        }
        let state = endpoint.shared.camera.state.lock().unwrap();
        if state.status == 2 && state.request_key {
            state.generation
        } else {
            0
        }
    })
    .unwrap_or(0)
}

/// # Safety
/// Endpoint is null or live. Record points at length readable PCAM bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_camera_send(
    endpoint: *mut PlankTransportNativeEndpoint,
    record: *const u8,
    length: usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint.mode != 2 || endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        if record.is_null()
            || !(HEADER_BYTES + 1..=HEADER_BYTES + MAX_FRAME_BYTES).contains(&length)
        {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let bytes = Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(record, length) });
        let Ok(packet) = Packet::decode(bytes) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        endpoint.shared.camera.push(packet, SEND_FRAMES)
    })
}

/// # Safety
/// Endpoint is null or live, outputs writable. Insufficient capacity preserves
/// the queued record. Nonblocking; copying and deactivation share one queue lock.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_camera_receive(
    endpoint: *mut PlankTransportNativeEndpoint,
    record: *mut u8,
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
        if length.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let mut state = endpoint.shared.camera.state.lock().unwrap();
        state.prune();
        let Some((_, front)) = state.packets.front() else {
            unsafe { *length = 0 };
            return PLANK_TRANSPORT_TIMEOUT;
        };
        let status =
            validate_bytes_out(HEADER_BYTES + front.payload.len(), record, capacity, length);
        if status != PLANK_TRANSPORT_OK {
            return status;
        }
        let bytes = match front.encode() {
            Ok(bytes) => bytes,
            Err(_) => return PLANK_TRANSPORT_ERROR_INVALID_STATE,
        };
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), record, bytes.len());
        }
        state.packets.pop_front();
        PLANK_TRANSPORT_OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::camera::Format;
    fn packet(generation: u64, sequence: u64, key: bool) -> Packet {
        Packet {
            format: Format {
                codec: H264,
                width: 1280,
                height: 720,
                colorspace: 8,
                transfer: 0,
                ycbcr: 0,
                quantization: 0,
            },
            flags: if key { KEY_FRAME } else { 0 },
            generation,
            sequence,
            capture_time_us: 1_000_000 + sequence * 33_333,
            driver_sequence: sequence as u32,
            payload: Bytes::from_static(&[0, 0, 0, 1, 0x65, 0x80]),
        }
    }
    #[test]
    fn queue_bounds_generations_format_and_keyframe_recovery() {
        let camera = Camera::default();
        assert!(!camera.activate(1));
        {
            let mut state = camera.state.lock().unwrap();
            state.enabled = true;
            state.status = 2;
        }
        assert!(camera.activate(1));
        assert_eq!(camera.push(packet(1, 0, false), 2), PLANK_TRANSPORT_DROPPED);
        assert!(camera.pop().is_none());
        assert_eq!(camera.push(packet(1, 1, true), 2), PLANK_TRANSPORT_OK);
        assert_eq!(camera.pop().unwrap().flags, KEY_FRAME | DISCONTINUITY);
        assert_eq!(camera.push(packet(1, 3, false), 2), PLANK_TRANSPORT_DROPPED);
        assert!(camera.state.lock().unwrap().request_key);
        assert_eq!(camera.push(packet(1, 4, true), 2), PLANK_TRANSPORT_OK);
        assert_eq!(camera.push(packet(1, 5, false), 2), PLANK_TRANSPORT_OK);
        assert_eq!(camera.push(packet(1, 6, false), 2), PLANK_TRANSPORT_DROPPED);
        assert!(camera.pop().is_none());
        assert_eq!(camera.push(packet(1, 7, true), 2), PLANK_TRANSPORT_OK);
        assert_eq!(camera.pop().unwrap().sequence, 7);
        assert!(!camera.state.lock().unwrap().request_key);
        let mut changed = packet(1, 8, true);
        changed.format.width = 1920;
        changed.format.height = 1080;
        assert_eq!(
            camera.push(changed, 2),
            PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT
        );
        assert_eq!(
            camera.push(packet(1, 7, true), 2),
            PLANK_TRANSPORT_ERROR_INVALID_STATE
        );
        assert!(camera.activate(0));
        assert!(camera.pop().is_none());
        assert!(!camera.activate(1));
        assert!(camera.activate(2));
        assert_eq!(
            camera.push(packet(1, 8, true), 2),
            PLANK_TRANSPORT_ERROR_INVALID_STATE
        );
        assert_eq!(camera.push(packet(2, 0, true), 2), PLANK_TRANSPORT_OK);
        assert_eq!(camera.push(packet(2, 1, false), 2), PLANK_TRANSPORT_OK);
        camera.state.lock().unwrap().packets.front_mut().unwrap().0 =
            Instant::now() - MAX_AGE - Duration::from_millis(1);
        assert!(camera.pop().is_none());
        assert!(camera.state.lock().unwrap().request_key);
        assert_eq!(camera.push(packet(2, 2, true), 2), PLANK_TRANSPORT_OK);
        let first = camera.pop().unwrap();
        assert_eq!(first.flags, KEY_FRAME | DISCONTINUITY);
        assert_eq!(first.payload, packet(2, 2, true).payload);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "requires loopback test certificate variables"]
    async fn encrypted_camera_with_and_without_microphone() {
        use super::super::cancellation_tests::{endpoint, wait_bound, wait_state};
        use super::super::microphone_lane::*;
        use std::net::UdpSocket;
        for microphone in [false, true] {
            for setup in [false, true] {
                let address = UdpSocket::bind("127.0.0.1:0")
                    .unwrap()
                    .local_addr()
                    .unwrap();
                let mut host = endpoint(address, true, setup);
                let mut client = endpoint(address, false, setup);
                unsafe {
                    assert_eq!(
                        plank_transport_native_camera_enable(&mut *client, microphone as u32),
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
                    if microphone {
                        assert_eq!(
                            plank_transport_native_microphone_enable(&mut *host),
                            PLANK_TRANSPORT_OK
                        );
                        assert_eq!(
                            plank_transport_native_microphone_enable(&mut *client),
                            PLANK_TRANSPORT_OK
                        );
                    }
                    assert_eq!(
                        plank_transport_native_camera_enable(&mut *host, microphone as u32),
                        PLANK_TRANSPORT_OK
                    );
                    assert_eq!(
                        plank_transport_native_camera_enable(&mut *client, microphone as u32),
                        PLANK_TRANSPORT_OK
                    );
                    assert_eq!(
                        plank_transport_native_microphone_enable(&mut *client),
                        PLANK_TRANSPORT_ERROR_INVALID_STATE
                    );
                    tokio::time::timeout(Duration::from_secs(5), async {
                        while plank_transport_native_camera_state(&*host) != 2
                            || plank_transport_native_camera_state(&*client) != 2
                        {
                            assert_ne!(plank_transport_native_camera_state(&*host), 3);
                            assert_ne!(plank_transport_native_camera_state(&*client), 3);
                            tokio::time::sleep(Duration::from_millis(1)).await;
                        }
                    })
                    .await
                    .unwrap();
                    for generation in [1, 2] {
                        assert_eq!(
                            plank_transport_native_camera_activate(&mut *host, generation),
                            PLANK_TRANSPORT_OK
                        );
                        assert_eq!(
                            plank_transport_native_camera_activate(&mut *client, generation),
                            PLANK_TRANSPORT_OK
                        );
                        let mut input = packet(generation, 0, true);
                        input.flags |= DISCONTINUITY;
                        input.payload =
                            Bytes::from((0..131_071).map(|n| (n % 251) as u8).collect::<Vec<_>>());
                        let bytes = input.encode().unwrap();
                        assert_eq!(
                            plank_transport_native_camera_send(
                                &mut *client,
                                bytes.as_ptr(),
                                bytes.len()
                            ),
                            PLANK_TRANSPORT_OK
                        );
                        tokio::time::timeout(Duration::from_secs(3), async {
                            loop {
                                let mut output = vec![0; bytes.len()];
                                let mut size = 0;
                                let status = plank_transport_native_camera_receive(
                                    &mut *host,
                                    output.as_mut_ptr(),
                                    1,
                                    &mut size,
                                );
                                if status == PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL {
                                    assert_eq!(size, bytes.len());
                                    assert_eq!(
                                        plank_transport_native_camera_receive(
                                            &mut *host,
                                            output.as_mut_ptr(),
                                            output.len(),
                                            &mut size
                                        ),
                                        PLANK_TRANSPORT_OK
                                    );
                                    assert_eq!(Packet::decode(Bytes::from(output)).unwrap(), input);
                                    break;
                                }
                                assert_eq!(status, PLANK_TRANSPORT_TIMEOUT);
                                tokio::time::sleep(Duration::from_millis(1)).await;
                            }
                        })
                        .await
                        .unwrap();
                        assert_eq!(
                            plank_transport_native_camera_activate(&mut *host, 0),
                            PLANK_TRANSPORT_OK
                        );
                        assert_eq!(
                            plank_transport_native_camera_activate(&mut *client, 0),
                            PLANK_TRANSPORT_OK
                        );
                        assert_eq!(
                            plank_transport_native_camera_send(
                                &mut *client,
                                bytes.as_ptr(),
                                bytes.len()
                            ),
                            PLANK_TRANSPORT_ERROR_INVALID_STATE
                        );
                        if microphone {
                            assert_eq!(plank_transport_native_microphone_state(&*host), 2);
                            assert_eq!(plank_transport_native_microphone_state(&*client), 2);
                        }
                        assert_eq!(host.shared.state(), EndpointState::Ready);
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
}
