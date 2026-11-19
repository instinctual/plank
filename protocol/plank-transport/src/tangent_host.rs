// SPDX-License-Identifier: AGPL-3.0-or-later
//! Linux VHCI boundary. Only a qualified panel is attached, and only validated
//! replies reach the kernel. No TCP USB/IP listener or peer-selected sysfs path.

use super::*;
use crate::tangent::{Generations, Kind, MAX_DEVICES, USBIP_HEADER, mf};
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

struct VirtualDevice {
    io: UnixStream,
    guard: Arc<Mutex<mf::Device>>,
    stop: Arc<AtomicBool>,
    reader: Option<JoinHandle<()>>,
}

impl VirtualDevice {
    fn attach(manifest: mf::Manifest) -> Result<Self> {
        let id = manifest.device_id;
        let guard = mf::Device::new(manifest).map_err(|_| anyhow!("invalid Tangent manifest"))?;
        let (io, kernel) = UnixStream::pair()?;
        io.set_read_timeout(Some(IO_WAIT))?;
        io.set_write_timeout(Some(Duration::from_secs(1)))?;
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
        Ok(Self {
            io,
            guard: Arc::new(Mutex::new(guard)),
            stop: Arc::new(AtomicBool::new(false)),
            reader: None,
        })
    }

    fn start(&mut self, shared: Arc<NativeShared>, slot: u8, generation: u64) -> Result<()> {
        let mut io = self.io.try_clone()?;
        let guard = self.guard.clone();
        let stop = self.stop.clone();
        self.reader = Some(
            std::thread::Builder::new()
                .name("plank-panel-vhci".into())
                .spawn(move || {
                    let result = (|| -> Result<()> {
                        loop {
                            let mut header = [0; USBIP_HEADER];
                            read_exact(&mut io, &mut header, &shared, &stop)?;
                            let size = guard
                                .lock()
                                .unwrap()
                                .request_size(&header)
                                .map_err(|_| anyhow!("unqualified Tangent USB request"))?;
                            let mut bytes = Vec::with_capacity(size);
                            bytes.extend_from_slice(&header);
                            bytes.resize(size, 0);
                            read_exact(&mut io, &mut bytes[USBIP_HEADER..], &shared, &stop)?;
                            guard
                                .lock()
                                .unwrap()
                                .request(&bytes)
                                .map_err(|_| anyhow!("invalid Tangent USB transaction"))?;
                            shared.tangent.send_record(
                                &shared,
                                Kind::Transfer,
                                slot,
                                generation,
                                &bytes,
                            )?;
                        }
                    })();
                    if result.is_err() && !stop.load(Ordering::Acquire) {
                        let _ = shared.tangent.send_record(
                            &shared,
                            Kind::Failed,
                            slot,
                            generation,
                            &[0, 2],
                        );
                    }
                    stop.store(true, Ordering::Release);
                    let _ = io.shutdown(Shutdown::Both);
                })?,
        );
        Ok(())
    }

    fn respond(&mut self, bytes: &[u8]) -> Result<()> {
        self.guard
            .lock()
            .unwrap()
            .response(bytes)
            .map_err(|_| anyhow!("invalid Tangent USB response"))?;
        self.io.write_all(bytes)?;
        Ok(())
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
) -> Result<()> {
    let mut offset = 0;
    let mut partial_since = None;
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

pub(super) fn run(shared: Arc<NativeShared>) -> Result<()> {
    let mut generations = Generations::default();
    let mut devices: [Option<VirtualDevice>; MAX_DEVICES as usize] = std::array::from_fn(|_| None);
    while let Some(bytes) = shared.tangent.receive_record(&shared)? {
        let record = Record::decode(&bytes).map_err(|_| anyhow!("invalid Tangent record"))?;
        let slot = usize::from(record.slot);
        match record.kind {
            Kind::Attach => {
                generations
                    .attach(record.slot, record.generation)
                    .map_err(|_| anyhow!("stale Tangent attachment"))?;
                let manifest = mf::Manifest::decode(record.body)
                    .map_err(|_| anyhow!("unqualified Tangent panel"))?;
                match VirtualDevice::attach(manifest) {
                    Ok(mut device) => {
                        shared.tangent.send_record(
                            &shared,
                            Kind::Ready,
                            record.slot,
                            record.generation,
                            &[],
                        )?;
                        device.start(shared.clone(), record.slot, record.generation)?;
                        devices[slot] = Some(device);
                    }
                    Err(_) => {
                        shared.tangent.send_record(
                            &shared,
                            Kind::Failed,
                            record.slot,
                            record.generation,
                            &[0, 1],
                        )?;
                        // Keep its generation until peer acknowledges detach.
                    }
                }
            }
            Kind::Transfer => {
                generations
                    .check(record.slot, record.generation)
                    .map_err(|_| anyhow!("stale Tangent response"))?;
                if let Some(device) = devices[slot].as_mut()
                    && !device.stop.load(Ordering::Acquire)
                {
                    device.respond(record.body)?;
                }
                // A device failure can race already-sent, ordered responses.
                // Ignore these until the peer's matching Detach barrier.
            }
            Kind::Detach | Kind::Failed => {
                generations
                    .detach(record.slot, record.generation)
                    .map_err(|_| anyhow!("stale Tangent detach"))?;
                devices[slot] = None;
            }
            Kind::Ready => return Err(anyhow!("unexpected Tangent client acknowledgement")),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_unused_usb2_ports_are_candidates() {
        let status = "hub port sta spd dev sockfd local_busid\nhs 0000 004 000 00000000 0 0-0\nhs 0001 006 002 00010002 5 9-1\nss 0002 004 000 00000000 0 0-0\nhs 9999 004 000 00000000 0 0-0\n";
        assert_eq!(free_ports(status), vec![0]);
        assert!(free_ports("not a status file").is_empty());
    }
}
