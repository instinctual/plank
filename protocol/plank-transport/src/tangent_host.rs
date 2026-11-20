// SPDX-License-Identifier: AGPL-3.0-or-later
//! Linux VHCI boundary. Only a qualified panel is attached, and only validated
//! replies reach the kernel. No TCP USB/IP listener or peer-selected sysfs path.

use super::*;
use crate::tangent::{
    ATTACH_UNAVAILABLE, DEVICE_IO_FAILED, Generations, Kind, MAX_DEVICES, MAX_OUTSTANDING,
    MAX_OUTSTANDING_BYTES, PROFILE_REJECTED, USBIP_HEADER, element, word,
};
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::thread::JoinHandle;

const CONTROLLER: &str = "/sys/devices/platform/vhci_hcd.0";
const IO_WAIT: Duration = Duration::from_millis(100);

pub(super) fn available() -> bool {
    OpenOptions::new()
        .write(true)
        .open(Path::new(CONTROLLER).join("attach"))
        .is_ok()
}

fn free_ports(status: &str) -> Vec<u32> {
    status
        .lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<_> = line.split_whitespace().collect();
            if fields.len() < 7 || fields[0] != "hs" || fields[2] != "004" {
                return None;
            }
            fields[1].parse().ok().filter(|port| *port < 128)
        })
        .collect()
}

// Leave room for one UNLINK per forwarded submit, and for local read-ahead.
// Stopping the VHCI reader on a full window would strand cancellations behind
// an idle interrupt-IN. All three reserves together fit the protocol limit.
const ACTIVE_SUBMITS: usize = MAX_OUTSTANDING / 4;
const DEFERRED_SUBMITS: usize = MAX_OUTSTANDING - 2 * ACTIVE_SUBMITS;
const WINDOW_BYTES: usize = MAX_OUTSTANDING_BYTES / 2;

struct HostUsb {
    guard: element::Device,
    deferred: VecDeque<Vec<u8>>,
    deferred_bytes: usize,
    kernel: UnixStream,
    shared: Arc<NativeShared>,
    slot: u8,
    generation: u64,
}

impl HostUsb {
    fn forward(&mut self, bytes: &[u8]) -> Result<()> {
        self.guard
            .request(bytes)
            .map_err(|_| anyhow!("invalid USB transaction"))?;
        self.shared.tangent.send_record(
            &self.shared,
            Kind::Transfer,
            self.slot,
            self.generation,
            bytes,
        )
    }

    fn room(&self, bytes: &[u8]) -> bool {
        self.guard.transactions.slots_with_cancel_reserve() + 2 <= 2 * ACTIVE_SUBMITS
            && word(bytes, 24) as usize
                <= WINDOW_BYTES - self.guard.transactions.outstanding_bytes()
    }

    fn local_reply(&mut self, command: u32, seq: u32, status: i32) -> Result<()> {
        let mut reply = [0; USBIP_HEADER];
        reply[..4].copy_from_slice(&command.to_be_bytes());
        reply[4..8].copy_from_slice(&seq.to_be_bytes());
        reply[20..24].copy_from_slice(&status.to_be_bytes());
        self.kernel.write_all(&reply)?;
        Ok(())
    }

    fn request(&mut self, bytes: Vec<u8>) -> Result<()> {
        let seq = word(&bytes, 4);
        anyhow::ensure!(
            !self.guard.transactions.contains_sequence(seq)
                && !self.deferred.iter().any(|pending| word(pending, 4) == seq),
            "duplicate VHCI sequence"
        );
        if word(&bytes, 0) == 2 {
            let target = word(&bytes, 20);
            if let Some(index) = self
                .deferred
                .iter()
                .position(|pending| word(pending, 4) == target)
            {
                let pending = self.deferred.remove(index).unwrap();
                self.deferred_bytes -= word(&pending, 24) as usize;
                self.local_reply(4, seq, -104)?; // ECONNRESET; never sent to the panel
                return self.drain();
            }
            if self.guard.transactions.request_header(target).is_err() {
                return self.local_reply(4, seq, 0); // submit already completed
            }
            anyhow::ensure!(
                !self.guard.transactions.cancelling(target),
                "duplicate VHCI cancellation"
            );
            return self.forward(&bytes);
        }
        if self.deferred.is_empty() && self.room(&bytes) {
            return self.forward(&bytes);
        }
        let length = word(&bytes, 24) as usize;
        if self.deferred.len() == DEFERRED_SUBMITS || length > WINDOW_BYTES - self.deferred_bytes {
            // Both windows are bounded. Explicitly fail this unissued URB to
            // the local USB caller; never lose or replay a physical panel report.
            return self.local_reply(3, seq, -28); // ENOSPC
        }
        self.deferred_bytes += length;
        self.deferred.push_back(bytes);
        Ok(())
    }

    fn drain(&mut self) -> Result<()> {
        while self.deferred.front().is_some_and(|bytes| self.room(bytes)) {
            let bytes = self.deferred.pop_front().unwrap();
            self.deferred_bytes -= word(&bytes, 24) as usize;
            self.forward(&bytes)?;
        }
        Ok(())
    }

    fn respond(&mut self, bytes: &[u8]) -> Result<()> {
        self.guard
            .response(bytes)
            .map_err(|_| anyhow!("invalid Tangent USB response"))?;
        self.kernel.write_all(bytes)?;
        self.drain()
    }
}

struct VirtualDevice {
    io: UnixStream,
    flow: Arc<Mutex<HostUsb>>,
    stop: Arc<AtomicBool>,
    reader: Option<JoinHandle<()>>,
}

impl VirtualDevice {
    fn new(
        io: UnixStream,
        manifest: element::Manifest,
        shared: Arc<NativeShared>,
        slot: u8,
        generation: u64,
    ) -> Result<Self> {
        io.set_read_timeout(Some(IO_WAIT))?;
        io.set_write_timeout(Some(Duration::from_secs(1)))?;
        let guard =
            element::Device::new(manifest).map_err(|_| anyhow!("invalid Tangent manifest"))?;
        let flow = HostUsb {
            guard,
            deferred: VecDeque::new(),
            deferred_bytes: 0,
            kernel: io.try_clone()?,
            shared,
            slot,
            generation,
        };
        Ok(Self {
            io,
            flow: Arc::new(Mutex::new(flow)),
            stop: Arc::new(AtomicBool::new(false)),
            reader: None,
        })
    }

    fn attach(
        manifest: element::Manifest,
        shared: Arc<NativeShared>,
        slot: u8,
        generation: u64,
    ) -> Result<Self> {
        let id = manifest.device_id;
        let (io, kernel) = UnixStream::pair()?;
        let device = Self::new(io, manifest, shared, slot, generation)?;
        let controller = Path::new(CONTROLLER);
        let status = fs::read_to_string(controller.join("status"))?;
        let mut attached = false;
        for port in free_ports(&status) {
            let mut attach = OpenOptions::new()
                .write(true)
                .open(controller.join("attach"))?;
            let command = format!("{port} {} {id} 2", kernel.as_raw_fd());
            // Kernel serializes port ownership; retry another free port if
            // another local USB/IP user won this slot after the snapshot.
            match attach.write(command.as_bytes()) {
                Ok(size) if size == command.len() => {
                    attached = true;
                    break;
                }
                Err(e) if e.raw_os_error() == Some(16) => continue, // EBUSY
                Err(e) => return Err(e.into()),
                _ => return Err(anyhow!("partial VHCI attachment")),
            }
        }
        anyhow::ensure!(attached, "no available Tangent virtual USB port");
        // VHCI owns its descriptor reference. Closing our peer on every exit
        // disconnects exactly this device; no detach-by-port race is possible.
        Ok(device)
    }

    fn start(&mut self, shared: Arc<NativeShared>) -> Result<()> {
        let mut io = self.io.try_clone()?;
        let flow = self.flow.clone();
        let stop = self.stop.clone();
        self.reader = Some(
            std::thread::Builder::new()
                .name("plank-panel-vhci".into())
                .spawn(move || {
                    let result = (|| -> Result<()> {
                        loop {
                            let mut header = [0; USBIP_HEADER];
                            read_exact(&mut io, &mut header, &shared, &stop, None)?;
                            let size = flow
                                .lock()
                                .unwrap()
                                .guard
                                .request_size(&header)
                                .map_err(|_| anyhow!("unqualified Tangent USB request"))?;
                            let mut bytes = vec![0; size];
                            bytes[..USBIP_HEADER].copy_from_slice(&header);
                            read_exact(
                                &mut io,
                                &mut bytes[USBIP_HEADER..],
                                &shared,
                                &stop,
                                Some(Instant::now()),
                            )?;
                            let mut f = flow.lock().unwrap();
                            if stop.load(Ordering::Acquire) {
                                return Ok(());
                            }
                            f.request(bytes)?;
                        }
                    })();
                    if result.is_err() {
                        Self::fail(&io, &flow, &stop);
                    }
                })?,
        );
        Ok(())
    }

    fn fail(io: &UnixStream, flow: &Mutex<HostUsb>, stop: &AtomicBool) {
        // Wait out the last accepted request before publishing the failure.
        // The reader and reply path can observe the same close simultaneously.
        let f = flow.lock().unwrap();
        if !stop.swap(true, Ordering::AcqRel) {
            let _ = io.shutdown(Shutdown::Both);
            if f.shared
                .tangent
                .send_record(
                    &f.shared,
                    Kind::Failed,
                    f.slot,
                    f.generation,
                    &DEVICE_IO_FAILED,
                )
                .is_err()
            {
                // A lost generation barrier makes this peripheral lane unusable.
                f.shared.tangent.fail();
            }
        }
    }

    fn deliver(&self, bytes: &[u8]) -> Result<()> {
        let mut flow = self.flow.lock().unwrap();
        if self.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        flow.respond(bytes)
    }
}

impl Drop for VirtualDevice {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = self.io.shutdown(Shutdown::Both);
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

fn read_exact(
    io: &mut UnixStream,
    bytes: &mut [u8],
    shared: &NativeShared,
    stop: &AtomicBool,
    mut partial_since: Option<Instant>,
) -> Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        anyhow::ensure!(
            !stop.load(Ordering::Acquire) && shared.tangent.alive(shared),
            "Tangent device stopped"
        );
        match io.read(&mut bytes[offset..]) {
            Ok(0) => return Err(anyhow!("Tangent virtual device closed")),
            Ok(size) => {
                offset += size;
                partial_since.get_or_insert_with(Instant::now);
            }
            Err(e)
                if [
                    io::ErrorKind::WouldBlock,
                    io::ErrorKind::TimedOut,
                    io::ErrorKind::Interrupted,
                ]
                .contains(&e.kind()) => {}
            Err(e) => return Err(e.into()),
        }
        anyhow::ensure!(
            partial_since.is_none_or(|since| since.elapsed() < Duration::from_secs(5)),
            "incomplete Tangent USB request"
        );
    }
    Ok(())
}

#[derive(Default)]
struct Bus {
    generations: Generations,
    devices: [Option<VirtualDevice>; MAX_DEVICES as usize],
}
impl Bus {
    fn receive(
        &mut self,
        record: Record<'_>,
        shared: &Arc<NativeShared>,
        panels: element::Panels,
    ) -> Result<()> {
        let slot = usize::from(record.slot);
        match record.kind {
            Kind::Attach => {
                self.generations
                    .attach(record.slot, record.generation)
                    .map_err(|_| anyhow!("stale Tangent attachment"))?;
                let Some(manifest) = element::Manifest::decode(record.body)
                    .ok()
                    .filter(|m| m.allowed_by(panels))
                else {
                    return shared.tangent.send_record(
                        shared,
                        Kind::Failed,
                        record.slot,
                        record.generation,
                        &PROFILE_REJECTED,
                    );
                };
                match VirtualDevice::attach(
                    manifest,
                    shared.clone(),
                    record.slot,
                    record.generation,
                ) {
                    Ok(mut device) => {
                        shared.tangent.send_record(
                            shared,
                            Kind::Ready,
                            record.slot,
                            record.generation,
                            &[],
                        )?;
                        if device.start(shared.clone()).is_ok() {
                            self.devices[slot] = Some(device);
                        } else {
                            shared.tangent.send_record(
                                shared,
                                Kind::Failed,
                                record.slot,
                                record.generation,
                                &DEVICE_IO_FAILED,
                            )?;
                        }
                    }
                    Err(_) => shared.tangent.send_record(
                        shared,
                        Kind::Failed,
                        record.slot,
                        record.generation,
                        &ATTACH_UNAVAILABLE,
                    )?,
                }
                // Retain this generation until the peer's ordered Detach barrier.
            }
            Kind::Transfer => {
                self.generations
                    .check(record.slot, record.generation)
                    .map_err(|_| anyhow!("stale Tangent response"))?;
                if let Some(device) = &self.devices[slot]
                    && device.deliver(record.body).is_err()
                {
                    VirtualDevice::fail(&device.io, &device.flow, &device.stop);
                    self.devices[slot] = None;
                }
            }
            Kind::Detach | Kind::Failed => {
                self.generations
                    .detach(record.slot, record.generation)
                    .map_err(|_| anyhow!("stale Tangent detach"))?;
                self.devices[slot] = None;
            }
            Kind::Ready => return Err(anyhow!("unexpected Tangent client acknowledgement")),
        }
        Ok(())
    }
}

pub(super) fn run(shared: Arc<NativeShared>, panels: element::Panels) -> Result<()> {
    let mut bus = Bus::default();
    while let Some(bytes) = shared.tangent.receive_record(&shared)? {
        bus.receive(
            Record::decode(&bytes).map_err(|_| anyhow!("invalid Tangent record"))?,
            &shared,
            panels,
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tangent::MAX_TRANSFER;
    use crate::tangent::tests::{reply, submit, unlink, unlink_reply};

    fn connection() -> Arc<NativeShared> {
        let shared = Arc::new(NativeShared::new(false, 100_000_000));
        shared.set_state(EndpointState::Ready);
        shared.tangent.state.lock().unwrap().status = 2;
        shared
    }

    fn pair(shared: &Arc<NativeShared>, slot: u8, generation: u64) -> (VirtualDevice, UnixStream) {
        let (app, kernel) = UnixStream::pair().unwrap();
        kernel
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let manifest =
            element::Manifest::new(0x10002, &element::tests::descriptors(), element::REPORT)
                .unwrap();
        (
            VirtualDevice::new(app, manifest, shared.clone(), slot, generation).unwrap(),
            kernel,
        )
    }

    fn take_record(shared: &NativeShared) -> (Kind, u8, Vec<u8>) {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(bytes) = shared.tangent.state.lock().unwrap().send.pop() {
                shared.tangent.received.notify_all();
                let r = Record::decode(&bytes).unwrap();
                return (r.kind, r.slot, r.body.to_vec());
            }
            assert!(Instant::now() < deadline, "missing panel record");
            std::thread::yield_now();
        }
    }

    fn read_reply(kernel: &mut UnixStream) -> (u32, u32, i32) {
        let mut h = [0; USBIP_HEADER];
        kernel.read_exact(&mut h).unwrap();
        (word(&h, 0), word(&h, 4), word(&h, 20) as i32)
    }

    #[test]
    fn full_window_keeps_cancellation_live_and_drains_submits_in_order() {
        for length in [15, MAX_TRANSFER] {
            let shared = connection();
            let (mut dev, mut kernel) = pair(&shared, 0, 1);
            dev.start(shared.clone()).unwrap();
            let active = ACTIVE_SUBMITS.min(WINDOW_BYTES / length) as u32;
            let waiting = DEFERRED_SUBMITS.min(WINDOW_BYTES / length) as u32;
            for seq in 1..=active + waiting + 1 {
                kernel.write_all(&submit(seq, true, length)).unwrap();
            }
            // The final, unissued submit is explicitly completed only to VHCI.
            assert_eq!(read_reply(&mut kernel), (3, active + waiting + 1, -28));
            for seq in 1..=active {
                assert_eq!(
                    take_record(&shared),
                    (Kind::Transfer, 0, submit(seq, true, length))
                );
            }
            // Unlink a deferred read and all active reads without any USB traffic.
            kernel.write_all(&unlink(200, active + 1)).unwrap();
            assert_eq!(read_reply(&mut kernel), (4, 200, -104));
            for seq in 1..=active {
                let cancel = unlink(300 + seq, seq);
                kernel.write_all(&cancel).unwrap();
                assert_eq!(take_record(&shared), (Kind::Transfer, 0, cancel));
            }
            let mut cancelled = unlink_reply(301);
            cancelled[20..24].copy_from_slice(&(-104i32).to_be_bytes());
            dev.deliver(&cancelled).unwrap();
            assert_eq!(read_reply(&mut kernel), (4, 301, -104));
            assert_eq!(
                take_record(&shared),
                (Kind::Transfer, 0, submit(active + 2, true, length))
            );
            assert!(shared.tangent.state.lock().unwrap().send.pop().is_none());
            assert!(!dev.stop.load(Ordering::Acquire));
        }
    }

    #[test]
    fn mf_only_session_rejects_an_extended_model_without_opening_vhci() {
        let shared = connection();
        let mut bus = Bus::default();
        let mut desc = element::tests::descriptors();
        desc[10] = 0x1f;
        let body = element::Manifest::new(0x10002, &desc, element::REPORT)
            .unwrap()
            .encode();
        let record = Record {
            kind: Kind::Attach,
            slot: 2,
            generation: 1,
            body: &body,
        };
        bus.receive(record, &shared, element::Panels::Mf).unwrap();
        assert_eq!(
            take_record(&shared),
            (Kind::Failed, 2, PROFILE_REJECTED.to_vec())
        );
        bus.receive(
            Record {
                kind: Kind::Detach,
                body: &[],
                ..record
            },
            &shared,
            element::Panels::Mf,
        )
        .unwrap();
        assert!(bus.devices[2].is_none());
        assert_eq!(shared.state(), EndpointState::Ready);
    }

    #[test]
    fn failed_socket_only_retires_its_panel_and_a_new_generation_can_use_the_slot() {
        let shared = connection();
        let mut bus = Bus::default();
        let mut kernels = Vec::new();
        for slot in 0..2 {
            let (mut dev, mut kernel) = pair(&shared, slot, 1);
            dev.start(shared.clone()).unwrap();
            bus.devices[usize::from(slot)] = Some(dev);
            bus.generations.attach(slot, 1).unwrap();
            let request = submit(1, false, 4);
            kernel.write_all(&request).unwrap();
            assert_eq!(take_record(&shared), (Kind::Transfer, slot, request));
            kernels.push(kernel);
        }
        // Leave the kernel write half open, but its read half closed, so the
        // fault occurs specifically inside the network-to-VHCI reply path.
        kernels[0].shutdown(Shutdown::Read).unwrap();
        let completion = reply(1, 4, false);
        let mut record = Record {
            kind: Kind::Transfer,
            slot: 0,
            generation: 1,
            body: &completion,
        };
        bus.receive(record, &shared, element::Panels::Element)
            .unwrap();
        assert_eq!(take_record(&shared), (Kind::Failed, 0, vec![0, 2]));
        bus.receive(record, &shared, element::Panels::Element)
            .unwrap(); // raced failure
        assert!(shared.tangent.state.lock().unwrap().send.pop().is_none());
        record.slot = 1;
        bus.receive(record, &shared, element::Panels::Element)
            .unwrap();
        assert_eq!(read_reply(&mut kernels[1]), (3, 1, 0));
        assert!(bus.devices[1].is_some());
        bus.receive(
            Record {
                kind: Kind::Detach,
                slot: 0,
                generation: 1,
                body: &[],
            },
            &shared,
            element::Panels::Element,
        )
        .unwrap();
        bus.generations.attach(0, 2).unwrap();
        assert!(bus.generations.check(0, 1).is_err());
        bus.generations.check(1, 1).unwrap();
        assert_eq!(shared.state(), EndpointState::Ready);
    }

    #[test]
    fn only_unused_usb2_ports_are_candidates() {
        let status = "hub port sta spd dev sockfd local_busid\nhs 0000 004 000 00000000 0 0-0\nhs 0001 006 002 00010002 5 9-1\nss 0002 004 000 00000000 0 0-0\nhs 9999 004 000 00000000 0 0-0\n";
        assert_eq!(free_ports(status), vec![0]);
        assert!(free_ports("not a status file").is_empty());
    }
}
