// SPDX-License-Identifier: AGPL-3.0-or-later
//! Common bounded queue record; each negotiated schema retains its own metadata.
use crate::{camera, camera_encoded};
use anyhow::{Result, bail};
use bytes::Bytes;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Format {
    Native(camera::Format),
    Encoded(camera_encoded::Format),
}
impl Format {
    pub fn codec(self) -> u32 {
        match self {
            Self::Native(f) => f.codec,
            Self::Encoded(f) => f.codec,
        }
    }
    pub fn version(self) -> u32 {
        match self {
            Self::Native(_) => 1,
            Self::Encoded(_) => 2,
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Record {
    pub format: Format,
    pub flags: u8,
    pub generation: u64,
    pub sequence: u64,
    pub capture_time_us: u64,
    pub driver_sequence: Option<u32>,
    pub payload: Bytes,
}
impl From<camera::Packet> for Record {
    fn from(p: camera::Packet) -> Self {
        Self {
            format: Format::Native(p.format),
            flags: p.flags,
            generation: p.generation,
            sequence: p.sequence,
            capture_time_us: p.capture_time_us,
            driver_sequence: Some(p.driver_sequence),
            payload: p.payload,
        }
    }
}
impl From<camera_encoded::Packet> for Record {
    fn from(p: camera_encoded::Packet) -> Self {
        Self {
            format: Format::Encoded(p.format),
            flags: p.flags,
            generation: p.generation,
            sequence: p.sequence,
            capture_time_us: p.capture_time_us,
            driver_sequence: None,
            payload: p.payload,
        }
    }
}
impl Record {
    pub fn decode(bytes: Bytes, version: u32) -> Result<Self> {
        match version {
            1 => Ok(camera::Packet::decode(bytes)?.into()),
            2 => Ok(camera_encoded::Packet::decode(bytes)?.into()),
            _ => bail!("unsupported negotiated camera version"),
        }
    }
    pub fn encode(&self) -> Result<Bytes> {
        match self.format {
            Format::Native(format) => camera::Packet {
                format,
                flags: self.flags,
                generation: self.generation,
                sequence: self.sequence,
                capture_time_us: self.capture_time_us,
                driver_sequence: self
                    .driver_sequence
                    .ok_or_else(|| anyhow::anyhow!("missing native sequence"))?,
                payload: self.payload.clone(),
            }
            .encode(),
            Format::Encoded(format) => camera_encoded::Packet {
                format,
                flags: self.flags,
                generation: self.generation,
                sequence: self.sequence,
                capture_time_us: self.capture_time_us,
                payload: self.payload.clone(),
            }
            .encode(),
        }
    }
}
