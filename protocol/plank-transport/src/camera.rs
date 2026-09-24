// SPDX-License-Identifier: AGPL-3.0-or-later
//! Bounded device-native camera records. No codec conversion lives here.
//! This optional lane requires authenticated capability and capture agreement.
use anyhow::{Context, Result, ensure};
use bytes::{BufMut, Bytes, BytesMut};
use kymux_types::{VideoClientProtocol, VideoServerProtocol};
use kyproto::{Connection, VideoProtocol};
use std::time::Duration;

pub const H264: u32 = u32::from_be_bytes(*b"H264");
pub const MJPEG: u32 = u32::from_be_bytes(*b"MJPG");
pub const LANE_CODEC: u32 = u32::from_be_bytes(*b"CAM1");
pub const HEADER_BYTES: usize = 64;
pub const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;
pub const KEY_FRAME: u8 = 1;
pub const DISCONTINUITY: u8 = 2;

/// Client endpoint allocation is explicit: negotiated microphone first, then
/// camera. A camera-only session uses ID 1; microphone plus camera uses 1/3.
/// Optional recording switches do not change this session's allocation.
pub const fn endpoint_id(microphone_negotiated: bool) -> u16 {
    if microphone_negotiated { 3 } else { 1 }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Format {
    pub codec: u32,
    pub width: u16,
    pub height: u16,
    // Preserve V4L2 metadata as values, not an inferred RGB conversion. The
    // receiving platform must validate its own supported interpretation.
    pub colorspace: u32,
    pub transfer: u32,
    pub ycbcr: u32,
    pub quantization: u32,
}
impl Format {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            matches!(self.codec, H264 | MJPEG),
            "unsupported native camera codec"
        );
        ensure!(
            matches!((self.width, self.height), (1280, 720) | (1920, 1080)),
            "unsupported native camera dimensions"
        );
        ensure!(
            self.colorspace <= 12
                && self.transfer <= 7
                && self.ycbcr <= 8
                && self.quantization <= 2,
            "unsupported camera color metadata"
        );
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet {
    pub format: Format,
    pub flags: u8,
    pub generation: u64,
    /// Strictly increasing frame index for this activation, starting at zero.
    pub sequence: u64,
    /// Actual Client monotonic capture time, in microseconds. The fixed v1
    /// contract is 30 fps; timestamps retain startup gaps and scheduling jitter.
    pub capture_time_us: u64,
    pub driver_sequence: u32,
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
            self.format.codec != MJPEG || self.flags & KEY_FRAME != 0,
            "JPEG camera frame must be independently decodable"
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
        out.put_u8(1);
        out.put_u8(self.flags);
        out.put_u16(HEADER_BYTES as u16);
        out.put_u64(self.generation);
        out.put_u64(self.sequence);
        out.put_u64(self.capture_time_us);
        out.put_u32(self.format.codec);
        out.put_u16(self.format.width);
        out.put_u16(self.format.height);
        out.put_u32(self.format.colorspace);
        out.put_u32(self.format.transfer);
        out.put_u32(self.format.ycbcr);
        out.put_u32(self.format.quantization);
        out.put_u32(self.driver_sequence);
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
                && bytes[4] == 1
                && bytes[6..8] == [0, 64]
                && bytes[60..64] == [0; 4],
            "unsupported camera envelope"
        );
        let word = |at| u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap());
        let wide = |at| u64::from_be_bytes(bytes[at..at + 8].try_into().unwrap());
        let packet = Self {
            format: Format {
                codec: word(32),
                width: u16::from_be_bytes(bytes[36..38].try_into().unwrap()),
                height: u16::from_be_bytes(bytes[38..40].try_into().unwrap()),
                colorspace: word(40),
                transfer: word(44),
                ycbcr: word(48),
                quantization: word(52),
            },
            flags: bytes[5],
            generation: wide(8),
            sequence: wide(16),
            capture_time_us: wide(24),
            driver_sequence: word(56),
            payload: bytes.slice(HEADER_BYTES..),
        };
        packet.validate()?;
        Ok(packet)
    }
}

pub async fn open_source(
    connection: &Connection,
    microphone_negotiated: bool,
    timeout: Duration,
) -> Result<VideoServerProtocol> {
    tokio::time::timeout(timeout, async {
        let (id, endpoint) = connection
            .register_video_endpoint(VideoProtocol::UnreliableFec)
            .await?;
        ensure!(
            id == endpoint_id(microphone_negotiated),
            "unexpected camera endpoint allocation"
        );
        Ok::<_, anyhow::Error>(endpoint.ready().await?)
    })
    .await
    .context("camera source negotiation timed out")?
}

pub async fn open_sink(
    connection: &Connection,
    microphone_negotiated: bool,
    timeout: Duration,
) -> Result<VideoClientProtocol> {
    let endpoint = connection.connect_video_endpoint(
        endpoint_id(microphone_negotiated),
        VideoProtocol::UnreliableFec,
    )?;
    Ok(tokio::time::timeout(timeout, endpoint.ready())
        .await
        .context("camera sink negotiation timed out")??)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fixed_vector_preserves_native_bytes_and_rejects_invalid_metadata() {
        let packet = Packet {
            format: Format {
                codec: H264,
                width: 1280,
                height: 720,
                colorspace: 8,
                transfer: 0,
                ycbcr: 0,
                quantization: 0,
            },
            flags: KEY_FRAME,
            generation: 2,
            sequence: 0,
            capture_time_us: 1_000_000,
            driver_sequence: 0,
            payload: Bytes::from_static(&[0, 0, 0, 1, 0x65, 0x80]),
        };
        let expected: [u8; 70] = include_str!("../../../tests/protocol/camera-v1.hex")
            .split_whitespace()
            .map(|byte| u8::from_str_radix(byte, 16).unwrap())
            .collect::<Vec<_>>()
            .try_into()
            .unwrap();
        assert_eq!(packet.encode().unwrap().as_ref(), &expected);
        assert_eq!(
            Packet::decode(Bytes::copy_from_slice(&expected)).unwrap(),
            packet
        );
        for size in 0..=HEADER_BYTES {
            assert!(Packet::decode(Bytes::copy_from_slice(&expected[..size])).is_err());
        }
        for offset in [0, 4, 6, 7, 32, 36, 38, 40, 44, 48, 52, 60] {
            let mut bad = expected;
            bad[offset] ^= 0x80;
            assert!(
                Packet::decode(Bytes::copy_from_slice(&bad)).is_err(),
                "offset={offset}"
            );
        }
        let mut bad = packet.clone();
        bad.flags = 4;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.generation = 0;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.capture_time_us = u64::MAX;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.capture_time_us = 0;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.sequence = u64::MAX;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.payload = Bytes::new();
        assert!(bad.encode().is_err());
        bad.payload = Bytes::from(vec![0; MAX_FRAME_BYTES]);
        assert_eq!(Packet::decode(bad.encode().unwrap()).unwrap(), bad);
        bad.payload = Bytes::from(vec![0; MAX_FRAME_BYTES + 1]);
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.format.codec = MJPEG;
        bad.flags = 0;
        assert!(bad.encode().is_err());
        bad.flags = KEY_FRAME;
        assert!(bad.encode().is_ok());
        assert_eq!(endpoint_id(false), 1);
        assert_eq!(endpoint_id(true), 3);
    }
}
