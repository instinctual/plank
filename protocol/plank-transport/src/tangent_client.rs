// SPDX-License-Identifier: AGPL-3.0-or-later
//! Qualified Tangent libusb exporter. Claims are local to the session process;
//! there is no persistent kernel bus-ID match table or privileged Client daemon.

use super::*;
use crate::tangent::{MAX_DEVICES, USBIP_HEADER, mf, word};
use rusb::{Context, DeviceHandle, UsbContext};
use std::collections::{HashMap, HashSet};
use std::sync::RwLock;
use std::sync::mpsc::{self, SyncSender};
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
    fn open(device: rusb::Device<Context>) -> Result<(Self, mf::Manifest)> {
        let description = device.device_descriptor()?;
        anyhow::ensure!(
            description.vendor_id() == 0x04d8
                && description.product_id() == 0xfa1a
                && device.speed() == rusb::Speed::Full,
            "unqualified Tangent device"
        );
        let handle = device.open()?;
        let mut descriptor = [0; 18];
        anyhow::ensure!(
            handle.read_control(0x80, 6, 0x100, 0, &mut descriptor, USB_TIMEOUT)? == 18,
            "short device descriptor"
        );
        anyhow::ensure!(
            (1..=2).contains(&descriptor[17]),
            "unqualified configuration count"
        );
        let mut descriptors = descriptor.to_vec();
        for index in 0..descriptor[17] {
            let mut configuration = [0; 41];
            anyhow::ensure!(
                handle.read_control(
                    0x80,
                    6,
                    0x200 | u16::from(index),
                    0,
                    &mut configuration,
                    USB_TIMEOUT
                )? == 41,
                "unqualified configuration descriptor"
            );
            descriptors.extend_from_slice(&configuration);
        }
        let device_id = (u32::from(device.bus_number()) << 16) | u32::from(device.address());
        // Check the complete USB shape before detaching its HID interface.
        let manifest = mf::Manifest::new(device_id, &descriptors, mf::REPORT)
            .map_err(|_| anyhow!("unqualified Tangent USB shape"))?;
        let original_configuration = handle.active_configuration()?;
        let original_kernel_driver = handle.kernel_driver_active(0)?;
        let physical = Self {
            handle,
            original_configuration,
            original_kernel_driver,
            configuration: RwLock::new(()),
        };
        if original_kernel_driver {
            physical.handle.detach_kernel_driver(0)?;
        }
        physical.handle.set_auto_detach_kernel_driver(true)?;
        physical.handle.claim_interface(0)?;
        let mut report = [0; 27];
        anyhow::ensure!(
            physical
                .handle
                .read_control(0x81, 6, 0x2200, 0, &mut report, USB_TIMEOUT)?
                == 27
                && report == mf::REPORT,
            "unqualified Tangent HID report"
        );
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

struct Pending {
    cancelled: AtomicBool,
    unlink: Mutex<Option<u32>>,
}
struct Accounting {
    guard: mf::Device,
    pending: HashMap<u32, Arc<Pending>>,
}
struct DeviceState {
    accounting: Mutex<Accounting>,
    stopped: AtomicBool,
    shared: Arc<NativeShared>,
    slot: u8,
    generation: u64,
}
struct Job {
    bytes: Vec<u8>,
    pending: Arc<Pending>,
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
    fn complete(&self, job: &Job, status: i32, size: usize, data: &[u8]) -> Result<()> {
        let mut accounting = self.accounting.lock().unwrap();
        let seq = word(&job.bytes, 4);
        let pending = accounting
            .pending
            .remove(&seq)
            .ok_or_else(|| anyhow!("missing USB completion"))?;
        anyhow::ensure!(Arc::ptr_eq(&pending, &job.pending), "stale USB completion");
        let reply = if let Some(unlink) = *pending.unlink.lock().unwrap() {
            response(4, unlink, -104, 0, &[])
        } else {
            response(3, seq, status, size, data)
        };
        self.send_locked(&mut accounting, &reply)
    }
}

struct Exported {
    id: u32,
    state: Arc<DeviceState>,
    jobs: [SyncSender<Job>; 3], // control, interrupt IN, interrupt OUT
    workers: Vec<JoinHandle<()>>,
    ready: bool,
}
impl Exported {
    fn new(
        physical: Physical,
        manifest: mf::Manifest,
        shared: Arc<NativeShared>,
        slot: u8,
        generation: u64,
    ) -> Result<Self> {
        let id = manifest.device_id;
        let guard = mf::Device::new(manifest).map_err(|_| anyhow!("invalid panel manifest"))?;
        let state = Arc::new(DeviceState {
            accounting: Mutex::new(Accounting {
                guard,
                pending: HashMap::new(),
            }),
            stopped: AtomicBool::new(false),
            shared,
            slot,
            generation,
        });
        let physical = Arc::new(physical);
        let mut senders = Vec::new();
        let mut workers = Vec::new();
        for _ in 0..3 {
            let (tx, rx) = mpsc::sync_channel::<Job>(crate::tangent::MAX_OUTSTANDING);
            senders.push(tx);
            let thread_state = state.clone();
            let physical = physical.clone();
            let worker = std::thread::Builder::new()
                .name("plank-panel-usb".into())
                .spawn(move || {
                    let state = thread_state;
                    while !state.stopped.load(Ordering::Acquire)
                        && state.shared.tangent.alive(&state.shared)
                    {
                        let job = match rx.recv_timeout(USB_TIMEOUT) {
                            Ok(job) => job,
                            Err(mpsc::RecvTimeoutError::Timeout) => continue,
                            Err(_) => break,
                        };
                        let input = word(&job.bytes, 12) == 1;
                        let interrupt_input = input && word(&job.bytes, 16) == 1;
                        let mut data = vec![0; word(&job.bytes, 24) as usize];
                        let result = loop {
                            if state.stopped.load(Ordering::Acquire)
                                || job.pending.cancelled.load(Ordering::Acquire)
                                || !state.shared.tangent.alive(&state.shared)
                            {
                                break Err(rusb::Error::Interrupted);
                            }
                            match physical.execute(&job.bytes, &mut data) {
                                Err(rusb::Error::Timeout) if interrupt_input => continue,
                                result => break result,
                            }
                        };
                        let (status, size) = match result {
                            Ok(size) => (0, size),
                            Err(error) => (usb_status(error), 0),
                        };
                        if state
                            .complete(&job, status, size, if input { &data[..size] } else { &[] })
                            .is_err()
                            || status == -19
                        {
                            state.stopped.store(true, Ordering::Release);
                            break;
                        }
                    }
                });
            match worker {
                Ok(worker) => workers.push(worker),
                Err(error) => {
                    state.stopped.store(true, Ordering::Release);
                    drop(senders);
                    for worker in workers {
                        let _ = worker.join();
                    }
                    return Err(error.into());
                }
            }
        }
        Ok(Self {
            id,
            state,
            jobs: senders.try_into().ok().unwrap(),
            workers,
            ready: false,
        })
    }
    fn request(&self, bytes: &[u8]) -> Result<()> {
        anyhow::ensure!(
            self.ready,
            "Tangent transfer preceded attachment acknowledgement"
        );
        let mut accounting = self.state.accounting.lock().unwrap();
        accounting
            .guard
            .request(bytes)
            .map_err(|_| anyhow!("unqualified Tangent request"))?;
        let sequence = word(bytes, 4);
        if word(bytes, 0) == 2 {
            if let Some(pending) = accounting.pending.get(&word(bytes, 20)) {
                let mut unlink = pending.unlink.lock().unwrap();
                anyhow::ensure!(unlink.is_none(), "duplicate USB cancellation");
                *unlink = Some(sequence);
                pending.cancelled.store(true, Ordering::Release);
                return Ok(());
            }
            return self
                .state
                .send_locked(&mut accounting, &response(4, sequence, 0, 0, &[]));
        }
        let pending = Arc::new(Pending {
            cancelled: AtomicBool::new(false),
            unlink: Mutex::new(None),
        });
        accounting.pending.insert(sequence, pending.clone());
        let queue = if word(bytes, 16) == 0 {
            0
        } else if word(bytes, 12) == 1 {
            1
        } else {
            2
        };
        self.jobs[queue]
            .try_send(Job {
                bytes: bytes.to_vec(),
                pending,
            })
            .map_err(|_| anyhow!("panel transfer queue exhausted"))?;
        Ok(())
    }
}
impl Drop for Exported {
    fn drop(&mut self) {
        self.state.stopped.store(true, Ordering::Release);
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

pub(super) fn run(shared: Arc<NativeShared>) -> Result<()> {
    let context = Context::new()?;
    let mut slots: [Option<Exported>; MAX_DEVICES as usize] = std::array::from_fn(|_| None);
    let mut refused = HashSet::new();
    let mut generation = 0u64;
    let mut next_scan = Instant::now();
    while shared.tangent.alive(&shared) {
        if Instant::now() >= next_scan && shared.tangent.state.lock().unwrap().status == 2 {
            next_scan = Instant::now() + Duration::from_secs(1);
            let devices = context.devices()?;
            let mut present = HashSet::new();
            for device in devices.iter() {
                let Ok(desc) = device.device_descriptor() else {
                    continue;
                };
                if desc.vendor_id() != 0x04d8 || desc.product_id() != 0xfa1a {
                    continue;
                }
                let id = (u32::from(device.bus_number()) << 16) | u32::from(device.address());
                present.insert(id);
                if refused.contains(&id) || slots.iter().flatten().any(|s| s.id == id) {
                    continue;
                }
                let Some(slot) = slots.iter().position(Option::is_none) else {
                    break;
                };
                let (physical, manifest) = match Physical::open(device) {
                    Ok(device) => device,
                    Err(error) => {
                        eprintln!("PLANK Tangent panel unavailable: {error}");
                        refused.insert(id);
                        continue;
                    }
                };
                generation = generation
                    .checked_add(1)
                    .ok_or_else(|| anyhow!("Tangent generation exhausted"))?;
                let announcement = manifest.encode();
                let exported =
                    Exported::new(physical, manifest, shared.clone(), slot as u8, generation)?;
                shared.tangent.send_record(
                    &shared,
                    Kind::Attach,
                    slot as u8,
                    generation,
                    &announcement,
                )?;
                slots[slot] = Some(exported);
            }
            refused.retain(|id| present.contains(id));
            for slot in &mut slots {
                if slot.as_ref().is_some_and(|d| {
                    !present.contains(&d.id) || d.state.stopped.load(Ordering::Acquire)
                }) {
                    let d = slot.take().unwrap();
                    refused.insert(d.id);
                    let slot_id = d.state.slot;
                    let old_generation = d.state.generation;
                    // Join completions before the ordered Detach barrier. No
                    // worker may append an old response after slot retirement.
                    drop(d);
                    shared.tangent.send_record(
                        &shared,
                        Kind::Detach,
                        slot_id,
                        old_generation,
                        &[],
                    )?;
                }
            }
        }
        let Some(bytes) = shared
            .tangent
            .receive_record_timeout(&shared, Duration::from_millis(100))?
        else {
            continue;
        };
        let record = Record::decode(&bytes).map_err(|_| anyhow!("invalid Tangent record"))?;
        let slot = &mut slots[usize::from(record.slot)];
        let Some(device) = slot.as_mut() else {
            anyhow::ensure!(record.generation <= generation, "unknown panel generation");
            continue;
        }; // late reply after local detach
        if record.generation < device.state.generation {
            continue; // requests already queued by the previous virtual device
        }
        anyhow::ensure!(
            device.state.generation == record.generation,
            "stale panel generation"
        );
        match record.kind {
            Kind::Ready => {
                anyhow::ensure!(!device.ready, "duplicate panel ready");
                device.ready = true;
            }
            Kind::Transfer => device.request(record.body)?,
            Kind::Failed | Kind::Detach => {
                refused.insert(device.id);
                *slot = None; // finish old completions before the detach barrier
                shared.tangent.send_record(
                    &shared,
                    Kind::Detach,
                    record.slot,
                    record.generation,
                    &[],
                )?;
            }
            Kind::Attach => return Err(anyhow!("unexpected Host panel announcement")),
        }
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

    fn state_and_job() -> (DeviceState, Job) {
        let shared = Arc::new(NativeShared::new(false, 100_000_000));
        shared.set_state(EndpointState::Ready);
        shared.tangent.state.lock().unwrap().status = 2;
        let manifest = mf::Manifest::new(0x10002, &mf::tests::descriptors(), mf::REPORT).unwrap();
        let mut guard = mf::Device::new(manifest).unwrap();
        let mut bytes = vec![0; USBIP_HEADER];
        for (offset, value) in [(0, 1u32), (4, 7), (8, 0x10002), (12, 1), (16, 1), (24, 15)] {
            bytes[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
        }
        guard.request(&bytes).unwrap();
        let pending = Arc::new(Pending {
            cancelled: AtomicBool::new(false),
            unlink: Mutex::new(None),
        });
        let mut requests = HashMap::new();
        requests.insert(7, pending.clone());
        (
            DeviceState {
                accounting: Mutex::new(Accounting {
                    guard,
                    pending: requests,
                }),
                stopped: AtomicBool::new(false),
                shared,
                slot: 0,
                generation: 1,
            },
            Job { bytes, pending },
        )
    }

    #[test]
    fn completion_then_cancellation_preserves_wire_order() {
        let (state, job) = state_and_job();
        state.complete(&job, 0, 15, &[0; 15]).unwrap();
        let mut cancel = vec![0; USBIP_HEADER];
        for (offset, value) in [(0, 2u32), (4, 8), (8, 0x10002), (20, 7)] {
            cancel[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
        }
        let mut accounting = state.accounting.lock().unwrap();
        accounting.guard.request(&cancel).unwrap();
        state
            .send_locked(&mut accounting, &response(4, 8, 0, 0, &[]))
            .unwrap();
        let mut transport = state.shared.tangent.state.lock().unwrap();
        let first = transport.send.pop().unwrap();
        let second = transport.send.pop().unwrap();
        assert_eq!(word(Record::decode(&first).unwrap().body, 0), 3);
        assert_eq!(word(Record::decode(&second).unwrap().body, 0), 4);
        assert!(transport.send.pop().is_none());
    }

    #[test]
    fn cancellation_replaces_completion_without_replaying_input() {
        let (state, job) = state_and_job();
        let mut cancel = vec![0; USBIP_HEADER];
        for (offset, value) in [(0, 2u32), (4, 8), (8, 0x10002), (20, 7)] {
            cancel[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
        }
        state
            .accounting
            .lock()
            .unwrap()
            .guard
            .request(&cancel)
            .unwrap();
        *job.pending.unlink.lock().unwrap() = Some(8);
        job.pending.cancelled.store(true, Ordering::Release);
        state.complete(&job, 0, 15, &[1; 15]).unwrap();
        let mut transport = state.shared.tangent.state.lock().unwrap();
        let bytes = transport.send.pop().unwrap();
        let record = Record::decode(&bytes).unwrap();
        assert_eq!(record.body.len(), USBIP_HEADER);
        assert_eq!(word(record.body, 0), 4);
        assert_eq!(word(record.body, 4), 8);
        assert_eq!(word(record.body, 20) as i32, -104);
        assert!(transport.send.pop().is_none());
        assert!(state.complete(&job, 0, 15, &[1; 15]).is_err());
    }
}
