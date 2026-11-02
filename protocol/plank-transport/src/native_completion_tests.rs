// SPDX-License-Identifier: AGPL-3.0-or-later
use super::*;

#[test]
fn orderly_peer_close_fails_all_live_phases() {
    for phase in [
        EndpointState::PeerValidation,
        EndpointState::SetupReady,
        EndpointState::Ready,
    ] {
        let shared = NativeShared::new(false, false, 150_000_000);
        shared.set_state(phase);
        finish_worker(&shared, Ok(()));
        assert_eq!(shared.state(), EndpointState::Failed);
        assert!(shared.status.lock().unwrap().error.contains("peer closed"));
    }
}

#[test]
fn explicit_local_stop_remains_stopped() {
    for result in [Ok(()), Err(anyhow!("closed during local shutdown"))] {
        let shared = NativeShared::new(false, false, 150_000_000);
        shared.stop.store(true, Ordering::Release);
        finish_worker(&shared, result);
        assert_eq!(shared.state(), EndpointState::Stopped);
        assert!(shared.status.lock().unwrap().error.is_empty());
    }
}

#[test]
fn transport_failure_keeps_original_error() {
    let shared = NativeShared::new(false, false, 150_000_000);
    finish_worker(&shared, Err(anyhow!("original transport error")));
    assert_eq!(shared.state(), EndpointState::Failed);
    assert_eq!(
        shared.status.lock().unwrap().error,
        "original transport error"
    );
}

#[test]
fn queued_control_precedes_peer_close() {
    let shared = NativeShared::new(false, false, 150_000_000);
    shared
        .queues
        .lock()
        .unwrap()
        .data_receive
        .push_back(Bytes::from_static(b"takeover"));
    finish_worker(&shared, Ok(()));
    let receive = || {
        wait_pop(
            &shared,
            &shared.data_receive_changed,
            Duration::ZERO,
            |queues| queues.data_receive.pop_front(),
        )
    };
    assert_eq!(receive(), Some(Bytes::from_static(b"takeover")));
    assert!(receive().is_none());
    assert_eq!(shared.state(), EndpointState::Failed);
}
