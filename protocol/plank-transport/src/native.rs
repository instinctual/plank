// SPDX-License-Identifier: AGPL-3.0-or-later

//! Thin PLANK ownership boundary around Kyber's native KyProto API.
//!
//! KyProto intentionally remains responsible for endpoint routing, media
//! packetization, RaptorQ, ordering, transport, and protocol statistics.  This
//! module only binds the PLANK session token and the fixed endpoint
//! manifest negotiated by matching experimental Host and Client builds.

use anyhow::{Context, Result, anyhow, bail};
use kymux_types::{AudioClientProtocol, AudioServerProtocol, DataProtocol, InputProtocol};
use kymux_types::{VideoClientProtocol, VideoServerProtocol};
use kynet::Server;
use kyproto::{AudioProtocol, ClientAuth, Connection, VideoProtocol};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use subtle::ConstantTimeEq;

pub const VIDEO_ENDPOINT_ID: u16 = 0;
pub const AUDIO_ENDPOINT_ID: u16 = 2;
pub const INPUT_ENDPOINT_ID: u16 = 4;
pub const DATA_ENDPOINT_ID: u16 = 6;
pub const SETUP_DATA_ENDPOINT_ID: u16 = 0;
pub const SETUP_VIDEO_ENDPOINT_ID: u16 = 2;
pub const SETUP_AUDIO_ENDPOINT_ID: u16 = 4;
pub const SETUP_INPUT_ENDPOINT_ID: u16 = 6;

#[cfg(test)]
#[path = "native_version_tests.rs"]
mod version_tests;

#[derive(Clone, Copy)]
pub struct NativeOptions {
    pub handshake_timeout: Duration,
    pub idle_timeout: Duration,
    pub keep_alive_interval: Duration,
    pub max_udp_payload_size: Option<u16>,
}

pub struct NativeServerProtocols {
    connection: Connection,
    pub video: VideoServerProtocol,
    pub audio: AudioServerProtocol,
    pub input: InputProtocol,
    pub data: DataProtocol,
}

pub struct NativeClientProtocols {
    connection: Connection,
    pub peer_certificate_der: Vec<u8>,
    pub video: VideoClientProtocol,
    pub audio: AudioClientProtocol,
    pub input: InputProtocol,
    pub data: DataProtocol,
}

pub struct NativeSetupServerProtocols {
    connection: Connection,
    pub data: DataProtocol,
}

pub struct NativeSetupClientProtocols {
    connection: Connection,
    pub peer_certificate_der: Vec<u8>,
    pub data: DataProtocol,
}

impl NativeSetupServerProtocols {
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub(crate) fn into_parts(self) -> (Connection, DataProtocol) {
        (self.connection, self.data)
    }
}

impl NativeSetupClientProtocols {
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub(crate) fn into_parts(self) -> (Connection, DataProtocol, Vec<u8>) {
        (self.connection, self.data, self.peer_certificate_der)
    }
}

impl NativeServerProtocols {
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub(crate) fn into_parts(
        self,
    ) -> (
        Connection,
        VideoServerProtocol,
        AudioServerProtocol,
        InputProtocol,
        DataProtocol,
    ) {
        (
            self.connection,
            self.video,
            self.audio,
            self.input,
            self.data,
        )
    }
}

#[derive(Debug)]
struct RecordingCertificateVerifier {
    expected_sha256: Option<Vec<u8>>,
    peer_certificate_der: Arc<Mutex<Option<Vec<u8>>>>,
}

impl rustls::client::danger::ServerCertVerifier for RecordingCertificateVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        let der = end_entity.as_ref();
        if let Some(expected) = &self.expected_sha256 {
            let actual = ring::digest::digest(&ring::digest::SHA256, der);
            if actual.as_ref().ct_eq(expected).unwrap_u8() != 1 {
                return Err(rustls::Error::General(
                    "PLANK certificate fingerprint mismatch".to_owned(),
                ));
            }
        }
        *self.peer_certificate_der.lock().unwrap() = Some(der.to_vec());
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

impl NativeClientProtocols {
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub(crate) fn into_parts(
        self,
    ) -> (
        Connection,
        VideoClientProtocol,
        AudioClientProtocol,
        InputProtocol,
        DataProtocol,
        Vec<u8>,
    ) {
        (
            self.connection,
            self.video,
            self.audio,
            self.input,
            self.data,
            self.peer_certificate_der,
        )
    }
}

fn verify_endpoint_id(actual: u16, expected: u16, name: &str) -> Result<()> {
    if actual != expected {
        bail!("KyProto allocated {name} endpoint {actual}, expected {expected}");
    }
    Ok(())
}

async fn connect_raw_client(
    remote_address: SocketAddr,
    server_name: &str,
    certificate_sha256: Option<&str>,
    options: NativeOptions,
) -> Result<(kynet::Connection, Vec<u8>)> {
    let expected_sha256 = certificate_sha256
        .map(hex::decode)
        .transpose()
        .context("certificate SHA-256 is not valid hexadecimal")?;
    let peer_certificate_der = Arc::new(Mutex::new(None));
    let verifier = RecordingCertificateVerifier {
        expected_sha256,
        peer_certificate_der: peer_certificate_der.clone(),
    };
    let tls_config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth();
    let client_options = kynet::quinn::QuinnClientOptions {
        max_idle_timeout: Some(options.idle_timeout),
        keep_alive_interval: Some(options.keep_alive_interval),
        max_udp_payload_size: options.max_udp_payload_size,
        certificate_hash: None,
        ..Default::default()
    };
    let raw_connection = kynet::Connection::quinn_connect(
        remote_address,
        server_name,
        Some(tls_config),
        &client_options,
    )
    .await?;
    let peer_certificate_der = peer_certificate_der
        .lock()
        .unwrap()
        .take()
        .ok_or_else(|| anyhow!("QUIC handshake did not provide a peer certificate"))?;
    Ok((raw_connection, peer_certificate_der))
}

pub async fn accept_server(
    server: &kynet::common::CommonServer,
    expected_token: &str,
    options: NativeOptions,
) -> Result<NativeServerProtocols> {
    let raw_connection = tokio::time::timeout(options.handshake_timeout, server.accept())
        .await
        .context("timed out waiting for native KyProto connection")??
        .ok_or_else(|| anyhow!("native KyProto listener closed"))?;
    let unauthenticated = tokio::time::timeout(
        options.handshake_timeout,
        Connection::accept_with_auth(raw_connection),
    )
    .await
    .context("timed out receiving native KyProto authentication")??;

    if unauthenticated
        .get_auth()
        .token()
        .as_bytes()
        .ct_eq(expected_token.as_bytes())
        .unwrap_u8()
        != 1
    {
        unauthenticated.reject_authentication();
        bail!("native KyProto authentication token mismatch");
    }

    let connection = unauthenticated.accept_authentication().await?;
    let (video_id, video_endpoint) = connection
        .register_video_endpoint(VideoProtocol::UnreliableFec)
        .await?;
    verify_endpoint_id(video_id, VIDEO_ENDPOINT_ID, "video")?;
    let (audio_id, audio_endpoint) = connection
        .register_audio_endpoint(AudioProtocol::UnreliableFec)
        .await?;
    verify_endpoint_id(audio_id, AUDIO_ENDPOINT_ID, "audio")?;
    let (input_id, input_endpoint) = connection.register_input_endpoint().await?;
    verify_endpoint_id(input_id, INPUT_ENDPOINT_ID, "input")?;
    let (data_id, data_endpoint) = connection.register_data_endpoint().await?;
    verify_endpoint_id(data_id, DATA_ENDPOINT_ID, "data")?;

    let ready = async {
        let video = video_endpoint.ready().await?;
        let audio = audio_endpoint.ready().await?;
        let input = input_endpoint.ready().await?;
        let data = data_endpoint.ready().await?;
        Ok::<_, kyproto::ProtocolError>((video, audio, input, data))
    };
    let (video, audio, input, data) = tokio::time::timeout(options.handshake_timeout, ready)
        .await
        .context("timed out starting native KyProto endpoints")??;

    Ok(NativeServerProtocols {
        connection,
        video,
        audio,
        input,
        data,
    })
}

pub async fn connect_client(
    remote_address: SocketAddr,
    server_name: &str,
    certificate_sha256: Option<&str>,
    session_token: &str,
    options: NativeOptions,
) -> Result<NativeClientProtocols> {
    let connect = async {
        let (raw_connection, peer_certificate_der) =
            connect_raw_client(remote_address, server_name, certificate_sha256, options).await?;
        let auth = ClientAuth::new(session_token)?;
        let connection = Connection::connect_with_auth(raw_connection, &auth).await?;

        let video_endpoint =
            connection.connect_video_endpoint(VIDEO_ENDPOINT_ID, VideoProtocol::UnreliableFec)?;
        let audio_endpoint =
            connection.connect_audio_endpoint(AUDIO_ENDPOINT_ID, AudioProtocol::UnreliableFec)?;
        let input_endpoint = connection.connect_input_endpoint(INPUT_ENDPOINT_ID)?;
        let data_endpoint = connection.connect_data_endpoint(DATA_ENDPOINT_ID)?;

        let video = video_endpoint.ready().await?;
        let audio = audio_endpoint.ready().await?;
        let input = input_endpoint.ready().await?;
        let data = data_endpoint.ready().await?;
        Ok::<_, anyhow::Error>(NativeClientProtocols {
            connection,
            peer_certificate_der,
            video,
            audio,
            input,
            data,
        })
    };

    tokio::time::timeout(options.handshake_timeout, connect)
        .await
        .context("timed out establishing native KyProto connection")?
}

pub async fn accept_setup_server(
    server: &kynet::common::CommonServer,
    expected_token: &str,
    options: NativeOptions,
) -> Result<NativeSetupServerProtocols> {
    let raw_connection = tokio::time::timeout(options.handshake_timeout, server.accept())
        .await
        .context("timed out waiting for setup KyProto connection")??
        .ok_or_else(|| anyhow!("setup KyProto listener closed"))?;
    let unauthenticated = tokio::time::timeout(
        options.handshake_timeout,
        Connection::accept_with_auth(raw_connection),
    )
    .await
    .context("timed out receiving setup KyProto marker")??;
    if unauthenticated
        .get_auth()
        .token()
        .as_bytes()
        .ct_eq(expected_token.as_bytes())
        .unwrap_u8()
        != 1
    {
        unauthenticated.reject_authentication();
        bail!("setup KyProto marker mismatch");
    }
    let connection = unauthenticated.accept_authentication().await?;
    let (data_id, data_endpoint) = connection.register_data_endpoint().await?;
    verify_endpoint_id(data_id, SETUP_DATA_ENDPOINT_ID, "setup data")?;
    let data = tokio::time::timeout(options.handshake_timeout, data_endpoint.ready())
        .await
        .context("timed out starting setup data endpoint")??;
    Ok(NativeSetupServerProtocols { connection, data })
}

pub async fn connect_setup_client(
    remote_address: SocketAddr,
    server_name: &str,
    setup_marker: &str,
    options: NativeOptions,
) -> Result<NativeSetupClientProtocols> {
    let connect = async {
        let (raw_connection, peer_certificate_der) =
            connect_raw_client(remote_address, server_name, None, options).await?;
        let auth = ClientAuth::new(setup_marker)?;
        let connection = Connection::connect_with_auth(raw_connection, &auth).await?;
        let data_endpoint = connection.connect_data_endpoint(SETUP_DATA_ENDPOINT_ID)?;
        let data = data_endpoint.ready().await?;
        Ok::<_, anyhow::Error>(NativeSetupClientProtocols {
            connection,
            peer_certificate_der,
            data,
        })
    };
    tokio::time::timeout(options.handshake_timeout, connect)
        .await
        .context("timed out establishing setup KyProto connection")?
}

pub async fn promote_setup_server(
    connection: &Connection,
    options: NativeOptions,
) -> Result<(VideoServerProtocol, AudioServerProtocol, InputProtocol)> {
    let (video_id, video_endpoint) = connection
        .register_video_endpoint(VideoProtocol::UnreliableFec)
        .await?;
    verify_endpoint_id(video_id, SETUP_VIDEO_ENDPOINT_ID, "setup video")?;
    let (audio_id, audio_endpoint) = connection
        .register_audio_endpoint(AudioProtocol::UnreliableFec)
        .await?;
    verify_endpoint_id(audio_id, SETUP_AUDIO_ENDPOINT_ID, "setup audio")?;
    let (input_id, input_endpoint) = connection.register_input_endpoint().await?;
    verify_endpoint_id(input_id, SETUP_INPUT_ENDPOINT_ID, "setup input")?;
    let ready = async {
        let video = video_endpoint.ready().await?;
        let audio = audio_endpoint.ready().await?;
        let input = input_endpoint.ready().await?;
        Ok::<_, kyproto::ProtocolError>((video, audio, input))
    };
    let (video, audio, input) = tokio::time::timeout(options.handshake_timeout, ready)
        .await
        .context("timed out promoting server KyProto endpoints")??;
    Ok((video, audio, input))
}

pub async fn promote_setup_client(
    connection: &Connection,
    options: NativeOptions,
) -> Result<(VideoClientProtocol, AudioClientProtocol, InputProtocol)> {
    let video_endpoint =
        connection.connect_video_endpoint(SETUP_VIDEO_ENDPOINT_ID, VideoProtocol::UnreliableFec)?;
    let audio_endpoint =
        connection.connect_audio_endpoint(SETUP_AUDIO_ENDPOINT_ID, AudioProtocol::UnreliableFec)?;
    let input_endpoint = connection.connect_input_endpoint(SETUP_INPUT_ENDPOINT_ID)?;
    let ready = async {
        let video = video_endpoint.ready().await?;
        let audio = audio_endpoint.ready().await?;
        let input = input_endpoint.ready().await?;
        Ok::<_, kyproto::ProtocolError>((video, audio, input))
    };
    let (video, audio, input) = tokio::time::timeout(options.handshake_timeout, ready)
        .await
        .context("timed out promoting client KyProto endpoints")??;
    Ok((video, audio, input))
}

#[cfg(test)]
#[path = "test_loss_proxy.rs"]
mod loss_proxy;

#[cfg(test)]
#[path = "test_loss_performance.rs"]
mod loss_performance;

#[cfg(test)]
mod tests {
    use super::loss_performance::{
        FRAME_DEADLINE, FRAMES_PER_PHASE, LOSS_BASIS_POINTS, PAYLOAD_BYTES, PhasePerformance,
        TOTAL_FRAMES, frame_offset,
    };
    use super::loss_proxy::LossProxy;
    use super::*;
    use crate::rate_control::{PlankRateControllerFactory, TransportRatePolicy};
    use bytes::Bytes;
    use kymux_types::{
        AVPacket, CodecPacket, CodecPacketHeader, DataPacket, InputPacket, MediaPacket,
        MediaPacketHeader,
    };
    use std::path::PathBuf;
    use std::sync::atomic::Ordering;

    fn test_certificate_paths() -> (PathBuf, PathBuf, String) {
        let certificate = std::env::var_os("SC_NATIVE_TEST_CERTIFICATE")
            .map(PathBuf::from)
            .expect("SC_NATIVE_TEST_CERTIFICATE must name the loopback certificate");
        let private_key = std::env::var_os("SC_NATIVE_TEST_PRIVATE_KEY")
            .map(PathBuf::from)
            .expect("SC_NATIVE_TEST_PRIVATE_KEY must name the loopback private key");
        let certificate_sha256 = std::env::var("SC_NATIVE_TEST_CERTIFICATE_SHA256")
            .expect("SC_NATIVE_TEST_CERTIFICATE_SHA256 must contain the DER fingerprint");
        (certificate, private_key, certificate_sha256)
    }

    fn unused_loopback_address() -> SocketAddr {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0")
            .expect("failed to reserve a loopback UDP port");
        let address = socket
            .local_addr()
            .expect("loopback UDP socket has no address");
        drop(socket);
        address
    }

    #[test]
    fn plank_endpoint_manifest_tracks_server_allocation_order() {
        assert_eq!(VIDEO_ENDPOINT_ID, 0);
        assert_eq!(AUDIO_ENDPOINT_ID, VIDEO_ENDPOINT_ID + 2);
        assert_eq!(INPUT_ENDPOINT_ID, AUDIO_ENDPOINT_ID + 2);
        assert_eq!(DATA_ENDPOINT_ID, INPUT_ENDPOINT_ID + 2);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "run through scripts/test/run-plank-transport-native-loopback.sh"]
    async fn native_kyproto_round_trip_preserves_all_initial_lanes() {
        crate::init_crypto_once();
        let (certificate_path, private_key_path, certificate_sha256) = test_certificate_paths();
        let certificate = kynet::cert::load_cert_from_pem_file(&certificate_path)
            .await
            .expect("failed to load loopback certificate");
        let private_key = kynet::cert::load_private_key_from_pem_file(&private_key_path)
            .await
            .expect("failed to load loopback private key");
        let address = unused_loopback_address();
        let options = NativeOptions {
            handshake_timeout: Duration::from_secs(5),
            idle_timeout: Duration::from_secs(10),
            keep_alive_interval: Duration::from_secs(1),
            max_udp_payload_size: Some(1344),
        };
        let rate_policy = TransportRatePolicy::new(100_000_000);
        let server_options = kynet::common::CommonServerOptions {
            max_idle_timeout: Some(options.idle_timeout),
            keep_alive_interval: Some(options.keep_alive_interval),
            max_udp_payload_size: options.max_udp_payload_size,
            congestion_controller_factory: Some(PlankRateControllerFactory::new(
                rate_policy.clone(),
            )),
        };
        let server = kynet::Connection::start_server_on_addr(
            address,
            vec![certificate],
            private_key,
            &server_options,
        )
        .expect("failed to start native KyProto loopback server");
        let token = "plank-native-kyproto-loopback";

        let (server_protocols, client_protocols) = tokio::join!(
            accept_server(&server, token, options),
            connect_client(
                address,
                "localhost",
                Some(&certificate_sha256),
                token,
                options,
            ),
        );
        let NativeServerProtocols {
            connection: server_connection,
            video: mut server_video,
            audio: mut server_audio,
            input: mut server_input,
            data: mut server_data,
        } = server_protocols.expect("native KyProto server handshake failed");
        let NativeClientProtocols {
            connection: client_connection,
            video: mut client_video,
            audio: mut client_audio,
            input: mut client_input,
            data: mut client_data,
            peer_certificate_der: _,
        } = client_protocols.expect("native KyProto client handshake failed");

        // A Client-created audio source works over the same authenticated QUIC
        // connection alongside the ordinary Host-created media/input lanes.
        let (microphone_source, microphone_sink) = tokio::join!(
            crate::microphone::open_source(&client_connection, options.handshake_timeout),
            crate::microphone::open_sink(&server_connection, options.handshake_timeout),
        );
        let mut microphone_source = microphone_source.expect("reverse audio source");
        let mut microphone_sink = microphone_sink.expect("reverse audio sink");
        let microphone_packet = crate::microphone::Packet {
            generation: 42,
            sample_time: 0,
            opus: Bytes::from_static(&[0xF0, 0xFF, 0xFE]),
        };
        let microphone_payload = microphone_packet.encode().unwrap();
        microphone_source
            .send
            .send(AVPacket::Codec(CodecPacket {
                header: CodecPacketHeader {
                    codec: u32::from_be_bytes(*b"OPUS"),
                    rotation: 0,
                    frame_size: 480,
                },
            }))
            .await
            .unwrap();
        microphone_source
            .send
            .send(AVPacket::Media(MediaPacket {
                header: MediaPacketHeader {
                    is_config: true,
                    is_key: true,
                    pts: 0,
                    size: 0,
                },
                payload: Bytes::new(),
            }))
            .await
            .unwrap();
        microphone_source
            .send
            .send(AVPacket::Media(MediaPacket {
                header: MediaPacketHeader {
                    is_config: false,
                    is_key: false,
                    pts: 0,
                    size: microphone_payload.len() as u32,
                },
                payload: microphone_payload,
            }))
            .await
            .unwrap();
        tokio::time::timeout(options.handshake_timeout, async {
            assert!(matches!(
                microphone_sink.recv.recv().await.unwrap(),
                Some(AVPacket::Codec(_))
            ));
            assert!(matches!(
                microphone_sink.recv.recv().await.unwrap(),
                Some(AVPacket::Media(packet)) if packet.header.is_config
            ));
            let Some(AVPacket::Media(packet)) = microphone_sink.recv.recv().await.unwrap() else {
                panic!("missing reverse audio packet");
            };
            assert_eq!(
                crate::microphone::Packet::decode(packet.payload).unwrap(),
                microphone_packet
            );
        })
        .await
        .expect("reverse audio delivery timeout");

        server_video
            .send
            .send(AVPacket::Codec(CodecPacket {
                header: CodecPacketHeader {
                    codec: u32::from_be_bytes(*b"HEVC"),
                    rotation: 0,
                    frame_size: 0,
                },
            }))
            .await
            .expect("failed to send native video codec packet");
        let video_config_payload = Bytes::from_static(b"annex-b-vps-sps-pps");
        server_video
            .send
            .send(AVPacket::Media(MediaPacket {
                header: MediaPacketHeader {
                    is_config: true,
                    is_key: true,
                    pts: 0,
                    size: video_config_payload.len() as u32,
                },
                payload: video_config_payload.clone(),
            }))
            .await
            .expect("failed to send native video configuration packet");
        let video_payload = Bytes::from(
            (0..192 * 1024)
                .map(|index| ((index * 37 + 11) & 0xff) as u8)
                .collect::<Vec<_>>(),
        );
        server_video
            .send
            .send(AVPacket::Media(MediaPacket {
                header: MediaPacketHeader {
                    is_config: false,
                    is_key: true,
                    pts: 90_000,
                    size: video_payload.len() as u32,
                },
                payload: video_payload.clone(),
            }))
            .await
            .expect("failed to send native RaptorQ video frame");

        let received_video_codec =
            tokio::time::timeout(Duration::from_secs(5), client_video.recv.recv())
                .await
                .expect("native video codec receive timed out")
                .expect("native video codec receive failed")
                .expect("native video codec endpoint closed");
        assert!(matches!(received_video_codec, AVPacket::Codec(_)));
        let received_video_config =
            tokio::time::timeout(Duration::from_secs(5), client_video.recv.recv())
                .await
                .expect("native video configuration receive timed out")
                .expect("native video configuration receive failed")
                .expect("native video endpoint closed before configuration");
        let AVPacket::Media(received_video_config) = received_video_config else {
            panic!("native video endpoint returned a non-media configuration packet");
        };
        assert!(received_video_config.header.is_config);
        assert_eq!(received_video_config.payload, video_config_payload);
        let received_video = tokio::time::timeout(Duration::from_secs(5), client_video.recv.recv())
            .await
            .expect("native video frame receive timed out")
            .expect("native video frame receive failed")
            .expect("native video endpoint closed");
        let AVPacket::Media(received_video) = received_video else {
            panic!("native video endpoint returned a non-media packet");
        };
        assert!(received_video.header.is_key);
        assert_eq!(received_video.header.pts, 90_000);
        assert_eq!(received_video.payload, video_payload);
        let video_protocol_stats = client_connection.protocol_stats();
        assert!(
            video_protocol_stats
                .video_fec_source_symbols
                .unwrap_or_default()
                > 0
        );
        assert_eq!(
            video_protocol_stats
                .video_fec_source_symbols_missing
                .unwrap_or_default(),
            0
        );

        server_audio
            .send
            .send(AVPacket::Codec(CodecPacket {
                header: CodecPacketHeader {
                    codec: u32::from_be_bytes(*b"OPUS"),
                    rotation: 0,
                    frame_size: 960,
                },
            }))
            .await
            .expect("failed to send native audio codec packet");
        let audio_config_payload = Bytes::from_static(b"OpusHead");
        server_audio
            .send
            .send(AVPacket::Media(MediaPacket {
                header: MediaPacketHeader {
                    is_config: true,
                    is_key: true,
                    pts: 0,
                    size: audio_config_payload.len() as u32,
                },
                payload: audio_config_payload.clone(),
            }))
            .await
            .expect("failed to send native audio configuration packet");
        let audio_payload = Bytes::from_static(b"plank-opus-packet");
        server_audio
            .send
            .send(AVPacket::Media(MediaPacket {
                header: MediaPacketHeader {
                    is_config: false,
                    is_key: false,
                    pts: 960,
                    size: audio_payload.len() as u32,
                },
                payload: audio_payload.clone(),
            }))
            .await
            .expect("failed to send native RaptorQ audio packet");
        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(5), client_audio.recv.recv())
                .await
                .expect("native audio codec receive timed out")
                .expect("native audio codec receive failed")
                .expect("native audio endpoint closed"),
            AVPacket::Codec(_)
        ));
        let received_audio_config =
            tokio::time::timeout(Duration::from_secs(5), client_audio.recv.recv())
                .await
                .expect("native audio configuration receive timed out")
                .expect("native audio configuration receive failed")
                .expect("native audio endpoint closed before configuration");
        let AVPacket::Media(received_audio_config) = received_audio_config else {
            panic!("native audio endpoint returned a non-media configuration packet");
        };
        assert!(received_audio_config.header.is_config);
        assert_eq!(received_audio_config.payload, audio_config_payload);
        let received_audio = tokio::time::timeout(Duration::from_secs(5), client_audio.recv.recv())
            .await
            .expect("native audio packet receive timed out")
            .expect("native audio packet receive failed")
            .expect("native audio endpoint closed");
        let AVPacket::Media(received_audio) = received_audio else {
            panic!("native audio endpoint returned a non-media packet");
        };
        assert_eq!(received_audio.payload, audio_payload);

        let input_payload = Bytes::from_static(b"wacom-state-transition");
        client_input
            .send
            .send(InputPacket {
                type_: 7,
                payload: input_payload.clone(),
            })
            .await
            .expect("failed to send native input packet");
        let received_input = tokio::time::timeout(Duration::from_secs(5), server_input.recv.recv())
            .await
            .expect("native input receive timed out")
            .expect("native input receive failed")
            .expect("native input endpoint closed");
        assert_eq!(received_input.type_, 7);
        assert_eq!(received_input.payload, input_payload);

        let client_data_payload = Bytes::from_static(b"client-control");
        client_data
            .send
            .send(DataPacket {
                payload: client_data_payload.clone(),
            })
            .await
            .expect("failed to send native client data packet");
        let received_client_data =
            tokio::time::timeout(Duration::from_secs(5), server_data.recv.recv())
                .await
                .expect("native client data receive timed out")
                .expect("native client data receive failed")
                .expect("native server data endpoint closed");
        assert_eq!(received_client_data.payload, client_data_payload);

        let server_data_payload = Bytes::from_static(b"server-control");
        server_data
            .send
            .send(DataPacket {
                payload: server_data_payload.clone(),
            })
            .await
            .expect("failed to send native server data packet");
        let received_server_data =
            tokio::time::timeout(Duration::from_secs(5), client_data.recv.recv())
                .await
                .expect("native server data receive timed out")
                .expect("native server data receive failed")
                .expect("native client data endpoint closed");
        assert_eq!(received_server_data.payload, server_data_payload);

        let server_stats = server_connection.connection_stats().await;
        let client_stats = client_connection.connection_stats().await;
        assert!(server_stats.rtt.is_some());
        assert!(client_stats.rtt.is_some());
        assert_eq!(
            client_connection
                .protocol_stats()
                .dropped_packets
                .unwrap_or_default(),
            0
        );
        server_connection.close();
        client_connection.close();
        server.close(0, "native KyProto loopback complete");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "run through scripts/test/run-plank-transport-native-loopback.sh"]
    async fn native_raptorq_survives_progressive_transport_loss_at_150_mbps() {
        crate::init_crypto_once();
        let (certificate_path, private_key_path, certificate_sha256) = test_certificate_paths();
        let certificate = kynet::cert::load_cert_from_pem_file(&certificate_path)
            .await
            .expect("failed to load loopback certificate");
        let private_key = kynet::cert::load_private_key_from_pem_file(&private_key_path)
            .await
            .expect("failed to load loopback private key");
        let server_address = unused_loopback_address();
        let mut proxy = LossProxy::start(server_address).expect("failed to start loss proxy");

        let options = NativeOptions {
            handshake_timeout: Duration::from_secs(5),
            idle_timeout: Duration::from_secs(10),
            keep_alive_interval: Duration::from_secs(1),
            max_udp_payload_size: Some(1_344),
        };
        let rate_policy = TransportRatePolicy::new(150_000_000);
        let server_options = kynet::common::CommonServerOptions {
            max_idle_timeout: Some(options.idle_timeout),
            keep_alive_interval: Some(options.keep_alive_interval),
            max_udp_payload_size: options.max_udp_payload_size,
            congestion_controller_factory: Some(PlankRateControllerFactory::new(
                rate_policy.clone(),
            )),
        };
        let server = kynet::Connection::start_server_on_addr(
            server_address,
            vec![certificate],
            private_key,
            &server_options,
        )
        .expect("failed to start loss-test KyProto server");
        let token = "plank-native-loss-loopback";
        let (server_protocols, client_protocols) = tokio::join!(
            accept_server(&server, token, options),
            connect_client(
                proxy.address,
                "localhost",
                Some(&certificate_sha256),
                token,
                options,
            ),
        );
        let NativeServerProtocols {
            connection: server_connection,
            video: mut server_video,
            audio: _,
            input: _,
            data: _,
        } = server_protocols.expect("loss-test server handshake failed");
        let NativeClientProtocols {
            connection: client_connection,
            video: mut client_video,
            audio: _,
            input: _,
            data: _,
            peer_certificate_der: _,
        } = client_protocols.expect("loss-test client handshake failed");

        server_video
            .send
            .send(AVPacket::Codec(CodecPacket {
                header: CodecPacketHeader {
                    codec: u32::from_be_bytes(*b"HEVC"),
                    rotation: 0,
                    frame_size: 0,
                },
            }))
            .await
            .expect("failed to send loss-test codec packet");
        server_video
            .send
            .send(AVPacket::Media(MediaPacket {
                header: MediaPacketHeader {
                    is_config: true,
                    is_key: true,
                    pts: 0,
                    size: 0,
                },
                payload: Bytes::new(),
            }))
            .await
            .expect("failed to send loss-test config packet");

        let payload = Bytes::from(
            (0..PAYLOAD_BYTES)
                .map(|index| ((index * 29 + 7) & 0xff) as u8)
                .collect::<Vec<_>>(),
        );
        let expected_payload = payload.clone();
        // A single epoch across every phase prevents delayed sends from
        // silently lowering the offered load or resetting accumulated latency.
        let matrix_start = tokio::time::Instant::now();
        let mut receiver = tokio::spawn(async move {
            let mut received = Vec::with_capacity(TOTAL_FRAMES);
            while received.len() < TOTAL_FRAMES {
                let frame = received.len();
                let deadline = matrix_start + frame_offset(frame) + FRAME_DEADLINE;
                let packet = tokio::time::timeout_at(deadline, client_video.recv.recv())
                    .await
                    .unwrap_or_else(|_| {
                        panic!("loss-test receiver missed 100 ms scheduled deadline for frame {frame}")
                    })
                    .expect("loss-test video endpoint closed")
                    .expect("loss-test video receive failed");
                let received_at = matrix_start.elapsed();
                if let AVPacket::Media(media) = packet {
                    if !media.header.is_config {
                        assert_eq!(media.header.pts, frame as u64 * 1_500);
                        assert_eq!(media.payload, expected_payload);
                        received.push(received_at);
                    }
                }
            }
            received
        });

        let mut submitted = Vec::with_capacity(TOTAL_FRAMES);
        let mut dropped_after_phase = 0_u64;
        for loss in LOSS_BASIS_POINTS {
            proxy.loss_basis_points.store(loss, Ordering::Release);
            let phase_start = matrix_start + frame_offset(submitted.len());
            for _ in 0..FRAMES_PER_PHASE {
                let frame_number = submitted.len();
                let due = matrix_start + frame_offset(frame_number);
                tokio::time::sleep_until(due).await;
                tokio::time::timeout_at(
                    due + FRAME_DEADLINE,
                    server_video.send.send(AVPacket::Media(MediaPacket {
                        header: MediaPacketHeader {
                            is_config: false,
                            is_key: frame_number == 0,
                            pts: frame_number as u64 * 1_500,
                            size: payload.len() as u32,
                        },
                        payload: payload.clone(),
                    })),
                )
                .await
                .unwrap_or_else(|_| {
                    panic!("loss-test sender missed 100 ms scheduled deadline for frame {frame_number}")
                })
                .expect("failed to send paced loss-test frame");
                submitted.push(matrix_start.elapsed());
            }
            tokio::time::sleep_until(matrix_start + frame_offset(submitted.len())).await;
            let dropped = proxy.dropped.load(Ordering::Relaxed);
            if loss == 0 {
                assert_eq!(dropped, dropped_after_phase);
            } else {
                assert!(dropped > dropped_after_phase);
            }
            eprintln!(
                "fec_loss_phase_basis_points={loss} frames={FRAMES_PER_PHASE} elapsed_ms={} dropped_datagrams={}",
                phase_start.elapsed().as_millis(), dropped - dropped_after_phase
            );
            dropped_after_phase = dropped;
        }
        let received = tokio::time::timeout_at(
            matrix_start + frame_offset(TOTAL_FRAMES) + FRAME_DEADLINE,
            &mut receiver,
        )
        .await;
        if received.is_err() {
            receiver.abort();
        }
        // Report/validate the proxy even when the frame-order assertion failed.
        proxy.finish();
        let received = received
            .expect("loss-test receiver timed out")
            .expect("loss-test receiver task failed");
        assert_eq!(received.len(), TOTAL_FRAMES);
        let mut performance_failures = Vec::new();
        for (phase, loss) in LOSS_BASIS_POINTS.into_iter().enumerate() {
            let first = phase * FRAMES_PER_PHASE;
            let end = first + FRAMES_PER_PHASE;
            let metrics = PhasePerformance::measure(
                first,
                &submitted[first..end],
                &received[first..end],
                first.checked_sub(1).map(|index| received[index]),
            )
            .expect("invalid loss-test timing samples");
            let violations = metrics.violations();
            eprintln!(
                "fec_loss_performance_basis_points={loss} frames={FRAMES_PER_PHASE} payload_bytes={PAYLOAD_BYTES} submitted_bps={} received_bps={} received_millifps={} submission_max_us={} delivery_p95_us={} delivery_max_us={} receive_gap_max_us={} completion_us={} pass={}",
                metrics.submitted_bps, metrics.received_bps, metrics.received_millifps,
                metrics.submission_max.as_micros(),
                metrics.delivery_p95.as_micros(), metrics.delivery_max.as_micros(),
                metrics.receive_gap_max.as_micros(), metrics.completion.as_micros(),
                violations.is_empty(),
            );
            if !violations.is_empty() {
                performance_failures.push((loss, violations));
            }
        }
        assert!(proxy.forwarded.load(Ordering::Relaxed) > 20_000);
        assert!(proxy.dropped.load(Ordering::Relaxed) > 500);
        let fec = client_connection.protocol_stats();
        let source = fec.video_fec_source_symbols.expect("missing FEC denominator");
        let missing = fec.video_fec_source_symbols_missing.expect("missing pre-FEC counter");
        assert!(source > 0 && missing > 0 && missing <= source);
        assert_eq!(fec.video_fec_source_symbols_unrecovered, Some(0));
        eprintln!("fec_loss_matrix_frames={TOTAL_FRAMES} source={source} missing={missing} unrecovered=0");

        server_connection.close();
        client_connection.close();
        server.close(0, "loss test complete");
        assert!(
            performance_failures.is_empty(),
            "loss-test performance gate failed: {performance_failures:?}"
        );
    }
}
