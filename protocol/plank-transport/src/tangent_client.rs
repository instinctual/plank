// SPDX-License-Identifier: AGPL-3.0-or-later
//! Qualified Tangent libusb exporter. Claims are local to the session process;
//! there is no persistent kernel bus-ID match table or privileged Client daemon.

use super::*;
use crate::tangent::{MAX_DEVICES, PROFILE_REJECTED, USBIP_HEADER, element, word};
use rusb::{Context, DeviceHandle, UsbContext};
use std::collections::{HashMap, HashSet};
use std::sync::RwLock;
use std::thread::JoinHandle;

const USB_TIMEOUT: Duration = Duration::from_millis(100);

struct Physical {
    handle: DeviceHandle<Context>,
    original_configuration: u8,
    original_kernel_driver: bool,
    configuration: RwLock<()>,
}
impl Drop for Physical {
    fn drop(&mut self) {
        let _ = self.handle.set_auto_detach_kernel_driver(false);
        let _ = self.handle.release_interface(0);
        if self.handle.active_configuration().ok() != Some(self.original_configuration) {
            let _ = self
                .handle
                .set_active_configuration(self.original_configuration);
        }
        if self.original_kernel_driver {
            let _ = self.handle.attach_kernel_driver(0);
        }
    }
}

impl Physical {
    fn open(
        device: rusb::Device<Context>,
        panels: element::Panels,
    ) -> std::result::Result<(Self, element::Manifest), OpenError> {
        let description = device.device_descriptor()?;
        if !panels.allows(description.vendor_id(), description.product_id())
            || device.speed() != rusb::Speed::Full
        {
            return Err(OpenError::Unsupported);
        }
        let handle = device.open()?;
        let mut descriptor = [0; 18];
        if handle.read_control(0x80, 6, 0x100, 0, &mut descriptor, USB_TIMEOUT)? != descriptor.len()
        {
            return Err(OpenError::Usb(rusb::Error::Io));
        }
        if !(1..=2).contains(&descriptor[17]) {
            return Err(OpenError::Unsupported);
        }
        let mut descriptors = descriptor.to_vec();
        for index in 0..descriptor[17] {
            let mut configuration = [0; 41];
            let count = handle.read_control(
                0x80,
                6,
                0x200 | u16::from(index),
                0,
                &mut configuration,
                USB_TIMEOUT,
            )?;
            if count >= 9 && u16::from_le_bytes([configuration[2], configuration[3]]) != 41 {
                return Err(OpenError::Unsupported);
            }
            if count != configuration.len() {
                return Err(OpenError::Usb(rusb::Error::Io));
            }
            descriptors.extend_from_slice(&configuration);
        }
        let device_id = (u32::from(device.bus_number()) << 16) | u32::from(device.address());
        let manifest = element::Manifest::new(device_id, &descriptors, element::REPORT)
            .map_err(|_| OpenError::Unsupported)?;
        if descriptors[8..10] != description.vendor_id().to_le_bytes()
            || descriptors[10..12] != description.product_id().to_le_bytes()
        {
            return Err(OpenError::Unsupported);
        }
        let original_configuration = handle.active_configuration()?;
        let original_kernel_driver = handle.kernel_driver_active(0)?;
        // Only an acquired interface is ours to restore. In particular a busy
        // claim must never unbind or reconfigure another application's device.
        handle.set_auto_detach_kernel_driver(true)?;
        handle.claim_interface(0)?;
        let physical = Self {
            handle,
            original_configuration,
            original_kernel_driver,
            configuration: RwLock::new(()),
        };
        let mut report = [0; 27];
        if physical
            .handle
            .read_control(0x81, 6, 0x2200, 0, &mut report, USB_TIMEOUT)?
            != report.len()
        {
            return Err(OpenError::Usb(rusb::Error::Io));
        }
        if report != element::REPORT {
            return Err(OpenError::Unsupported);
        }
        Ok((physical, manifest))
    }

    fn execute(&self, request: &[u8], data: &mut [u8]) -> rusb::Result<usize> {
        let input = word(request, 12) == 1;
        if word(request, 16) == 1 {
            let _configuration = self.configuration.read().unwrap();
            return if input {
                self.handle.read_interrupt(0x81, data, USB_TIMEOUT)
            } else {
                self.handle
                    .write_interrupt(0x01, &request[USBIP_HEADER..], USB_TIMEOUT)
            };
        }
        let setup = &request[40..48];
        let value = u16::from_le_bytes(setup[2..4].try_into().unwrap());
        let index = u16::from_le_bytes(setup[4..6].try_into().unwrap());
        match (setup[0], setup[1]) {
            (0x00, 9) => {
                let _configuration = self.configuration.write().unwrap();
                // usbfs requires releasing the interface for SET_CONFIGURATION.
                // Keep the original kernel driver detached during this short
                // transaction; Drop restores it on every normal/error exit.
                self.handle.set_auto_detach_kernel_driver(false)?;
                let _ = self.handle.release_interface(0);
                let result = if value == 0 {
                    self.handle.unconfigure()
                } else {
                    self.handle.set_active_configuration(value as u8)
                };
                // SET_CONFIGURATION can bind a new local HID interface. Let
                // libusb detach that exact interface again when claiming it.
                self.handle.set_auto_detach_kernel_driver(true)?;
                let claim = if value != 0 || result.is_err() {
                    self.handle.claim_interface(0)
                } else {
                    Ok(())
                };
                result.and(claim).map(|()| 0)
            }
            (0x01, 11) => {
                let _configuration = self.configuration.write().unwrap();
                self.handle
                    .set_alternate_setting(0, value as u8)
                    .map(|()| 0)
            }
            (0x02, 1) => {
                let _configuration = self.configuration.write().unwrap();
                self.handle.clear_halt(index as u8).map(|()| 0)
            }
            _ => {
                let _configuration = self.configuration.read().unwrap();
                if input {
                    self.handle
                        .read_control(setup[0], setup[1], value, index, data, USB_TIMEOUT)
                } else {
                    self.handle.write_control(
                        setup[0],
                        setup[1],
                        value,
                        index,
                        &request[USBIP_HEADER..],
                        USB_TIMEOUT,
                    )
                }
            }
        }
    }
}

#[derive(Debug)]
enum OpenError {
    Usb(rusb::Error),
    Unsupported,
}
impl From<rusb::Error> for OpenError {
    fn from(error: rusb::Error) -> Self {
        Self::Usb(error)
    }
}

// A running libusb call completes or polls for cancellation within USB_TIMEOUT.
// A queued URB can be removed immediately, even behind a permanently idle read.
struct Running {
    sequence: u32,
    unlink: Option<u32>,
}
struct Accounting {
    guard: element::Device,
    queues: [VecDeque<Vec<u8>>; 3],
    running: [Option<Running>; 3],
}
struct DeviceState {
    accounting: Mutex<Accounting>,
    work: [Condvar; 3],
    stopped: AtomicBool,
    shared: Arc<NativeShared>,
    slot: u8,
    generation: u64,
}

fn response(command: u32, sequence: u32, status: i32, size: usize, data: &[u8]) -> Vec<u8> {
    let mut bytes = vec![0; USBIP_HEADER];
    for (offset, value) in [
        (0, command),
        (4, sequence),
        (20, status as u32),
        (24, size as u32),
    ] {
        bytes[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
    }
    bytes.extend_from_slice(data);
    bytes
}
fn usb_status(error: rusb::Error) -> i32 {
    match error {
        rusb::Error::Pipe => -32,
        rusb::Error::Timeout => -110,
        rusb::Error::NoDevice => -19,
        rusb::Error::Overflow => -75,
        rusb::Error::Busy => -16,
        rusb::Error::InvalidParam => -22,
        rusb::Error::Interrupted => -4,
        _ => -5,
    }
}
impl DeviceState {
    fn send_locked(&self, accounting: &mut Accounting, reply: &[u8]) -> Result<()> {
        accounting
            .guard
            .response(reply)
            .map_err(|_| anyhow!("invalid local Tangent response"))?;
        // Keep response order consistent with cancellation accounting. This
        // lock belongs only to one panel; never to desktop input or media.
        self.shared.tangent.send_record(
            &self.shared,
            Kind::Transfer,
            self.slot,
            self.generation,
            reply,
        )
    }
    fn new(
        manifest: element::Manifest,
        shared: Arc<NativeShared>,
        slot: u8,
        generation: u64,
    ) -> Result<Self> {
        Ok(Self {
            accounting: Mutex::new(Accounting {
                guard: element::Device::new(manifest)
                    .map_err(|_| anyhow!("invalid panel manifest"))?,
                queues: Default::default(),
                running: Default::default(),
            }),
            work: Default::default(),
            stopped: AtomicBool::new(false),
            shared,
            slot,
            generation,
        })
    }

    fn stop(&self) {
        let _accounting = self.accounting.lock().unwrap();
        self.stopped.store(true, Ordering::Release);
        for work in &self.work {
            work.notify_one();
        }
    }

    fn request(&self, bytes: &[u8]) -> Result<()> {
        let mut a = self.accounting.lock().unwrap();
        anyhow::ensure!(!self.stopped.load(Ordering::Acquire), "panel stopped");
        a.guard
            .request(bytes)
            .map_err(|_| anyhow!("invalid Tangent request"))?;
        let sequence = word(bytes, 4);
        if word(bytes, 0) == 2 {
            let target = word(bytes, 20);
            for queue in &mut a.queues {
                if let Some(i) = queue.iter().position(|job| word(job, 4) == target) {
                    queue.remove(i);
                    return self.send_locked(&mut a, &response(4, sequence, -104, 0, &[]));
                }
            }
            if let Some(job) = a
                .running
                .iter_mut()
                .flatten()
                .find(|j| j.sequence == target)
            {
                anyhow::ensure!(job.unlink.is_none(), "duplicate USB cancellation");
                job.unlink = Some(sequence);
                return Ok(());
            }
            // The ordinary completion has already been sent.
            return self.send_locked(&mut a, &response(4, sequence, 0, 0, &[]));
        }
        let queue = if word(bytes, 16) == 0 {
            0
        } else if word(bytes, 12) == 1 {
            1
        } else {
            2
        };
        // guard.request bounds the sum of all three queues and their USB payloads.
        a.queues[queue].push_back(bytes.to_vec());
        self.work[queue].notify_one();
        Ok(())
    }

    fn next_job(&self, queue: usize) -> Option<Vec<u8>> {
        let mut a = self.accounting.lock().unwrap();
        loop {
            if self.stopped.load(Ordering::Acquire) {
                return None;
            }
            if let Some(bytes) = a.queues[queue].pop_front() {
                a.running[queue] = Some(Running {
                    sequence: word(&bytes, 4),
                    unlink: None,
                });
                return Some(bytes);
            }
            a = self.work[queue].wait(a).unwrap();
        }
    }

    fn complete(
        &self,
        queue: usize,
        sequence: u32,
        status: i32,
        size: usize,
        data: &[u8],
    ) -> Result<()> {
        let mut a = self.accounting.lock().unwrap();
        let job = a.running[queue]
            .as_ref()
            .ok_or_else(|| anyhow!("missing USB completion"))?;
        anyhow::ensure!(job.sequence == sequence, "stale USB completion");
        let reply = match job.unlink {
            Some(unlink) => response(4, unlink, -104, 0, &[]),
            None => response(3, sequence, status, size, data),
        };
        a.running[queue] = None;
        self.send_locked(&mut a, &reply)
    }

    fn worker(&self, queue: usize, physical: &Physical) {
        while let Some(bytes) = self.next_job(queue) {
            let input = word(&bytes, 12) == 1;
            let mut data = vec![0; word(&bytes, 24) as usize];
            let result = loop {
                if self.stopped.load(Ordering::Acquire) || !self.shared.tangent.alive(&self.shared)
                {
                    return;
                }
                if self.accounting.lock().unwrap().running[queue]
                    .as_ref()
                    .is_some_and(|j| j.unlink.is_some())
                {
                    break Err(rusb::Error::Interrupted);
                }
                match physical.execute(&bytes, &mut data) {
                    Err(rusb::Error::Timeout) if queue == 1 => continue,
                    result => break result,
                }
            };
            let (status, size) = match result {
                Ok(size) => (0, size),
                Err(error) => (usb_status(error), 0),
            };
            if self
                .complete(
                    queue,
                    word(&bytes, 4),
                    status,
                    size,
                    if input { &data[..size] } else { &[] },
                )
                .is_err()
                || status == -19
            {
                self.stop();
                return;
            }
        }
    }
}

struct Exported {
    id: u32,
    state: Arc<DeviceState>,
    workers: Vec<JoinHandle<()>>,
    ready_since: Option<Instant>,
}
impl Exported {
    fn new(
        physical: Physical,
        manifest: element::Manifest,
        shared: Arc<NativeShared>,
        slot: u8,
        generation: u64,
    ) -> Result<Self> {
        let mut device = Self {
            id: manifest.device_id,
            state: Arc::new(DeviceState::new(manifest, shared, slot, generation)?),
            workers: Vec::new(),
            ready_since: None,
        };
        let physical = Arc::new(physical);
        for queue in 0..3 {
            let state = device.state.clone();
            let physical = physical.clone();
            device.workers.push(
                std::thread::Builder::new()
                    .name("plank-panel-usb".into())
                    .spawn(move || state.worker(queue, &physical))?,
            );
        }
        Ok(device)
    }
}
impl Drop for Exported {
    fn drop(&mut self) {
        self.state.stop();
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

#[derive(Default)]
struct Retries(HashMap<u32, Retry>);
enum Retry {
    Unsupported,
    Later { when: Instant, delay: Duration },
}
impl Retries {
    fn eligible(&self, id: u32, now: Instant) -> bool {
        match self.0.get(&id) {
            None => true,
            Some(Retry::Later { when, .. }) => now >= *when,
            Some(Retry::Unsupported) => false,
        }
    }
    // Return true only on the first transient error, for rate-limited logging.
    fn later(&mut self, id: u32, now: Instant) -> bool {
        let delay = match self.0.get(&id) {
            Some(Retry::Later { delay, .. }) => (*delay * 2).min(Duration::from_secs(30)),
            _ => Duration::from_secs(1),
        };
        self.0
            .insert(
                id,
                Retry::Later {
                    when: now + delay,
                    delay,
                },
            )
            .is_none()
    }
}

fn retire(slot: &mut Option<Exported>, shared: &NativeShared) -> Result<()> {
    let device = slot.take().unwrap();
    let (slot_id, generation) = (device.state.slot, device.state.generation);
    // All local workers finish before the generation's ordered Detach barrier.
    drop(device);
    shared
        .tangent
        .send_record(shared, Kind::Detach, slot_id, generation, &[])
}

fn handle_record(
    shared: &NativeShared,
    slots: &mut [Option<Exported>; MAX_DEVICES as usize],
    retries: &mut Retries,
    generation: u64,
    record: Record<'_>,
) -> Result<()> {
    let slot = &mut slots[usize::from(record.slot)];
    let Some(device) = slot.as_mut() else {
        anyhow::ensure!(record.generation <= generation, "unknown panel generation");
        return Ok(());
    }; // late reply after local detach
    if record.generation < device.state.generation {
        return Ok(()); // requests already queued by the previous virtual device
    }
    anyhow::ensure!(
        device.state.generation == record.generation,
        "stale panel generation"
    );
    match record.kind {
        Kind::Ready => {
            anyhow::ensure!(device.ready_since.is_none(), "duplicate panel ready");
            device.ready_since = Some(Instant::now());
        }
        Kind::Transfer => {
            anyhow::ensure!(
                device.ready_since.is_some(),
                "Tangent transfer preceded attachment acknowledgement"
            );
            if let Err(error) = device.state.request(record.body) {
                if retries.later(device.id, Instant::now()) {
                    shared
                        .tangent
                        .report(&format!("Retiring Tangent panel: {error}"));
                }
                retire(slot, shared)?;
            }
        }
        Kind::Failed | Kind::Detach => {
            if record.kind == Kind::Failed && record.body == PROFILE_REJECTED {
                retries.0.insert(device.id, Retry::Unsupported);
                shared
                    .tangent
                    .report("Host does not support this Tangent panel profile");
            } else if retries.later(device.id, Instant::now()) {
                shared
                    .tangent
                    .report("Host released a Tangent panel; retrying attachment");
            }
            retire(slot, shared)?;
        }
        Kind::Attach => return Err(anyhow!("unexpected Host panel announcement")),
    }
    Ok(())
}

pub(super) fn run(shared: Arc<NativeShared>, panels: element::Panels) -> Result<()> {
    let context = Context::new()?;
    let mut slots: [Option<Exported>; MAX_DEVICES as usize] = std::array::from_fn(|_| None);
    let mut retries = Retries::default();
    let mut generation = 0u64;
    let mut scan_failed = false;
    let mut next_scan = Instant::now();
    while shared.tangent.alive(&shared) {
        if Instant::now() >= next_scan && shared.tangent.state.lock().unwrap().status == 2 {
            next_scan = Instant::now() + Duration::from_secs(1);
            let devices = match context.devices() {
                Ok(devices) => {
                    scan_failed = false;
                    devices
                }
                Err(error) => {
                    if !scan_failed {
                        shared.tangent.report(&format!(
                            "Tangent USB enumeration unavailable; retrying: {error}"
                        ));
                    }
                    scan_failed = true;
                    // A failed scan says nothing about already attached panels.
                    continue;
                }
            };
            let mut present = HashSet::new();
            for device in devices.iter() {
                let id = (u32::from(device.bus_number()) << 16) | u32::from(device.address());
                present.insert(id);
                let Ok(desc) = device.device_descriptor() else {
                    continue;
                };
                if !panels.allows(desc.vendor_id(), desc.product_id()) {
                    continue;
                }
                if !retries.eligible(id, Instant::now())
                    || slots.iter().flatten().any(|s| s.id == id)
                {
                    continue;
                }
                let Some(slot) = slots.iter().position(Option::is_none) else {
                    continue; // still inventory owned panels after the ninth device
                };
                let (physical, manifest) = match Physical::open(device, panels) {
                    Ok(opened) => opened,
                    Err(OpenError::Unsupported) => {
                        retries.0.insert(id, Retry::Unsupported);
                        shared
                            .tangent
                            .report("Tangent panel has unsupported USB or HID descriptors");
                        continue;
                    }
                    Err(OpenError::Usb(error)) => {
                        if retries.later(id, Instant::now()) {
                            shared
                                .tangent
                                .report(&format!("Tangent panel unavailable; retrying: {error}"));
                        }
                        continue;
                    }
                };
                generation = generation
                    .checked_add(1)
                    .ok_or_else(|| anyhow!("Tangent generation exhausted"))?;
                let announcement = manifest.encode();
                let exported =
                    match Exported::new(physical, manifest, shared.clone(), slot as u8, generation)
                    {
                        Ok(exported) => exported,
                        Err(error) => {
                            if retries.later(id, Instant::now()) {
                                shared.tangent.report(&format!(
                                    "Tangent panel worker unavailable; retrying: {error}"
                                ));
                            }
                            continue;
                        }
                    };
                shared.tangent.send_record(
                    &shared,
                    Kind::Attach,
                    slot as u8,
                    generation,
                    &announcement,
                )?;
                slots[slot] = Some(exported);
            }
            for slot in &mut slots {
                if let Some(d) = slot
                    && (!present.contains(&d.id) || d.state.stopped.load(Ordering::Acquire))
                {
                    if present.contains(&d.id) {
                        retries.later(d.id, Instant::now());
                    }
                    retire(slot, &shared)?;
                } else if let Some(d) = slot
                    && d.ready_since
                        .is_some_and(|since| since.elapsed() >= Duration::from_secs(30))
                {
                    retries.0.remove(&d.id);
                }
            }
            retries.0.retain(|id, _| present.contains(id));
        }
        let Some(bytes) = shared
            .tangent
            .receive_record_timeout(&shared, Duration::from_millis(100))?
        else {
            continue;
        };
        let record = Record::decode(&bytes).map_err(|_| anyhow!("invalid Tangent record"))?;
        handle_record(&shared, &mut slots, &mut retries, generation, record)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replies_keep_usb_status_and_payload_lengths_distinct() {
        let reply = response(3, 5, 0, 64, &[]); // OUT completion carries no data
        assert_eq!(reply.len(), USBIP_HEADER);
        assert_eq!(word(&reply, 24), 64);
        let cancelled = response(4, 6, -104, 0, &[]);
        assert_eq!(word(&cancelled, 20) as i32, -104);
        assert_eq!(&cancelled[8..20], &[0; 12]);
        assert_eq!(usb_status(rusb::Error::NoDevice), -19);
        assert_eq!(usb_status(rusb::Error::Pipe), -32);
    }

    fn state() -> DeviceState {
        let shared = Arc::new(NativeShared::new(false, 100_000_000));
        shared.set_state(EndpointState::Ready);
        shared.tangent.state.lock().unwrap().status = 2;
        let manifest =
            element::Manifest::new(0x10002, &element::tests::descriptors(), element::REPORT)
                .unwrap();
        DeviceState::new(manifest, shared, 0, 1).unwrap()
    }

    fn pop(state: &DeviceState) -> (u32, u32, i32) {
        let bytes = state
            .shared
            .tangent
            .state
            .lock()
            .unwrap()
            .send
            .pop()
            .unwrap();
        let body = Record::decode(&bytes).unwrap().body;
        (word(body, 0), word(body, 4), word(body, 20) as i32)
    }

    #[test]
    fn queued_idle_reads_cancel_immediately_without_consuming_future_input() {
        use crate::tangent::tests::{submit, unlink};
        let s = state();
        s.request(&submit(1, true, 15)).unwrap();
        let first = s.next_job(1).unwrap();
        // Leave the first read in flight. Reuse a queued sequence often enough
        // to catch queues that accumulate cancelled entries behind the idle URB.
        for _ in 0..256 {
            s.request(&submit(2, true, 15)).unwrap();
            s.request(&unlink(3, 2)).unwrap();
            assert_eq!(pop(&s), (4, 3, -104));
        }
        s.request(&unlink(4, 1)).unwrap();
        assert!(s.shared.tangent.state.lock().unwrap().send.pop().is_none());
        s.complete(1, word(&first, 4), 0, 15, &[1; 15]).unwrap();
        assert_eq!(pop(&s), (4, 4, -104));
        assert!(s.complete(1, 1, 0, 15, &[1; 15]).is_err());
        assert!(s.accounting.lock().unwrap().queues[1].is_empty());
        assert_eq!(
            s.accounting
                .lock()
                .unwrap()
                .guard
                .transactions
                .outstanding(),
            0
        );
    }

    #[test]
    fn a_stopped_usb_worker_releases_only_its_slot_before_retry() {
        use crate::tangent::tests::submit;
        let shared = state().shared;
        let mut slots = std::array::from_fn(|_| None);
        for slot in 0..2u8 {
            let id = 0x10002 + u32::from(slot);
            let manifest =
                element::Manifest::new(id, &element::tests::descriptors(), element::REPORT)
                    .unwrap();
            slots[usize::from(slot)] = Some(Exported {
                id,
                state: Arc::new(DeviceState::new(manifest, shared.clone(), slot, 1).unwrap()),
                workers: vec![],
                ready_since: Some(Instant::now()),
            });
        }
        let mut retries = Retries::default();
        slots[0].as_ref().unwrap().state.stop();
        let mut bytes = submit(1, true, 15);
        let first = Record {
            kind: Kind::Transfer,
            slot: 0,
            generation: 1,
            body: &bytes,
        };
        handle_record(&shared, &mut slots, &mut retries, 1, first).unwrap();
        assert!(slots[0].is_none());
        assert!(!retries.eligible(0x10002, Instant::now()));
        let sent = shared.tangent.state.lock().unwrap().send.pop().unwrap();
        assert_eq!(Record::decode(&sent).unwrap().kind, Kind::Detach);
        handle_record(&shared, &mut slots, &mut retries, 1, first).unwrap(); // stale, no second barrier
        bytes[8..12].copy_from_slice(&0x10003_u32.to_be_bytes());
        handle_record(
            &shared,
            &mut slots,
            &mut retries,
            1,
            Record {
                kind: Kind::Transfer,
                slot: 1,
                generation: 1,
                body: &bytes,
            },
        )
        .unwrap();
        let second = &slots[1].as_ref().unwrap().state;
        assert_eq!(second.next_job(1).unwrap(), bytes);
        second.complete(1, 1, 0, 15, &[0; 15]).unwrap();
        assert_eq!(pop(second), (3, 1, 0));
        assert!(shared.tangent.state.lock().unwrap().send.pop().is_none());
    }

    #[test]
    fn completion_then_late_cancel_keeps_wire_order() {
        use crate::tangent::tests::{submit, unlink};
        let s = state();
        s.request(&submit(7, true, 15)).unwrap();
        s.next_job(1).unwrap();
        s.complete(1, 7, 0, 15, &[0; 15]).unwrap();
        s.request(&unlink(8, 7)).unwrap();
        assert_eq!(pop(&s), (3, 7, 0));
        assert_eq!(pop(&s), (4, 8, 0));
    }

    #[test]
    fn transient_retries_are_bounded_and_unsupported_devices_wait_for_unplug() {
        let now = Instant::now();
        let mut retries = Retries::default();
        for i in 0..10 {
            let t = now + Duration::from_secs(40 * i);
            assert!(retries.eligible(1, t));
            assert_eq!(retries.later(1, t), i == 0);
            assert!(!retries.eligible(1, t));
            assert!(retries.eligible(1, t + Duration::from_secs(30)));
        }
        retries.0.insert(2, Retry::Unsupported);
        assert!(!retries.eligible(2, now + Duration::from_secs(3600)));
        retries.0.retain(|id, _| *id == 1);
        assert!(retries.eligible(2, now));
    }
}
