// SPDX-License-Identifier: AGPL-3.0-or-later
//! PCAM v2: explicitly negotiated hardware-encoded Mac source, not V4L2 capture.
//! Codec validation and conversion remain platform-adapter responsibilities.
use crate::camera::{DISCONTINUITY, H264, HEADER_BYTES, KEY_FRAME, MAX_FRAME_BYTES};
use anyhow::{Result, ensure};
use bytes::{BufMut, Bytes, BytesMut};

pub const MACOS: u32 = 1;
pub const VIDEOTOOLBOX_HARDWARE: u32 = 1;
pub const NV12: u32 = 1;
// PLANK enums, not V4L2 or H.273 numeric passthrough.
pub const BT709: u8 = 1;
pub const LIMITED_RANGE: u8 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Format {
    pub codec: u32,
    pub width: u16,
    pub height: u16,
    pub platform: u32,
    pub encoder: u32,
    pub source_pixel_format: u32,
    pub primaries: u8,
    pub transfer: u8,
    pub matrix: u8,
    pub range: u8,
    pub nominal_fps: u16,
}
impl Format {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.codec == H264 && (self.width, self.height) == (1280, 720),
            "unsupported encoded camera mode"
        );
        ensure!(
            self.platform == MACOS
                && self.encoder == VIDEOTOOLBOX_HARDWARE
                && self.source_pixel_format == NV12,
            "unsupported encoded camera provenance"
        );
        ensure!(
            self.primaries == BT709
                && self.transfer == BT709
                && self.matrix == BT709
                && self.range == LIMITED_RANGE
                && self.nominal_fps == 30,
            "unsupported encoded camera color/rate"
        );
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet {
    pub format: Format,
    pub flags: u8,
    pub generation: u64,
    pub sequence: u64,
    pub capture_time_us: u64,
    pub payload: Bytes,
}
impl Packet {
    pub fn validate(&self) -> Result<()> {
        self.format.validate()?;
        ensure!(
            self.generation != 0 && self.sequence != u64::MAX,
            "invalid camera activation"
        );
        ensure!(
            self.capture_time_us > 0 && self.capture_time_us <= i64::MAX as u64 / 1000,
            "invalid camera capture time"
        );
        ensure!(
            self.flags & !(KEY_FRAME | DISCONTINUITY) == 0,
            "unsupported camera flags"
        );
        ensure!(
            (1..=MAX_FRAME_BYTES).contains(&self.payload.len()),
            "invalid camera payload size"
        );
        Ok(())
    }
    pub fn encode(&self) -> Result<Bytes> {
        self.validate()?;
        let mut out = BytesMut::with_capacity(HEADER_BYTES + self.payload.len());
        out.extend_from_slice(b"PCAM");
        out.put_u8(2);
        out.put_u8(self.flags);
        out.put_u16(HEADER_BYTES as u16);
        out.put_u64(self.generation);
        out.put_u64(self.sequence);
        out.put_u64(self.capture_time_us);
        out.put_u32(self.format.codec);
        out.put_u16(self.format.width);
        out.put_u16(self.format.height);
        out.put_u32(self.format.platform);
        out.put_u32(self.format.encoder);
        out.put_u32(self.format.source_pixel_format);
        out.put_u8(self.format.primaries);
        out.put_u8(self.format.transfer);
        out.put_u8(self.format.matrix);
        out.put_u8(self.format.range);
        out.put_u16(self.format.nominal_fps);
        out.put_u16(0);
        out.put_u32(0);
        out.extend_from_slice(&self.payload);
        Ok(out.freeze())
    }
    pub fn decode(bytes: Bytes) -> Result<Self> {
        ensure!(
            (HEADER_BYTES + 1..=HEADER_BYTES + MAX_FRAME_BYTES).contains(&bytes.len()),
            "invalid camera record size"
        );
        ensure!(
            &bytes[..4] == b"PCAM"
                && bytes[4] == 2
                && bytes[6..8] == [0, 64]
                && bytes[58..64] == [0; 6],
            "unsupported encoded camera envelope"
        );
        let word = |at| u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap());
        let half = |at| u16::from_be_bytes(bytes[at..at + 2].try_into().unwrap());
        let wide = |at| u64::from_be_bytes(bytes[at..at + 8].try_into().unwrap());
        let packet = Self {
            format: Format {
                codec: word(32),
                width: half(36),
                height: half(38),
                platform: word(40),
                encoder: word(44),
                source_pixel_format: word(48),
                primaries: bytes[52],
                transfer: bytes[53],
                matrix: bytes[54],
                range: bytes[55],
                nominal_fps: half(56),
            },
            flags: bytes[5],
            generation: wide(8),
            sequence: wide(16),
            capture_time_us: wide(24),
            payload: bytes.slice(HEADER_BYTES..),
        };
        packet.validate()?;
        Ok(packet)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn fixture() -> Packet {
        Packet::decode(Bytes::from(
            include_str!("../../../tests/protocol/camera-v2.hex")
                .split_whitespace()
                .map(|b| u8::from_str_radix(b, 16).unwrap())
                .collect::<Vec<_>>(),
        ))
        .unwrap()
    }
    #[test]
    fn shared_vector_and_version_isolation() {
        let packet = fixture();
        let encoded = packet.encode().unwrap();
        assert_eq!(Packet::decode(encoded.clone()).unwrap(), packet);
        assert!(crate::camera::Packet::decode(encoded.clone()).is_err());
        let native = Bytes::from(
            include_str!("../../../tests/protocol/camera-v1.hex")
                .split_whitespace()
                .map(|b| u8::from_str_radix(b, 16).unwrap())
                .collect::<Vec<_>>(),
        );
        assert!(Packet::decode(native).is_err());
        for size in 0..=HEADER_BYTES {
            assert!(Packet::decode(encoded.slice(..size)).is_err());
        }
        for offset in [
            0, 4, 5, 6, 7, 32, 36, 38, 40, 44, 48, 52, 53, 54, 55, 56, 57, 58, 59, 60, 63,
        ] {
            let mut bad = encoded.to_vec();
            bad[offset] ^= 0x80;
            assert!(Packet::decode(Bytes::from(bad)).is_err(), "offset={offset}");
        }
        let mut bad = packet.clone();
        bad.generation = 0;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.sequence = u64::MAX;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.capture_time_us = 0;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.capture_time_us = u64::MAX;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.payload = Bytes::new();
        assert!(bad.encode().is_err());
        bad.payload = Bytes::from(vec![0; MAX_FRAME_BYTES]);
        assert!(bad.encode().is_ok());
        bad.payload = Bytes::from(vec![0; MAX_FRAME_BYTES + 1]);
        assert!(bad.encode().is_err());
    }
}
