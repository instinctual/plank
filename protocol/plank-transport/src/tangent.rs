// SPDX-License-Identifier: AGPL-3.0-or-later
//! Optional Tangent bus records and bounded USB/IP transaction validation.
//!
//! This module does not open devices, register endpoints, or grant USB access.
//! A negotiated session owns the bus; each attachment has a new generation.
//! Kernel USB/IP traffic is not a safe network framing/allocation boundary.

use std::collections::HashMap;

#[path = "tangent_element.rs"]
pub mod element;

pub const VERSION: u8 = 1;
pub const MAX_DEVICES: u8 = 8;
pub const ATTACH_UNAVAILABLE: [u8; 2] = 1u16.to_be_bytes();
pub const DEVICE_IO_FAILED: [u8; 2] = 2u16.to_be_bytes();
pub const PROFILE_REJECTED: [u8; 2] = 3u16.to_be_bytes();
pub const MAX_TRANSFER: usize = 4096;
pub const USBIP_HEADER: usize = 48;
pub const RECORD_HEADER: usize = 16;
pub const MAX_BODY: usize = USBIP_HEADER + MAX_TRANSFER;
pub const MAX_OUTSTANDING: usize = 128;
pub const MAX_OUTSTANDING_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Malformed,
    Unsupported,
    Stale,
    Backpressure,
}
type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    Attach = 1,
    Ready = 2,
    Transfer = 3,
    Detach = 4,
    Failed = 5,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Record<'a> {
    pub kind: Kind,
    pub slot: u8,
    pub generation: u64,
    pub body: &'a [u8],
}

impl<'a> Record<'a> {
    pub fn decode(bytes: &'a [u8]) -> Result<Self> {
        if !(RECORD_HEADER..=RECORD_HEADER + MAX_BODY).contains(&bytes.len())
            || &bytes[..4] != b"PTNG"
            || bytes[4] != VERSION
            || bytes[7] != 0
        {
            return Err(Error::Malformed);
        }
        let kind = match bytes[5] {
            1 => Kind::Attach,
            2 => Kind::Ready,
            3 => Kind::Transfer,
            4 => Kind::Detach,
            5 => Kind::Failed,
            _ => return Err(Error::Unsupported),
        };
        let record = Self {
            kind,
            slot: bytes[6],
            generation: u64::from_be_bytes(bytes[8..16].try_into().unwrap()),
            body: &bytes[RECORD_HEADER..],
        };
        record.validate()?;
        Ok(record)
    }

    fn validate(&self) -> Result<()> {
        if self.slot >= MAX_DEVICES || self.generation == 0 || self.body.len() > MAX_BODY {
            return Err(Error::Malformed);
        }
        let valid = match self.kind {
            Kind::Attach => !self.body.is_empty(),
            Kind::Transfer => self.body.len() >= USBIP_HEADER,
            Kind::Ready | Kind::Detach => self.body.is_empty(),
            // Fixed machine-readable reason, never arbitrary peer log text.
            Kind::Failed => self.body.len() == 2,
        };
        if valid { Ok(()) } else { Err(Error::Malformed) }
    }

    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let mut bytes = Vec::with_capacity(RECORD_HEADER + self.body.len());
        bytes.extend_from_slice(b"PTNG");
        bytes.extend_from_slice(&[VERSION, self.kind as u8, self.slot, 0]);
        bytes.extend_from_slice(&self.generation.to_be_bytes());
        bytes.extend_from_slice(self.body);
        Ok(bytes)
    }
}

/// Tracks negotiated attachment ownership independently of USB sequence numbers.
#[derive(Default)]
pub struct Generations {
    last: [u64; MAX_DEVICES as usize],
    active: [u64; MAX_DEVICES as usize],
}
impl Generations {
    pub fn attach(&mut self, slot: u8, generation: u64) -> Result<()> {
        let slot = usize::from(slot);
        if slot >= self.active.len() || generation == 0 {
            return Err(Error::Malformed);
        }
        if self.active[slot] != 0 || generation <= self.last[slot] {
            return Err(Error::Stale);
        }
        self.last[slot] = generation;
        self.active[slot] = generation;
        Ok(())
    }
    pub fn check(&self, slot: u8, generation: u64) -> Result<()> {
        if generation != 0 && self.active.get(usize::from(slot)) == Some(&generation) {
            Ok(())
        } else {
            Err(Error::Stale)
        }
    }
    pub fn detach(&mut self, slot: u8, generation: u64) -> Result<()> {
        self.check(slot, generation)?;
        self.active[usize::from(slot)] = 0;
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
struct Request {
    input: bool,
    length: usize,
    ticket: u64,
    header: [u8; USBIP_HEADER],
}

#[derive(Clone, Copy, Debug)]
struct Unlink {
    target: u32,
    target_ticket: Option<u64>,
}

/// Per-device USB/IP accounting. A separate qualified descriptor/control policy
/// must approve the actual USB commands and successful descriptor replies.
/// This guard bounds/correlates framing; it does not qualify a device model.
pub struct Transactions {
    device_id: u32,
    requests: HashMap<u32, Request>,
    unlinks: HashMap<u32, Unlink>,
    bytes: usize,
    next_ticket: u64,
}

pub(crate) fn word(bytes: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap())
}
fn signed(bytes: &[u8], offset: usize) -> i32 {
    i32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap())
}
fn header(bytes: &[u8]) -> Result<()> {
    if bytes.len() < USBIP_HEADER {
        Err(Error::Malformed)
    } else {
        Ok(())
    }
}

impl Transactions {
    pub fn new(device_id: u32) -> Result<Self> {
        if device_id == 0 {
            return Err(Error::Malformed);
        }
        Ok(Self {
            device_id,
            requests: HashMap::new(),
            unlinks: HashMap::new(),
            bytes: 0,
            next_ticket: 1,
        })
    }

    /// Validate a complete header *before* allocating/reading a declared body.
    pub fn request_size(&self, bytes: &[u8]) -> Result<usize> {
        header(bytes)?;
        if word(bytes, 8) != self.device_id || word(bytes, 12) > 1 || word(bytes, 16) > 15 {
            return Err(Error::Malformed);
        }
        match word(bytes, 0) {
            1 => {
                let length = signed(bytes, 24);
                // Only control/interrupt records: no isochronous descriptor array.
                if length < 0
                    || length as usize > MAX_TRANSFER
                    || ![0, -1].contains(&signed(bytes, 32))
                {
                    return Err(Error::Unsupported);
                }
                Ok(USBIP_HEADER
                    + if word(bytes, 12) == 0 {
                        length as usize
                    } else {
                        0
                    })
            }
            2 if word(bytes, 12) == 0 && word(bytes, 16) == 0 => Ok(USBIP_HEADER),
            _ => Err(Error::Unsupported),
        }
    }

    pub fn request(&mut self, bytes: &[u8]) -> Result<()> {
        if bytes.len() != self.request_size(bytes)? {
            return Err(Error::Malformed);
        }
        let sequence = word(bytes, 4);
        if self.requests.contains_key(&sequence) || self.unlinks.contains_key(&sequence) {
            return Err(Error::Malformed);
        }
        let length = if word(bytes, 0) == 1 {
            signed(bytes, 24) as usize
        } else {
            0
        };
        if self.requests.len() + self.unlinks.len() >= MAX_OUTSTANDING
            || length > MAX_OUTSTANDING_BYTES - self.bytes
        {
            return Err(Error::Backpressure);
        }
        if word(bytes, 0) == 1 {
            let next = self.next_ticket.checked_add(1).ok_or(Error::Malformed)?;
            self.requests.insert(
                sequence,
                Request {
                    input: word(bytes, 12) == 1,
                    length,
                    ticket: self.next_ticket,
                    header: bytes[..USBIP_HEADER].try_into().unwrap(),
                },
            );
            self.next_ticket = next;
            self.bytes += length;
        } else {
            // Cancellation may race a completion already forwarded locally.
            // Keep a ticket so a late cancellation cannot retire a reused seqnum.
            let target = word(bytes, 20);
            self.unlinks.insert(
                sequence,
                Unlink {
                    target,
                    target_ticket: self.requests.get(&target).map(|r| r.ticket),
                },
            );
        }
        Ok(())
    }

    /// USB/IP replies carry zero direction/device/endpoint fields; body framing
    /// comes from the outstanding request, never from those untrusted fields.
    pub fn response_size(&self, bytes: &[u8]) -> Result<usize> {
        header(bytes)?;
        if word(bytes, 8) != 0
            || word(bytes, 12) != 0
            || word(bytes, 16) != 0
            || !(-4095..=0).contains(&signed(bytes, 20))
        {
            return Err(Error::Malformed);
        }
        let sequence = word(bytes, 4);
        match word(bytes, 0) {
            3 => {
                let request = self.requests.get(&sequence).ok_or(Error::Stale)?;
                let length = signed(bytes, 24);
                if length < 0
                    || length as usize > request.length
                    || ![0, -1].contains(&signed(bytes, 32))
                    || signed(bytes, 36) != 0
                {
                    return Err(Error::Malformed);
                }
                Ok(USBIP_HEADER + if request.input { length as usize } else { 0 })
            }
            4 if self.unlinks.contains_key(&sequence) => Ok(USBIP_HEADER),
            _ => Err(Error::Stale),
        }
    }

    pub fn response(&mut self, bytes: &[u8]) -> Result<()> {
        if bytes.len() != self.response_size(bytes)? {
            return Err(Error::Malformed);
        }
        let sequence = word(bytes, 4);
        if word(bytes, 0) == 3 {
            let retired = self.requests.remove(&sequence).ok_or(Error::Stale)?;
            self.bytes -= retired.length;
        } else {
            let unlink = self.unlinks.remove(&sequence).ok_or(Error::Stale)?;
            // Linux replaces the original completion with RET_UNLINK. Its
            // status is the completed URB status (normally -ECONNRESET), not
            // a zero-only acknowledgement. See stub_complete()/vhci_recv_ret_unlink().
            if unlink.target_ticket.is_some()
                && self.requests.get(&unlink.target).map(|r| r.ticket) == unlink.target_ticket
            {
                self.bytes -= self.requests.remove(&unlink.target).unwrap().length;
            }
        }
        Ok(())
    }

    pub fn contains_sequence(&self, sequence: u32) -> bool {
        self.requests.contains_key(&sequence) || self.unlinks.contains_key(&sequence)
    }

    pub fn cancelling(&self, sequence: u32) -> bool {
        self.requests.get(&sequence).is_some_and(|request| {
            self.unlinks.values().any(|unlink| {
                unlink.target == sequence && unlink.target_ticket == Some(request.ticket)
            })
        })
    }

    /// Each forwarded submit needs space for a future cancellation. A pending
    /// unlink for its current ticket already occupies that space. A late unlink
    /// for an earlier ticket still counts until its own reply arrives.
    pub fn slots_with_cancel_reserve(&self) -> usize {
        let paired = self
            .unlinks
            .values()
            .filter(|u| {
                u.target_ticket.is_some_and(|ticket| {
                    self.requests
                        .get(&u.target)
                        .is_some_and(|request| request.ticket == ticket)
                })
            })
            .count();
        self.outstanding() + self.requests.len() - paired
    }

    pub fn outstanding(&self) -> usize {
        self.requests.len() + self.unlinks.len()
    }
    pub fn outstanding_bytes(&self) -> usize {
        self.bytes
    }

    pub fn request_header(&self, sequence: u32) -> Result<&[u8; USBIP_HEADER]> {
        self.requests
            .get(&sequence)
            .map(|r| &r.header)
            .ok_or(Error::Stale)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    const DEVICE: u32 = 0x10002;
    fn put(bytes: &mut [u8], offset: usize, value: u32) {
        bytes[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
    }
    pub(crate) fn submit(seq: u32, input: bool, length: usize) -> Vec<u8> {
        let mut bytes = vec![0; USBIP_HEADER + if input { 0 } else { length }];
        for (offset, value) in [
            (0, 1),
            (4, seq),
            (8, DEVICE),
            (12, u32::from(input)),
            (16, 1),
            (24, length as u32),
        ] {
            put(&mut bytes, offset, value);
        }
        bytes
    }
    pub(crate) fn reply(seq: u32, length: usize, input: bool) -> Vec<u8> {
        let mut bytes = vec![0; USBIP_HEADER + if input { length } else { 0 }];
        for (offset, value) in [(0, 3), (4, seq), (24, length as u32)] {
            put(&mut bytes, offset, value);
        }
        bytes
    }
    pub(crate) fn unlink(seq: u32, target: u32) -> Vec<u8> {
        let mut bytes = vec![0; USBIP_HEADER];
        for (offset, value) in [(0, 2), (4, seq), (8, DEVICE), (20, target)] {
            put(&mut bytes, offset, value);
        }
        bytes
    }
    pub(crate) fn unlink_reply(seq: u32) -> Vec<u8> {
        let mut bytes = vec![0; USBIP_HEADER];
        put(&mut bytes, 0, 4);
        put(&mut bytes, 4, seq);
        bytes
    }
    #[test]
    fn envelope_vector_and_short_inputs() {
        let record = Record {
            kind: Kind::Ready,
            slot: 2,
            generation: 3,
            body: &[],
        };
        let vector = [b'P', b'T', b'N', b'G', 1, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 3];
        assert_eq!(record.encode().unwrap(), vector);
        assert_eq!(Record::decode(&vector).unwrap(), record);
        for size in 0..RECORD_HEADER {
            assert!(Record::decode(&vector[..size]).is_err());
        }
        for (index, value) in [(0, 0), (4, 2), (5, 0), (6, 8), (7, 1), (15, 0)] {
            let mut bad = vector;
            bad[index] = value;
            assert!(Record::decode(&bad).is_err());
        }
    }
    #[test]
    fn envelopes_bound_before_allocating_and_do_not_carry_peer_log_text() {
        let body = vec![0; MAX_BODY + 1];
        assert!(
            Record {
                kind: Kind::Attach,
                slot: 0,
                generation: 1,
                body: &body
            }
            .encode()
            .is_err()
        );
        for kind in [Kind::Ready, Kind::Detach, Kind::Failed, Kind::Transfer] {
            assert!(
                Record {
                    kind,
                    slot: 0,
                    generation: 1,
                    body: &[1]
                }
                .encode()
                .is_err()
            );
        }
    }
    #[test]
    fn attachments_are_isolated_and_old_generations_cannot_take_over() {
        let mut bus = Generations::default();
        for slot in 0..MAX_DEVICES {
            bus.attach(slot, 1).unwrap();
        }
        assert_eq!(bus.attach(0, 2), Err(Error::Stale));
        bus.detach(0, 1).unwrap();
        bus.attach(0, 2).unwrap();
        assert_eq!(bus.detach(0, 1), Err(Error::Stale));
        bus.check(0, 2).unwrap();
        for slot in 1..MAX_DEVICES {
            bus.check(slot, 1).unwrap();
        }
        bus.detach(0, 2).unwrap();
        assert_eq!(bus.attach(0, 1), Err(Error::Stale));
    }
    #[test]
    fn bounds_are_checked_from_header_before_body_allocation() {
        let g = Transactions::new(DEVICE).unwrap();
        for length in [u32::MAX, 4097, i32::MAX as u32] {
            let mut b = submit(1, true, 0);
            put(&mut b, 24, length);
            assert!(g.request_size(&b).is_err());
        }
        let mut b = submit(1, true, 0);
        put(&mut b, 32, 1);
        assert!(g.request_size(&b).is_err());
        for size in 0..USBIP_HEADER {
            assert!(g.request_size(&b[..size]).is_err());
        }
    }
    #[test]
    fn bidirectional_transfers_use_request_direction_for_framing() {
        let mut g = Transactions::new(DEVICE).unwrap();
        g.request(&submit(1, true, 15)).unwrap();
        g.request(&submit(2, false, 64)).unwrap();
        assert_eq!(
            g.response_size(&reply(1, 15, false)).unwrap(),
            USBIP_HEADER + 15
        );
        assert_eq!(g.response_size(&reply(2, 64, false)).unwrap(), USBIP_HEADER);
        g.response(&reply(2, 64, false)).unwrap();
        g.response(&reply(1, 15, true)).unwrap();
        assert_eq!(g.outstanding(), 0);
        assert_eq!(g.outstanding_bytes(), 0);
    }
    #[test]
    fn unsolicited_oversized_and_duplicate_replies_do_not_retire_requests() {
        let mut g = Transactions::new(DEVICE).unwrap();
        g.request(&submit(1, true, 15)).unwrap();
        assert!(g.response(&reply(2, 15, true)).is_err());
        assert!(g.response(&reply(1, 16, true)).is_err());
        assert!(g.response(&reply(1, 15, false)).is_err());
        assert_eq!(g.outstanding(), 1);
        assert_eq!(g.outstanding_bytes(), 15);
        g.response(&reply(1, 15, true)).unwrap();
        assert!(g.response(&reply(1, 15, true)).is_err());
    }
    #[test]
    fn byte_and_request_pressure_can_resume_after_completions() {
        let mut g = Transactions::new(DEVICE).unwrap();
        for seq in 1..=16 {
            g.request(&submit(seq, true, MAX_TRANSFER)).unwrap();
        }
        assert_eq!(g.request(&submit(17, true, 1)), Err(Error::Backpressure));
        g.response(&reply(1, 0, true)).unwrap();
        g.request(&submit(17, true, MAX_TRANSFER)).unwrap();
        let mut g = Transactions::new(DEVICE).unwrap();
        for seq in 1..=128 {
            g.request(&submit(seq, true, 1)).unwrap();
        }
        assert_eq!(g.request(&submit(129, true, 1)), Err(Error::Backpressure));
        g.response(&reply(1, 1, true)).unwrap();
        g.request(&submit(129, true, 1)).unwrap();
    }
    #[test]
    fn cancellation_and_completion_races_preserve_accounting() {
        let mut g = Transactions::new(DEVICE).unwrap();
        g.request(&submit(1, true, 15)).unwrap();
        g.request(&unlink(2, 1)).unwrap();
        g.response(&unlink_reply(2)).unwrap();
        assert_eq!(g.outstanding(), 0);
        assert_eq!(g.outstanding_bytes(), 0);
        g.request(&submit(3, true, 15)).unwrap();
        g.request(&unlink(4, 3)).unwrap();
        g.response(&reply(3, 15, true)).unwrap();
        g.response(&unlink_reply(4)).unwrap();
        assert_eq!(g.outstanding(), 0);
        assert_eq!(g.outstanding_bytes(), 0);
    }
    #[test]
    fn delayed_cancellation_cannot_remove_a_reused_sequence() {
        let mut g = Transactions::new(DEVICE).unwrap();
        g.request(&submit(1, true, 15)).unwrap();
        g.request(&unlink(2, 1)).unwrap();
        g.response(&reply(1, 15, true)).unwrap();
        g.request(&submit(1, true, 64)).unwrap();
        assert_eq!(g.slots_with_cancel_reserve(), 3);
        g.response(&unlink_reply(2)).unwrap();
        assert_eq!(g.outstanding(), 1);
        assert_eq!(g.outstanding_bytes(), 64);
        assert_eq!(g.slots_with_cancel_reserve(), 2);
        g.response(&reply(1, 64, true)).unwrap();
        assert_eq!(g.outstanding(), 0);
    }
    #[test]
    fn cancellation_may_arrive_after_a_completion() {
        let mut g = Transactions::new(DEVICE).unwrap();
        g.request(&submit(1, true, 15)).unwrap();
        g.response(&reply(1, 15, true)).unwrap();
        g.request(&unlink(2, 1)).unwrap();
        g.request(&submit(1, true, 15)).unwrap();
        g.response(&unlink_reply(2)).unwrap();
        assert_eq!(g.outstanding(), 1);
    }

    #[test]
    fn linux_cancel_status_retires_the_original_urb_and_zero_sequence_is_valid() {
        for status in [0i32, -104, -32, -108] {
            let mut g = Transactions::new(DEVICE).unwrap();
            g.request(&submit(0, true, 15)).unwrap();
            g.request(&unlink(1, 0)).unwrap();
            let mut response = unlink_reply(1);
            put(&mut response, 20, status as u32);
            g.response(&response).unwrap();
            assert_eq!(g.outstanding(), 0);
            assert_eq!(g.outstanding_bytes(), 0);
        }
    }
}
