// SPDX-License-Identifier: AGPL-3.0-or-later
//! Optional reliable Tangent bus on the existing authenticated connection.
//! Failure retires this bus without taking down desktop media or ordinary input.

use super::*;
#[cfg(target_os = "linux")]
use crate::tangent::Kind;
use crate::tangent::{MAX_BODY, RECORD_HEADER, Record, VERSION};

#[cfg(all(target_os = "linux", feature = "tangent-client"))]
#[path = "tangent_client.rs"]
mod client;
#[cfg(target_os = "linux")]
#[path = "tangent_host.rs"]
mod host;

const ENDPOINT_ID: u16 = 8;
const QUEUE_BYTES: usize = 64 * 1024;
const QUEUE_RECORDS: usize = 128;

#[derive(Default)]
struct Queue {
    records: VecDeque<Bytes>,
    bytes: usize,
}
impl Queue {
    fn room(&self, size: usize) -> bool {
        self.records.len() < QUEUE_RECORDS && size <= QUEUE_BYTES - self.bytes
    }
    fn push(&mut self, record: Bytes) {
        assert!(self.room(record.len()));
        self.bytes += record.len();
        self.records.push_back(record);
    }
    fn pop(&mut self) -> Option<Bytes> {
        let record = self.records.pop_front()?;
        self.bytes -= record.len();
        Some(record)
    }
}

#[derive(Default)]
struct State {
    enabled: bool,
    status: u32,
    send: Queue,
    receive: Queue,
}

#[derive(Default)]
pub(super) struct Tangent {
    state: Mutex<State>,
    changed: tokio::sync::Notify,
    space: tokio::sync::Notify,
    received: Condvar,
    failed: tokio::sync::Notify,
    worker: Mutex<Option<std::thread::JoinHandle<()>>>,
}
impl Tangent {
    pub(super) fn stop_worker(&self) {
        self.wake();
        if let Some(worker) = self.worker.lock().unwrap().take() {
            let _ = worker.join();
        }
    }

    #[cfg(target_os = "linux")]
    fn alive(&self, shared: &NativeShared) -> bool {
        shared.state() == EndpointState::Ready && {
            let state = self.state.lock().unwrap();
            state.status == 1 || state.status == 2
        }
    }

    #[cfg(target_os = "linux")]
    fn send_record(
        &self,
        shared: &NativeShared,
        kind: Kind,
        slot: u8,
        generation: u64,
        body: &[u8],
    ) -> Result<()> {
        let bytes = Record {
            kind,
            slot,
            generation,
            body,
        }
        .encode()
        .map_err(|_| anyhow!("invalid local Tangent record"))?;
        let deadline = Instant::now() + Duration::from_secs(1);
        let mut state = self.state.lock().unwrap();
        loop {
            anyhow::ensure!(
                shared.state() == EndpointState::Ready && [1, 2].contains(&state.status),
                "Tangent lane stopped"
            );
            if state.status == 2 && state.send.room(bytes.len()) {
                state.send.push(Bytes::from(bytes));
                drop(state);
                self.changed.notify_one();
                return Ok(());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            anyhow::ensure!(!remaining.is_zero(), "Tangent peer did not drain its queue");
            (state, _) = self.received.wait_timeout(state, remaining).unwrap();
        }
    }

    #[cfg(any(target_os = "linux", test))]
    fn receive_record(&self, shared: &NativeShared) -> Result<Option<Bytes>> {
        let mut state = self.state.lock().unwrap();
        loop {
            if shared.state() != EndpointState::Ready || state.status == 3 {
                return Ok(None);
            }
            if let Some(bytes) = state.receive.pop() {
                drop(state);
                self.space.notify_one();
                return Ok(Some(bytes));
            }
            state = self.received.wait(state).unwrap();
        }
    }

    #[cfg(all(target_os = "linux", feature = "tangent-client"))]
    fn receive_record_timeout(
        &self,
        shared: &NativeShared,
        timeout: Duration,
    ) -> Result<Option<Bytes>> {
        let deadline = Instant::now() + timeout;
        let mut state = self.state.lock().unwrap();
        loop {
            if shared.state() != EndpointState::Ready || state.status == 3 {
                return Ok(None);
            }
            if let Some(bytes) = state.receive.pop() {
                drop(state);
                self.space.notify_one();
                return Ok(Some(bytes));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Ok(None);
            }
            (state, _) = self.received.wait_timeout(state, remaining).unwrap();
        }
    }
    pub(super) fn wake(&self) {
        // Pair the wake with the same mutex used by the C receive predicate.
        let _state = self.state.lock().unwrap();
        self.received.notify_all();
        self.changed.notify_waiters();
        self.space.notify_waiters();
    }
    fn fail(&self) {
        let mut state = self.state.lock().unwrap();
        state.status = 3;
        state.send = Queue::default();
        state.receive = Queue::default();
        self.received.notify_all();
        self.failed.notify_one();
    }
}

async fn connected(
    shared: &NativeShared,
    connection: &kyproto::Connection,
    client: bool,
) -> Result<()> {
    let (mut send, mut receive) = tokio::time::timeout(Duration::from_secs(5), async {
        if client {
            Ok::<_, anyhow::Error>(
                connection
                    .connect_data_endpoint(ENDPOINT_ID)?
                    .ready()
                    .await?,
            )
        } else {
            let (id, endpoint) = connection.register_data_endpoint().await?;
            anyhow::ensure!(id == ENDPOINT_ID, "unexpected Tangent endpoint allocation");
            Ok(endpoint.ready().await?)
        }
    })
    .await
    .context("Tangent endpoint readiness timed out")??;
    {
        let mut state = shared.tangent.state.lock().unwrap();
        anyhow::ensure!(state.status == 1, "Tangent backend stopped during setup");
        state.status = 2;
        shared.tangent.received.notify_all();
    }
    let sender = async {
        loop {
            let changed = shared.tangent.changed.notified();
            let record = shared.tangent.state.lock().unwrap().send.pop();
            if let Some(payload) = record {
                shared.tangent.received.notify_all();
                send.send(DataPacket { payload }).await?;
            } else {
                changed.await;
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    let receiver = async {
        while let Some(packet) = receive.recv().await? {
            Record::decode(&packet.payload).map_err(|_| anyhow!("invalid Tangent record"))?;
            loop {
                let space = shared.tangent.space.notified();
                {
                    let mut state = shared.tangent.state.lock().unwrap();
                    if state.receive.room(packet.payload.len()) {
                        state.receive.push(packet.payload);
                        shared.tangent.received.notify_one();
                        break;
                    }
                }
                // Retain this one bounded record and propagate stream flow
                // control. Keyboard, media and the main control lane are separate.
                space.await;
            }
        }
        Err::<(), anyhow::Error>(anyhow!("Tangent peer closed its data stream"))
    };
    tokio::try_join!(sender, receiver)?;
    Ok(())
}

/// Returns whether this process can use the Linux virtual USB controller.
/// No device is attached, no driver is loaded, and no network listener is opened.
#[unsafe(no_mangle)]
pub extern "C" fn plank_transport_native_tangent_host_available() -> i32 {
    #[cfg(target_os = "linux")]
    {
        i32::from(host::available())
    }
    #[cfg(not(target_os = "linux"))]
    {
        0
    }
}

/// # Safety
/// Endpoint must be live and session-authenticated. Call only after capability
/// agreement. This starts the Linux device boundary, not merely a raw data lane.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_tangent_host_enable(
    endpoint: *mut PlankTransportNativeEndpoint,
    version: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint_ref) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint_ref.mode != 1 || plank_transport_native_tangent_host_available() == 0 {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let result = unsafe { plank_transport_native_tangent_enable(endpoint, version) };
        if result != PLANK_TRANSPORT_OK {
            return result;
        }
        #[cfg(target_os = "linux")]
        {
            let shared = endpoint_ref.shared.clone();
            match std::thread::Builder::new()
                .name("plank-panel-host".into())
                .spawn(move || {
                    if let Err(error) = host::run(shared.clone()) {
                        eprintln!("PLANK Tangent Host forwarding stopped: {error}");
                    }
                    shared.tangent.fail();
                }) {
                Ok(worker) => *endpoint_ref.shared.tangent.worker.lock().unwrap() = Some(worker),
                Err(_) => {
                    endpoint_ref.shared.tangent.fail();
                    return PLANK_TRANSPORT_ERROR_RUNTIME;
                }
            }
        }
        PLANK_TRANSPORT_OK
    })
}

/// Logical Client session ownership survives replacement of a QUIC endpoint.
/// The runtime-directory lock also covers separate GUI processes for this user.
pub struct PlankTransportTangentClient {
    #[cfg(all(target_os = "linux", feature = "tangent-client"))]
    lease: Arc<std::fs::File>,
}

#[cfg(all(target_os = "linux", feature = "tangent-client"))]
fn claim_client_lease(directory: &std::path::Path) -> Result<std::fs::File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let metadata = directory.metadata()?;
    let uid = unsafe { libc::geteuid() };
    anyhow::ensure!(
        metadata.is_dir() && metadata.uid() == uid && metadata.mode() & 0o077 == 0,
        "unprotected runtime directory"
    );
    let lease = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(directory.join("plank-tangent-panels.lock"))?;
    let metadata = lease.metadata()?;
    anyhow::ensure!(
        metadata.is_file()
            && metadata.uid() == uid
            && metadata.nlink() == 1
            && metadata.mode() & 0o077 == 0,
        "unprotected panel ownership file"
    );
    lease.try_lock()?;
    Ok(lease)
}

/// # Safety
/// Output must point to writable storage. No physical device is opened here.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_tangent_client_create(
    output: *mut *mut PlankTransportTangentClient,
) -> i32 {
    catch_result(|| {
        if output.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        unsafe {
            *output = ptr::null_mut();
        }
        #[cfg(all(target_os = "linux", feature = "tangent-client"))]
        {
            let create = || -> Result<std::fs::File> {
                let directory = std::path::PathBuf::from(
                    std::env::var_os("XDG_RUNTIME_DIR")
                        .ok_or_else(|| anyhow!("missing user runtime directory"))?,
                );
                claim_client_lease(&directory)
            };
            match create() {
                Ok(lease) => unsafe {
                    *output = Box::into_raw(Box::new(PlankTransportTangentClient {
                        lease: Arc::new(lease),
                    }));
                },
                Err(_) => return PLANK_TRANSPORT_ERROR_INVALID_STATE,
            }
            PLANK_TRANSPORT_OK
        }
        #[cfg(not(all(target_os = "linux", feature = "tangent-client")))]
        {
            PLANK_TRANSPORT_ERROR_INVALID_STATE
        }
    })
}

/// # Safety
/// Owner is null or the live unique pointer returned by create. Stop associated
/// endpoints first. Do not unlink its lock file: another session may be waiting.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_tangent_client_destroy(
    owner: *mut PlankTransportTangentClient,
) {
    if !owner.is_null() {
        drop(unsafe { Box::from_raw(owner) });
    }
}

/// # Safety
/// Endpoint and owner must be live, and the authenticated Host must have agreed
/// to schema1. Ownership remains until owner destruction, independent of focus.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_tangent_client_enable(
    endpoint: *mut PlankTransportNativeEndpoint,
    owner: *const PlankTransportTangentClient,
    version: u32,
) -> i32 {
    catch_result(|| {
        let (Some(endpoint_ref), Some(owner)) =
            (unsafe { endpoint.as_ref() }, unsafe { owner.as_ref() })
        else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if endpoint_ref.mode != 2 {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        #[cfg(all(target_os = "linux", feature = "tangent-client"))]
        {
            let result = unsafe { plank_transport_native_tangent_enable(endpoint, version) };
            if result != PLANK_TRANSPORT_OK {
                return result;
            }
            let lease = owner.lease.clone();
            let shared = endpoint_ref.shared.clone();
            match std::thread::Builder::new()
                .name("plank-panel-client".into())
                .spawn(move || {
                    let _lease = lease;
                    if let Err(error) = client::run(shared.clone()) {
                        eprintln!("PLANK Tangent Client forwarding stopped: {error}");
                    }
                    shared.tangent.fail();
                }) {
                Ok(worker) => *endpoint_ref.shared.tangent.worker.lock().unwrap() = Some(worker),
                Err(_) => {
                    endpoint_ref.shared.tangent.fail();
                    return PLANK_TRANSPORT_ERROR_RUNTIME;
                }
            }
            PLANK_TRANSPORT_OK
        }
        #[cfg(not(all(target_os = "linux", feature = "tangent-client")))]
        {
            let _ = (owner, version);
            PLANK_TRANSPORT_ERROR_INVALID_STATE
        }
    })
}

pub(super) async fn run(shared: Arc<NativeShared>, connection: &kyproto::Connection, client: bool) {
    loop {
        let changed = shared.tangent.changed.notified();
        if shared.tangent.state.lock().unwrap().enabled {
            break;
        }
        changed.await;
    }
    // Drop both reliable streams if the local USB backend fails, so its peer
    // promptly removes the corresponding virtual devices too. Keeping the
    // transport task alive with only a failed queue would strand peer URBs.
    tokio::select! {
        _result = connected(&shared, connection, client) => {},
        _ = shared.tangent.failed.notified() => {},
    }
    shared.tangent.fail();
    // Do not end hold_client/hold_server because an optional peripheral failed.
    std::future::pending::<()>().await;
}

/// # Safety
/// Endpoint must be null or live. Caller must already have authenticated
/// agreement on Tangent schema1; this is not capability negotiation or consent.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_tangent_enable(
    endpoint: *mut PlankTransportNativeEndpoint,
    version: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if version != u32::from(VERSION) {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let mut state = endpoint.shared.tangent.state.lock().unwrap();
        if state.enabled {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        state.enabled = true;
        state.status = 1;
        drop(state);
        endpoint.shared.tangent.changed.notify_one();
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// Endpoint must be null or live. Returns disabled/starting/ready/failed (0..3).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_tangent_status(
    endpoint: *const PlankTransportNativeEndpoint,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        let status = endpoint.shared.tangent.state.lock().unwrap().status;
        if status != 0 && endpoint.shared.state() != EndpointState::Ready {
            3
        } else {
            status as i32
        }
    })
}

/// # Safety
/// Endpoint and non-null input storage must remain valid for this call.
/// TIMEOUT means retain the same record and retry; no record was accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_tangent_send(
    endpoint: *mut PlankTransportNativeEndpoint,
    payload: *const u8,
    size: usize,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if payload.is_null() || !(RECORD_HEADER..=RECORD_HEADER + MAX_BODY).contains(&size) {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        if endpoint.shared.state() != EndpointState::Ready {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        let bytes = unsafe { std::slice::from_raw_parts(payload, size) };
        if Record::decode(bytes).is_err() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        let mut state = endpoint.shared.tangent.state.lock().unwrap();
        if state.status != 2 {
            return PLANK_TRANSPORT_ERROR_INVALID_STATE;
        }
        if !state.send.room(size) {
            return PLANK_TRANSPORT_TIMEOUT;
        }
        state.send.push(Bytes::copy_from_slice(bytes));
        drop(state);
        endpoint.shared.tangent.changed.notify_one();
        PLANK_TRANSPORT_OK
    })
}

/// # Safety
/// Output pointers must name writable storage of the stated size. A short
/// buffer reports the required size and leaves the same record pending.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn plank_transport_native_tangent_receive(
    endpoint: *mut PlankTransportNativeEndpoint,
    payload: *mut u8,
    capacity: usize,
    size_out: *mut usize,
    timeout_ms: u32,
) -> i32 {
    catch_result(|| {
        let Some(endpoint) = (unsafe { endpoint.as_ref() }) else {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        };
        if size_out.is_null() {
            return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
        }
        unsafe {
            *size_out = 0;
        }
        let deadline = Instant::now() + Duration::from_millis(u64::from(timeout_ms));
        let mut state = endpoint.shared.tangent.state.lock().unwrap();
        loop {
            if endpoint.shared.state() != EndpointState::Ready
                || state.status == 0
                || state.status == 3
            {
                return PLANK_TRANSPORT_ERROR_INVALID_STATE;
            }
            if let Some(record) = state.receive.records.front() {
                let result = copy_bytes_out(record, payload, capacity, size_out);
                if result == PLANK_TRANSPORT_OK {
                    state.receive.pop();
                    drop(state);
                    endpoint.shared.tangent.space.notify_one();
                }
                return result;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return PLANK_TRANSPORT_TIMEOUT;
            }
            (state, _) = endpoint
                .shared
                .tangent
                .received
                .wait_timeout(state, remaining)
                .unwrap();
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(all(target_os = "linux", feature = "tangent-client"))]
    #[test]
    fn ownership_survives_endpoint_references_and_rejects_unsafe_paths() {
        use std::os::unix::fs::PermissionsExt;
        let directory = std::env::temp_dir().join(format!(
            "plank-panel-lease-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let logical_session = Arc::new(claim_client_lease(&directory).unwrap());
        let old_endpoint = logical_session.clone();
        drop(old_endpoint);
        assert!(claim_client_lease(&directory).is_err());
        let recovery_endpoint = logical_session.clone();
        drop(logical_session);
        assert!(claim_client_lease(&directory).is_err());
        drop(recovery_endpoint);
        drop(claim_client_lease(&directory).unwrap());
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(claim_client_lease(&directory).is_err());
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let lock = directory.join("plank-tangent-panels.lock");
        std::fs::remove_file(&lock).unwrap();
        std::os::unix::fs::symlink(directory.join("unrelated"), &lock).unwrap();
        assert!(claim_client_lease(&directory).is_err());
        assert!(!directory.join("unrelated").exists());
        std::fs::remove_file(lock).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }
    #[test]
    fn queues_bound_count_and_bytes_without_losing_order() {
        let mut q = Queue::default();
        for id in 0..16u8 {
            q.push(Bytes::from(vec![id; 4096]));
        }
        assert!(!q.room(1));
        for id in 0..16u8 {
            assert_eq!(q.pop().unwrap()[0], id);
        }
        assert_eq!(q.bytes, 0);
        for _ in 0..QUEUE_RECORDS {
            q.push(Bytes::from_static(b"x"));
        }
        assert!(!q.room(1));
        q.pop();
        assert!(q.room(1));
    }
    #[test]
    fn failure_retires_both_queues() {
        let bus = Tangent::default();
        {
            let mut s = bus.state.lock().unwrap();
            s.status = 2;
            s.send.push(Bytes::from_static(b"x"));
            s.receive.push(Bytes::from_static(b"y"));
        }
        bus.fail();
        let s = bus.state.lock().unwrap();
        assert_eq!(s.status, 3);
        assert_eq!(s.send.bytes, 0);
        assert_eq!(s.receive.bytes, 0);
    }

    #[test]
    fn stopping_wakes_blocked_backend_without_killing_desktop_on_panel_failure() {
        let shared = Arc::new(NativeShared::new(false, 100_000_000));
        shared.set_state(EndpointState::Ready);
        shared.tangent.state.lock().unwrap().status = 2;
        let receiver = shared.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            tx.send(receiver.tangent.receive_record(&receiver).unwrap())
                .unwrap()
        });
        shared.tangent.fail();
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), None);
        worker.join().unwrap();
        assert_eq!(shared.state(), EndpointState::Ready);
        shared.tangent.state.lock().unwrap().status = 2;
        let receiver = shared.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            tx.send(receiver.tangent.receive_record(&receiver).unwrap())
                .unwrap()
        });
        shared.set_state(EndpointState::Stopping);
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), None);
        worker.join().unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "run through scripts/test/run-plank-transport-native-loopback.sh"]
    async fn encrypted_panel_failure_closes_only_its_streams() {
        init_crypto_once();
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
            native::accept_server(&server, "panel-isolation", options),
            native::connect_client(address, "localhost", None, "panel-isolation", options)
        );
        let (host_connection, _video, _audio, _input, mut host_data) = host.unwrap().into_parts();
        let (client_connection, _cv, _ca, _ci, mut client_data, _) = client.unwrap().into_parts();
        let host = Arc::new(NativeShared::new(false, 150_000_000));
        let client = Arc::new(NativeShared::new(false, 150_000_000));
        for peer in [&host, &client] {
            peer.set_state(EndpointState::Ready);
            let mut state = peer.tangent.state.lock().unwrap();
            state.enabled = true;
            state.status = 1;
        }
        let observe = async {
            tokio::time::timeout(Duration::from_secs(5), async {
                while host.tangent.state.lock().unwrap().status != 2
                    || client.tangent.state.lock().unwrap().status != 2
                {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            })
            .await
            .unwrap();
            client.tangent.fail(); // equivalent to a local USB exporter failure
            tokio::time::timeout(Duration::from_secs(2), async {
                while host.tangent.state.lock().unwrap().status != 3 {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            })
            .await
            .expect("peer retained a dead panel lane");
            client_data
                .0
                .send(DataPacket {
                    payload: Bytes::from_static(b"desktop still connected"),
                })
                .await
                .unwrap();
            let packet = tokio::time::timeout(Duration::from_secs(2), host_data.1.recv())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            assert_eq!(packet.payload.as_ref(), b"desktop still connected");
            assert_eq!(host.state(), EndpointState::Ready);
            assert_eq!(client.state(), EndpointState::Ready);
        };
        tokio::select! {
            _ = run(host.clone(), &host_connection, false) => panic!("Host panel task returned"),
            _ = run(client.clone(), &client_connection, true) => panic!("Client panel task returned"),
            _ = observe => {},
        }
        host_connection.close();
        client_connection.close();
        server.close(0, "panel isolation completed");
        let _ = tokio::time::timeout(Duration::from_secs(1), server.wait_idle()).await;
    }
}
