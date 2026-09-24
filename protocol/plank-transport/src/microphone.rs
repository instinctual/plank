// SPDX-License-Identifier: AGPL-3.0-or-later
//! Optional reverse audio lane. Callers must
//! negotiate microphone support and bind activation to the authenticated lease.
//! KyProto's server/client audio types mean source/sink, not QUIC server/client.
use anyhow::{Context, Result, bail, ensure};
use bytes::{BufMut, Bytes, BytesMut};
use kymux_types::{AudioClientProtocol, AudioServerProtocol};
use kyproto::{AudioProtocol, Connection};
use std::time::Duration;

// Client-created endpoints have odd IDs. Existing Host-created endpoints are
// even; the reverse direction requires no change to Kyber or another socket.
pub const ENDPOINT_ID: u16 = 1;
pub const SAMPLE_RATE: u32 = 48_000;
pub const FRAME_SAMPLES: u16 = 480;
pub const MAX_OPUS_BYTES: usize = 1275;
pub const HEADER_BYTES: usize = 24;
const MAGIC: &[u8; 4] = b"PMIC";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet {
    /// Nonzero activation generation agreed through authenticated control.
    pub generation: u64,
    /// First 48 kHz sample relative to this activation, not receive wall time.
    pub sample_time: u64,
    pub opus: Bytes,
}
impl Packet {
    fn validate(&self) -> Result<()> {
        ensure!(
            self.generation != 0,
            "zero microphone activation generation"
        );
        ensure!(
            self.sample_time % u64::from(FRAME_SAMPLES) == 0
                && self
                    .sample_time
                    .checked_add(u64::from(FRAME_SAMPLES))
                    .is_some(),
            "invalid microphone sample time"
        );
        ensure!(
            (1..=MAX_OPUS_BYTES).contains(&self.opus.len()),
            "invalid microphone packet size"
        );
        Ok(())
    }
    pub fn encode(&self) -> Result<Bytes> {
        self.validate()?;
        let mut output = BytesMut::with_capacity(HEADER_BYTES + self.opus.len());
        output.extend_from_slice(MAGIC);
        output.put_u8(2); // stereo envelope version
        output.put_u8(2); // stereo
        output.put_u16(FRAME_SAMPLES);
        output.put_u64(self.generation);
        output.put_u64(self.sample_time);
        output.extend_from_slice(&self.opus);
        Ok(output.freeze())
    }
    pub fn decode(bytes: Bytes) -> Result<Self> {
        // Bound the complete record before slicing or allocating anything.
        ensure!(
            (HEADER_BYTES + 1..=HEADER_BYTES + MAX_OPUS_BYTES).contains(&bytes.len()),
            "invalid microphone record length"
        );
        ensure!(
            &bytes[..4] == MAGIC
                && bytes[4] == 2
                && bytes[5] == 2
                && u16::from_be_bytes(bytes[6..8].try_into().unwrap()) == FRAME_SAMPLES,
            "unsupported microphone packet format"
        );
        let packet = Self {
            generation: u64::from_be_bytes(bytes[8..16].try_into().unwrap()),
            sample_time: u64::from_be_bytes(bytes[16..24].try_into().unwrap()),
            opus: bytes.slice(HEADER_BYTES..),
        };
        packet.validate()?;
        Ok(packet)
    }
}

/// Called once, after capability agreement, on the authenticated Client's
/// existing connection. Enclose this future in the session cancellation scope.
pub async fn open_source(
    connection: &Connection,
    timeout: Duration,
) -> Result<AudioServerProtocol> {
    tokio::time::timeout(timeout, async {
        let (id, endpoint) = connection
            .register_audio_endpoint(AudioProtocol::UnreliableFec)
            .await?;
        if id != ENDPOINT_ID {
            bail!("unexpected microphone endpoint allocation");
        }
        Ok::<_, anyhow::Error>(endpoint.ready().await?)
    })
    .await
    .context("microphone source negotiation timed out")?
}

/// The Host is the sink on this lane. No endpoint is opened for a Host which
/// has not advertised support; the existing playback lane remains unchanged.
pub async fn open_sink(connection: &Connection, timeout: Duration) -> Result<AudioClientProtocol> {
    let endpoint = connection.connect_audio_endpoint(ENDPOINT_ID, AudioProtocol::UnreliableFec)?;
    Ok(tokio::time::timeout(timeout, endpoint.ready())
        .await
        .context("microphone sink negotiation timed out")??)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fixed_wire_vector_and_boundaries() {
        let packet = Packet {
            generation: 2,
            sample_time: 480,
            opus: Bytes::from_static(&[0xF4, 0xFF, 0xFE]),
        };
        let expected = [
            b'P', b'M', b'I', b'C', 2, 2, 1, 224, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 1, 224,
            0xF4, 0xFF, 0xFE,
        ];
        assert_eq!(packet.encode().unwrap().as_ref(), &expected);
        assert_eq!(
            Packet::decode(Bytes::copy_from_slice(&expected)).unwrap(),
            packet
        );
        for length in 0..=HEADER_BYTES {
            assert!(Packet::decode(Bytes::copy_from_slice(&expected[..length])).is_err());
        }
        for offset in [0, 4, 5, 6, 7, 23] {
            let mut bad = expected;
            bad[offset] ^= 1;
            assert!(Packet::decode(Bytes::copy_from_slice(&bad)).is_err());
        }
        let mut legacy = expected;
        legacy[4] = 1;
        legacy[5] = 1;
        assert!(Packet::decode(Bytes::copy_from_slice(&legacy)).is_err());
        let mut bad = packet.clone();
        bad.generation = 0;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.sample_time = u64::MAX;
        assert!(bad.encode().is_err());
        bad = packet.clone();
        bad.opus = Bytes::new();
        assert!(bad.encode().is_err());
        bad.opus = Bytes::from(vec![0; MAX_OPUS_BYTES]);
        assert_eq!(Packet::decode(bad.encode().unwrap()).unwrap(), bad);
        bad.opus = Bytes::from(vec![0; MAX_OPUS_BYTES + 1]);
        assert!(bad.encode().is_err());
        assert!(Packet::decode(Bytes::from(vec![0; HEADER_BYTES + MAX_OPUS_BYTES + 1])).is_err());
    }
}
