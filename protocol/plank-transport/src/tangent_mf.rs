// SPDX-License-Identifier: AGPL-3.0-or-later
//! Initial qualified Element Mf USB shape. Control meanings remain in TangentHub.
//! Additional panel models need their own descriptor/transfer qualification.

use super::{Error, MAX_TRANSFER, Result, Transactions, USBIP_HEADER, word};

pub const REPORT: &[u8] = &[
    0x05, 0x01, 0x09, 0x08, 0xa1, 0x01, 0x05, 0xf0, 0x09, 0x01, 0x75, 0x08, 0x95, 0x0f, 0x81, 0x02,
    0x05, 0xf0, 0x09, 0x02, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02, 0xc0,
];
const MAX_DESCRIPTORS: usize = 1024;
const MANIFEST_HEADER: usize = 12;

#[derive(Clone, Debug)]
pub struct Manifest {
    pub device_id: u32,
    descriptors: Vec<u8>,
    configurations: Vec<std::ops::Range<usize>>,
}

fn short(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap())
}

impl Manifest {
    pub fn new(device_id: u32, descriptors: &[u8], report: &[u8]) -> Result<Self> {
        if device_id >> 16 == 0
            || !(1..=127).contains(&(device_id & 0xffff))
            || !(18..=MAX_DESCRIPTORS).contains(&descriptors.len())
            || report != REPORT
        {
            return Err(Error::Unsupported);
        }
        let d = descriptors;
        if d[0] != 18
            || d[1] != 1
            || d[4..7] != [0, 0, 0]
            || ![8, 16, 32, 64].contains(&d[7])
            || short(d, 8) != 0x04d8
            || short(d, 10) != 0xfa1a
            || !(1..=2).contains(&d[17])
        {
            return Err(Error::Unsupported);
        }
        let mut configurations = Vec::new();
        let mut offset = 18;
        let mut values = Vec::new();
        for _ in 0..d[17] {
            if d.len() - offset < 9 {
                return Err(Error::Malformed);
            }
            let c = &d[offset..];
            let total = usize::from(short(c, 2));
            if c[0] != 9
                || c[1] != 2
                || total != 41
                || total > c.len()
                || c[4] != 1
                || usize::from(c[5]) != configurations.len() + 1
                || values.contains(&c[5])
                || c[7] & 0x80 == 0
                || c[7] & 0x1f != 0
            {
                return Err(Error::Unsupported);
            }
            let interface = &c[9..18];
            if interface[..8] != [9, 4, 0, 0, 2, 3, 0, 0] {
                return Err(Error::Unsupported);
            }
            let hid = &c[18..27];
            if hid[0] != 9
                || hid[1] != 0x21
                || hid[5] != 1
                || hid[6] != 0x22
                || usize::from(short(hid, 7)) != REPORT.len()
            {
                return Err(Error::Unsupported);
            }
            let mut input = false;
            let mut output = false;
            for ep in [&c[27..34], &c[34..41]] {
                if ep[0] != 7 || ep[1] != 5 || ep[3] != 3 || ep[6] == 0 {
                    return Err(Error::Unsupported);
                }
                match (ep[2], short(ep, 4)) {
                    (0x81, 15) if !input => input = true,
                    (0x01, 64) if !output => output = true,
                    _ => return Err(Error::Unsupported),
                }
            }
            values.push(c[5]);
            configurations.push(offset..offset + total);
            offset += total;
        }
        if offset != d.len() {
            return Err(Error::Malformed);
        }
        Ok(Self {
            device_id,
            descriptors: d.to_vec(),
            configurations,
        })
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if !(MANIFEST_HEADER + 18..=MANIFEST_HEADER + MAX_DESCRIPTORS + REPORT.len())
            .contains(&bytes.len())
            || bytes[4..8] != [0, 2, 0, 0]
        // full speed, reserved=0
        {
            return Err(Error::Malformed);
        }
        let size = usize::from(u16::from_be_bytes(bytes[8..10].try_into().unwrap()));
        let report_size = usize::from(u16::from_be_bytes(bytes[10..12].try_into().unwrap()));
        if size > MAX_DESCRIPTORS
            || report_size != REPORT.len()
            || bytes.len() != MANIFEST_HEADER + size + report_size
        {
            return Err(Error::Malformed);
        }
        Self::new(
            word(bytes, 0),
            &bytes[MANIFEST_HEADER..MANIFEST_HEADER + size],
            &bytes[MANIFEST_HEADER + size..],
        )
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut b = Vec::with_capacity(MANIFEST_HEADER + self.descriptors.len() + REPORT.len());
        b.extend_from_slice(&self.device_id.to_be_bytes());
        b.extend_from_slice(&[0, 2, 0, 0]);
        b.extend_from_slice(&(self.descriptors.len() as u16).to_be_bytes());
        b.extend_from_slice(&(REPORT.len() as u16).to_be_bytes());
        b.extend_from_slice(&self.descriptors);
        b.extend_from_slice(REPORT);
        b
    }

    pub fn check_request(&self, request: &[u8]) -> Result<()> {
        if request.len() < USBIP_HEADER {
            return Err(Error::Malformed);
        }
        if word(request, 0) == 2 {
            return Ok(());
        } // cancellation; transaction guard validates it
        let direction = word(request, 12);
        let endpoint = word(request, 16);
        let length = word(request, 24) as usize;
        if endpoint == 1 {
            return if (direction == 1 && (1..=MAX_TRANSFER).contains(&length))
                || (direction == 0 && length <= 64)
            {
                Ok(())
            } else {
                Err(Error::Unsupported)
            };
        }
        if endpoint != 0 {
            return Err(Error::Unsupported);
        }
        let s = &request[40..48];
        let kind = s[0];
        let command = s[1];
        let value = short(s, 2);
        let index = short(s, 4);
        if usize::from(short(s, 6)) != length || u32::from(kind >> 7) != direction {
            return Err(Error::Malformed);
        }
        let allowed = match (kind, command) {
            // Status getters. USB test mode, arbitrary feature setters and
            // SET_ADDRESS/SET_DESCRIPTOR never reach the physical device.
            (0x80, 0) => value == 0 && index == 0 && length == 2,
            (0x81, 0) => value == 0 && index == 0 && length == 2,
            (0x82, 0) => value == 0 && [0, 1, 0x81].contains(&index) && length == 2,
            (0x02, 1) => value == 0 && [1, 0x81].contains(&index) && length == 0,
            (0x80, 6) | (0x81, 6) => {
                length <= MAX_TRANSFER
                    && match value >> 8 {
                        1 | 6 | 15 => kind == 0x80 && value & 0xff == 0 && index == 0,
                        2 | 7 => {
                            kind == 0x80
                                && index == 0
                                && usize::from(value & 0xff) < self.configurations.len()
                        }
                        3 => kind == 0x80 && length <= 255,
                        0x21 | 0x22 => kind == 0x81 && value & 0xff == 0 && index == 0,
                        _ => false,
                    }
            }
            (0x80, 8) => value == 0 && index == 0 && length == 1,
            (0x00, 9) => {
                index == 0
                    && length == 0
                    && (value == 0
                        || self
                            .configurations
                            .iter()
                            .any(|c| u16::from(self.descriptors[c.start + 5]) == value))
            }
            (0x81, 10) => value == 0 && index == 0 && length == 1,
            (0x01, 11) => value == 0 && index == 0 && length == 0,
            // The qualified descriptor has input/output reports, no feature
            // reports. Vendor diagnostics and firmware programming are denied.
            (0xa1, 1) => {
                index == 0 && value & 0xff == 0 && [1, 2].contains(&(value >> 8)) && length <= 64
            }
            (0x21, 9) => index == 0 && value == 0x0200 && length <= 64,
            (0xa1, 2) | (0xa1, 3) => index == 0 && value == 0 && length == 1,
            (0x21, 10) => index == 0 && value & 0xff == 0 && length == 0,
            (0x21, 11) => index == 0 && value <= 1 && length == 0,
            _ => false,
        };
        if allowed {
            Ok(())
        } else {
            Err(Error::Unsupported)
        }
    }

    /// Match successful enumeration replies against the qualified manifest.
    /// A peer cannot announce a panel and later enumerate a keyboard/storage
    /// interface. The transaction guard must first verify all sizes/status.
    pub fn check_response(&self, request: &[u8], response: &[u8]) -> Result<()> {
        if request.len() < USBIP_HEADER || response.len() < USBIP_HEADER {
            return Err(Error::Malformed);
        }
        self.check_request(request)?;
        if word(response, 0) != 3 || word(response, 20) != 0 || word(request, 12) != 1 {
            return Ok(());
        }
        let data = &response[USBIP_HEADER..];
        if word(request, 16) == 1 {
            return if data.len() == 15 {
                Ok(())
            } else {
                Err(Error::Malformed)
            };
        }
        let setup = &request[40..48];
        if setup[1] != 6 || setup[0] & 0x60 != 0 {
            return Ok(());
        }
        let value = short(setup, 2);
        let expected = match value >> 8 {
            1 => &self.descriptors[..18],
            2 => &self.descriptors[self.configurations[usize::from(value & 0xff)].clone()],
            0x21 => {
                let start = self.configurations[0].start + 18;
                &self.descriptors[start..start + 9]
            }
            0x22 => REPORT,
            3 => {
                let requested = usize::from(short(setup, 6));
                if requested == 0 && data.is_empty() {
                    return Ok(());
                }
                // Descriptor-header reads may deliberately request only one
                // or two bytes; bLength still describes the complete string.
                if data.is_empty()
                    || data[0] < 2
                    || !data[0].is_multiple_of(2)
                    || data.len() != usize::min(usize::from(data[0]), requested)
                    || (data.len() >= 2 && data[1] != 3)
                {
                    return Err(Error::Malformed);
                }
                return Ok(());
            }
            // These full-speed devices may STALL unsupported qualifier/BOS/
            // other-speed requests; successful unqualified variants are denied.
            _ => return Err(Error::Unsupported),
        };
        let count = usize::min(expected.len(), usize::from(short(setup, 6)));
        if data == &expected[..count] {
            Ok(())
        } else {
            Err(Error::Malformed)
        }
    }
}

/// The device boundary composes model qualification with transaction framing.
/// Callers use these methods before bytes reach either kernel endpoint.
pub struct Device {
    pub manifest: Manifest,
    transactions: Transactions,
}
impl Device {
    pub fn new(manifest: Manifest) -> Result<Self> {
        let transactions = Transactions::new(manifest.device_id)?;
        Ok(Self {
            manifest,
            transactions,
        })
    }
    pub fn request_size(&self, header: &[u8]) -> Result<usize> {
        let size = self.transactions.request_size(header)?;
        self.manifest.check_request(header)?;
        Ok(size)
    }
    pub fn request(&mut self, bytes: &[u8]) -> Result<()> {
        self.manifest.check_request(bytes)?;
        self.transactions.request(bytes)
    }
    pub fn response_size(&self, header: &[u8]) -> Result<usize> {
        self.transactions.response_size(header)
    }
    pub fn response(&mut self, bytes: &[u8]) -> Result<()> {
        if bytes.len() != self.transactions.response_size(bytes)? {
            return Err(Error::Malformed);
        }
        if word(bytes, 0) == 3 {
            let request = self.transactions.request_header(word(bytes, 4))?;
            self.manifest.check_response(request, bytes)?;
        }
        self.transactions.response(bytes)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn descriptors() -> Vec<u8> {
        let mut d = vec![
            18, 1, 0, 2, 0, 0, 0, 8, 0xd8, 4, 0x1a, 0xfa, 0x20, 1, 1, 2, 3, 2,
        ];
        for (value, power) in [(1, 250), (2, 50)] {
            d.extend_from_slice(&[
                9, 2, 41, 0, 1, value, 0, 0x80, power, 9, 4, 0, 0, 2, 3, 0, 0, 0, 9, 0x21, 0x11, 1,
                0, 1, 0x22, 27, 0, 7, 5, 0x81, 3, 15, 0, 20, 7, 5, 1, 3, 64, 0, 16,
            ]);
        }
        d
    }
    fn control(kind: u8, command: u8, value: u16, length: u16) -> Vec<u8> {
        let mut b = vec![0; 48];
        b[..4].copy_from_slice(&1u32.to_be_bytes());
        b[12..16].copy_from_slice(&u32::from(kind >> 7).to_be_bytes());
        b[24..28].copy_from_slice(&u32::from(length).to_be_bytes());
        b[40] = kind;
        b[41] = command;
        b[42..44].copy_from_slice(&value.to_le_bytes());
        b[46..48].copy_from_slice(&length.to_le_bytes());
        b
    }
    #[test]
    fn manifest_roundtrip_and_descriptor_mutations() {
        let m = Manifest::new(0x10002, &descriptors(), REPORT).unwrap();
        assert_eq!(Manifest::decode(&m.encode()).unwrap().encode(), m.encode());
        for offset in [
            0, 1, 4, 7, 8, 10, 17, 18, 20, 22, 23, 27, 31, 32, 36, 41, 43, 47, 49, 50, 54, 56,
        ] {
            let mut d = descriptors();
            d[offset] ^= 0x80;
            assert!(
                Manifest::new(0x10002, &d, REPORT).is_err(),
                "accepted mutation at {offset}"
            );
        }
        for size in 0..descriptors().len() {
            assert!(Manifest::new(0x10002, &descriptors()[..size], REPORT).is_err());
        }
        let mut report = REPORT.to_vec();
        report[6] = 1;
        assert!(Manifest::new(0x10002, &descriptors(), &report).is_err());
    }
    #[test]
    fn bootloader_test_mode_feature_reports_and_foreign_endpoints_are_denied() {
        let m = Manifest::new(0x10002, &descriptors(), REPORT).unwrap();
        for b in [
            control(0x40, 0x54, 0x424c, 0),
            control(0x00, 3, 2, 0),
            control(0x00, 5, 12, 0),
            control(0x00, 7, 0x100, 18),
            control(0x21, 9, 0x300, 64),
        ] {
            assert!(m.check_request(&b).is_err());
        }
        let mut b = control(0x80, 6, 0x100, 18);
        b[19] = 2;
        assert!(m.check_request(&b).is_err());
        for b in [
            control(0x80, 6, 0x100, 18),
            control(0x80, 6, 0x200, 9),
            control(0x81, 6, 0x2200, 27),
            control(0x21, 10, 0, 0),
            control(0x21, 9, 0x200, 64),
        ] {
            m.check_request(&b).unwrap();
        }
    }
    #[test]
    fn enumeration_cannot_switch_device_shape_after_announcement() {
        let m = Manifest::new(0x10002, &descriptors(), REPORT).unwrap();
        for length in [8, 18, 64] {
            let req = control(0x80, 6, 0x100, length);
            let mut reply = vec![0; 48];
            reply[..4].copy_from_slice(&3u32.to_be_bytes());
            reply.extend_from_slice(&descriptors()[..usize::min(18, length.into())]);
            m.check_response(&req, &reply).unwrap();
            reply[52] = 3;
            assert!(m.check_response(&req, &reply).is_err());
        }
    }

    #[test]
    fn real_hub_setup_sequence_is_qualified_without_vendor_access() {
        let manifest = Manifest::new(0x10002, &descriptors(), REPORT).unwrap();
        // Header-only observation; no serial strings or input report payloads.
        for setup in [
            "8006000100004000",
            "8006000100001200",
            "8006000600000a00",
            "8006000200000900",
            "8006000200002900",
            "8006010200000900",
            "8006010200002900",
            "800600030000ff00",
            "800602030904ff00",
            "800601030904ff00",
            "800603030904ff00",
            "0009010000000000",
            "210a000000000000",
            "8106002200001b00",
            "8006000300000400",
        ] {
            let setup = hex::decode(setup).unwrap();
            let mut request = control(setup[0], setup[1], short(&setup, 2), short(&setup, 6));
            request[40..48].copy_from_slice(&setup);
            manifest.check_request(&request).unwrap();
        }
    }

    #[test]
    fn string_descriptor_prefixes_and_invalid_replies() {
        let manifest = Manifest::new(0x10002, &descriptors(), REPORT).unwrap();
        for size in [0, 1, 2, 4, 255] {
            let request = control(0x80, 6, 0x300, size);
            let descriptor = [4, 3, 9, 4];
            let mut response = vec![0; USBIP_HEADER];
            response[..4].copy_from_slice(&3u32.to_be_bytes());
            response.extend_from_slice(&descriptor[..usize::min(size.into(), descriptor.len())]);
            manifest.check_response(&request, &response).unwrap();
            if size > 0 {
                response[USBIP_HEADER] = 255;
                assert!(manifest.check_response(&request, &response).is_err());
            }
        }
    }
}
