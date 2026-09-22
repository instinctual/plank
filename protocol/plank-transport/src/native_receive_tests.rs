// SPDX-License-Identifier: AGPL-3.0-or-later

use super::*;
use std::cell::RefCell;
use std::sync::Barrier;

thread_local! {
    // Per-thread, one-shot injection; other tests and nested receives cannot
    // accidentally run this callback. Compiled out of the production library.
    static BEFORE_COPY: RefCell<Option<Box<dyn FnOnce()>>> = const { RefCell::new(None) };
}

pub(super) fn before_copy() {
    let hook = BEFORE_COPY.with_borrow_mut(Option::take);
    if let Some(hook) = hook {
        hook();
    }
}

fn interleave_before_copy(hook: impl FnOnce() + 'static, receive: impl FnOnce()) {
    struct ResetHook;
    impl Drop for ResetHook {
        fn drop(&mut self) {
            BEFORE_COPY.with_borrow_mut(|hook| *hook = None);
        }
    }
    let _reset = ResetHook;
    BEFORE_COPY.with_borrow_mut(|slot| {
        assert!(slot.is_none());
        *slot = Some(Box::new(hook));
    });
    receive();
    assert!(
        BEFORE_COPY.with_borrow(|slot| slot.is_none()),
        "copy hook did not run"
    );
}

#[derive(Clone, Copy, Debug)]
enum Lane {
    Video,
    Audio,
    Input,
}

const PAYLOAD_SIZE: usize = 4096;
const SENTINEL: u32 = 0xfeed;

fn endpoint(lane: Lane) -> PlankTransportNativeEndpoint {
    let shared = Arc::new(NativeShared::new(false, false, 150_000_000));
    shared.set_state(EndpointState::Ready);
    // No worker/network is started: use the real synchronous C receive entry
    // points with queues filled by the production video/audio producer helpers.
    PlankTransportNativeEndpoint {
        config: EndpointConfig::Client {
            remote_address: "127.0.0.1:28989".parse().unwrap(),
            server_name: "localhost".into(),
            certificate_sha256: None,
            session_token: "test-only".into(),
            setup_mode: false,
            options: super::super::RuntimeOptions {
                handshake_timeout: Duration::from_secs(5),
                idle_timeout: Duration::from_secs(5),
                keep_alive_interval: Duration::from_secs(1),
                max_udp_payload_size: None,
                initial_video_bitrate_bps: 150_000_000,
            },
        },
        mode: if matches!(lane, Lane::Input) { 1 } else { 2 },
        shared,
        worker: Mutex::new(None),
    }
}

fn payload(tag: u64) -> Bytes {
    let mut bytes = vec![tag as u8; PAYLOAD_SIZE];
    bytes[..8].copy_from_slice(&tag.to_be_bytes());
    bytes.into()
}

fn push(lane: Lane, shared: &NativeShared, tag: u64) {
    match lane {
        Lane::Video => push_video_receive(
            shared,
            NativeVideoFrame {
                #[cfg(feature = "sender-timing")]
                enqueued_at: Instant::now(),
                codec: VIDEO_CODEC_HEVC,
                flags: VIDEO_FLAG_KEY,
                frame_number: tag,
                pts: tag * 1000,
                host_processing_latency: 123,
                payload: payload(tag),
            },
        ),
        Lane::Audio => push_audio_receive(
            shared,
            NativeAudioPacket {
                pts: tag * 1000,
                frame_samples: 960,
                missing_samples: 0,
                payload: payload(tag),
            },
        ),
        Lane::Input => {
            let mut queues = shared.queues.lock().unwrap();
            assert!(queues.input_receive.len() < INPUT_RECEIVE_CAPACITY);
            queues.input_receive.push_back(NativeInputPacket {
                type_: 42,
                payload: payload(tag),
            });
            drop(queues);
            shared.input_receive_changed.notify_one();
        }
    }
}

fn receive(
    lane: Lane,
    endpoint: &PlankTransportNativeEndpoint,
    output: *mut u8,
    capacity: usize,
    size: &mut usize,
    timeout_ms: u32,
) -> i32 {
    let endpoint = ptr::from_ref(endpoint).cast_mut();
    match lane {
        Lane::Video => {
            let mut info: PlankTransportNativeVideoFrameInfo = unsafe { std::mem::zeroed() };
            info.struct_size = SENTINEL;
            let result = unsafe {
                plank_transport_native_video_receive(
                    endpoint, &mut info, output, capacity, size, timeout_ms,
                )
            };
            if result == PLANK_TRANSPORT_OK {
                let tag = u64::from_be_bytes(
                    unsafe { std::slice::from_raw_parts(output, 8) }
                        .try_into()
                        .unwrap(),
                );
                assert_eq!(info.struct_size as usize, std::mem::size_of_val(&info));
                assert_eq!(info.codec, VIDEO_CODEC_HEVC);
                assert_eq!(info.flags, VIDEO_FLAG_KEY);
                assert_eq!(info.frame_number, tag);
                assert_eq!(info.pts, tag * 1000);
                assert_eq!(info.host_processing_latency, 123);
                assert_eq!(info.reserved, 0);
                assert_eq!(info.reserved2, [0; 6]);
            } else {
                assert_eq!(info.struct_size, SENTINEL);
            }
            result
        }
        Lane::Audio => {
            let mut info: PlankTransportNativeAudioPacketInfo = unsafe { std::mem::zeroed() };
            info.struct_size = SENTINEL;
            let result = unsafe {
                plank_transport_native_audio_receive(
                    endpoint, &mut info, output, capacity, size, timeout_ms,
                )
            };
            if result == PLANK_TRANSPORT_OK {
                let tag = u64::from_be_bytes(
                    unsafe { std::slice::from_raw_parts(output, 8) }
                        .try_into()
                        .unwrap(),
                );
                assert_eq!(info.struct_size as usize, std::mem::size_of_val(&info));
                assert_eq!(info.pts, tag * 1000);
                assert_eq!(info.frame_samples, 960);
                assert_eq!(info.missing_samples, 0);
                assert_eq!(info.reserved, 0);
                assert_eq!(info.reserved2, 0);
            } else {
                assert_eq!(info.struct_size, SENTINEL);
            }
            result
        }
        Lane::Input => {
            let mut type_ = 255;
            let result = unsafe {
                plank_transport_native_input_receive(
                    endpoint, &mut type_, output, capacity, size, timeout_ms,
                )
            };
            assert_eq!(
                type_,
                if result == PLANK_TRANSPORT_OK {
                    42
                } else {
                    255
                }
            );
            result
        }
    }
}

fn read_tag(lane: Lane, endpoint: &PlankTransportNativeEndpoint) -> Result<u64, i32> {
    // Canary bytes after the exact advertised capacity must remain untouched.
    let mut output = vec![0x5a; PAYLOAD_SIZE + 16];
    let mut size = 0;
    let result = receive(
        lane,
        endpoint,
        output.as_mut_ptr(),
        PAYLOAD_SIZE,
        &mut size,
        0,
    );
    if result != PLANK_TRANSPORT_OK {
        return Err(result);
    }
    assert_eq!(size, PAYLOAD_SIZE);
    assert_eq!(&output[PAYLOAD_SIZE..], &[0x5a; 16]);
    let tag = u64::from_be_bytes(output[..8].try_into().unwrap());
    assert!(output[8..size].iter().all(|&value| value == tag as u8));
    Ok(tag)
}

fn capacity(lane: Lane) -> usize {
    match lane {
        Lane::Video => VIDEO_RECEIVE_CAPACITY,
        Lane::Audio => AUDIO_RECEIVE_CAPACITY,
        Lane::Input => INPUT_RECEIVE_CAPACITY,
    }
}

fn check_overflow_during_copy(lane: Lane) {
    let endpoint = endpoint(lane);
    let capacity = capacity(lane) as u64;
    for tag in 0..capacity {
        push(lane, &endpoint.shared, tag);
    }
    let shared = endpoint.shared.clone();
    interleave_before_copy(
        move || {
            // This is the actual C ABI call after claiming, before payload copy.
            // Prove it is not holding the shared lock during the large copy.
            drop(
                shared
                    .queues
                    .try_lock()
                    .expect("copy must run outside queue lock"),
            );
            push(lane, &shared, capacity);
            push(lane, &shared, capacity + 1);
        },
        || assert_eq!(read_tag(lane, &endpoint), Ok(0)),
    );

    let drops = match lane {
        Lane::Video => endpoint
            .shared
            .stats
            .video_receive_drops
            .load(Ordering::Relaxed),
        Lane::Audio => endpoint
            .shared
            .stats
            .audio_receive_drops
            .load(Ordering::Relaxed),
        Lane::Input => unreachable!(),
    };
    // 0 belongs to the receiver; only 1 was overflow-evicted. Nothing may
    // remove 2 after the copy, and all remaining payloads/metadata stay paired.
    assert_eq!(drops, 1);
    for tag in 2..capacity + 2 {
        assert_eq!(read_tag(lane, &endpoint), Ok(tag));
    }
    assert_eq!(read_tag(lane, &endpoint), Err(PLANK_TRANSPORT_TIMEOUT));
}

#[test]
fn video_overflow_during_copy_does_not_evict_another_frame() {
    check_overflow_during_copy(Lane::Video);
}

#[test]
fn audio_overflow_during_copy_does_not_evict_another_packet() {
    check_overflow_during_copy(Lane::Audio);
}

#[test]
fn short_and_invalid_receive_buffers_leave_the_item_queued() {
    for lane in [Lane::Video, Lane::Audio, Lane::Input] {
        let endpoint = endpoint(lane);
        push(lane, &endpoint.shared, 7);
        push(lane, &endpoint.shared, 8);
        let mut output = [0x5a; 32];
        let mut size = 0;
        for capacity in [0, output.len()] {
            assert_eq!(
                receive(lane, &endpoint, output.as_mut_ptr(), capacity, &mut size, 0),
                PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL
            );
            assert_eq!(size, PAYLOAD_SIZE);
            assert_eq!(output, [0x5a; 32]);
        }
        assert_eq!(
            receive(lane, &endpoint, ptr::null_mut(), 0, &mut size, 0),
            PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL
        );
        assert_eq!(size, PAYLOAD_SIZE);
        assert_eq!(
            receive(lane, &endpoint, ptr::null_mut(), PAYLOAD_SIZE, &mut size, 0),
            PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT
        );
        assert_eq!(size, PAYLOAD_SIZE);
        assert_eq!(read_tag(lane, &endpoint), Ok(7));
        assert_eq!(read_tag(lane, &endpoint), Ok(8));
        assert_eq!(read_tag(lane, &endpoint), Err(PLANK_TRANSPORT_TIMEOUT));
    }
}

#[test]
fn overlapping_receivers_claim_distinct_items_before_copying() {
    for lane in [Lane::Video, Lane::Audio, Lane::Input] {
        let endpoint = Arc::new(endpoint(lane));
        push(lane, &endpoint.shared, 0);
        push(lane, &endpoint.shared, 1);
        push(lane, &endpoint.shared, 2);
        let other_reader = endpoint.clone();
        interleave_before_copy(
            move || {
                assert_eq!(read_tag(lane, &other_reader), Ok(1));
            },
            || assert_eq!(read_tag(lane, &endpoint), Ok(0)),
        );
        assert_eq!(read_tag(lane, &endpoint), Ok(2));
        assert_eq!(read_tag(lane, &endpoint), Err(PLANK_TRANSPORT_TIMEOUT));
    }
}

#[test]
fn concurrent_readers_return_every_queued_item_exactly_once() {
    for lane in [Lane::Video, Lane::Audio, Lane::Input] {
        for _ in 0..20 {
            let endpoint = Arc::new(endpoint(lane));
            for tag in 0..capacity(lane) as u64 {
                push(lane, &endpoint.shared, tag);
            }
            let start = Arc::new(Barrier::new(4));
            let mut readers = Vec::new();
            for _ in 0..4 {
                let endpoint = endpoint.clone();
                let start = start.clone();
                readers.push(std::thread::spawn(move || {
                    start.wait();
                    let mut tags = Vec::new();
                    loop {
                        match read_tag(lane, &endpoint) {
                            Ok(tag) => tags.push(tag),
                            Err(PLANK_TRANSPORT_TIMEOUT) => break,
                            Err(result) => panic!("receive failed: {result}"),
                        }
                    }
                    tags
                }));
            }
            let mut tags: Vec<u64> = readers
                .into_iter()
                .flat_map(|reader| reader.join().unwrap())
                .collect();
            tags.sort_unstable();
            assert_eq!(tags, (0..capacity(lane) as u64).collect::<Vec<_>>());
        }
    }
}

#[test]
fn audio_hole_can_be_claimed_without_a_payload_buffer() {
    let mut endpoint = endpoint(Lane::Audio);
    push_audio_receive(
        &endpoint.shared,
        NativeAudioPacket {
            pts: 0,
            frame_samples: 960,
            missing_samples: 1920,
            payload: Bytes::new(),
        },
    );
    push(Lane::Audio, &endpoint.shared, 3);
    let mut info: PlankTransportNativeAudioPacketInfo = unsafe { std::mem::zeroed() };
    let mut size = usize::MAX;
    assert_eq!(
        unsafe {
            plank_transport_native_audio_receive(
                &mut endpoint,
                &mut info,
                ptr::null_mut(),
                0,
                &mut size,
                0,
            )
        },
        PLANK_TRANSPORT_OK
    );
    assert_eq!(size, 0);
    assert_eq!(info.frame_samples, 960);
    assert_eq!(info.missing_samples, 1920);
    assert_eq!(info.pts, 0);
    assert_eq!(read_tag(Lane::Audio, &endpoint), Ok(3));
    assert_eq!(
        read_tag(Lane::Audio, &endpoint),
        Err(PLANK_TRANSPORT_TIMEOUT)
    );
}

#[test]
fn empty_receive_timeout_and_failed_queue_drain_are_preserved() {
    for lane in [Lane::Video, Lane::Audio, Lane::Input] {
        let endpoint = endpoint(lane);
        let mut output = [0x5a; 32];
        let mut size = SENTINEL as usize;
        assert_eq!(
            receive(
                lane,
                &endpoint,
                output.as_mut_ptr(),
                output.len(),
                &mut size,
                2
            ),
            PLANK_TRANSPORT_TIMEOUT
        );
        assert_eq!(output, [0x5a; 32]);
        assert_eq!(size, SENTINEL as usize);
        push(lane, &endpoint.shared, 1);
        endpoint.shared.fail("test peer closed");
        assert_eq!(read_tag(lane, &endpoint), Ok(1));
        assert_eq!(
            read_tag(lane, &endpoint),
            Err(PLANK_TRANSPORT_ERROR_RUNTIME)
        );
    }
}
