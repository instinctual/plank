// SPDX-License-Identifier: AGPL-3.0-or-later
//! Exercise the real TLS compatibility boundary, not just a constant comparison.
//! Old peers are simulated with their ALPN; no retired FEC decoder is shipped.
use super::*;
use std::path::PathBuf;

fn options() -> NativeOptions {
    NativeOptions {
        handshake_timeout: Duration::from_secs(3),
        idle_timeout: Duration::from_secs(5),
        keep_alive_interval: Duration::from_secs(1),
        max_udp_payload_size: Some(1344),
    }
}

async fn certificates() -> (kynet::cert::Certificate, kynet::cert::PrivateKey) {
    let certificate = PathBuf::from(std::env::var_os("SC_NATIVE_TEST_CERTIFICATE").unwrap());
    let key = PathBuf::from(std::env::var_os("SC_NATIVE_TEST_PRIVATE_KEY").unwrap());
    (
        kynet::cert::load_cert_from_pem_file(&certificate)
            .await
            .unwrap(),
        kynet::cert::load_private_key_from_pem_file(&key)
            .await
            .unwrap(),
    )
}

async fn peer_server(alpn: &[u8]) -> quinn::Endpoint {
    let (cert, key) = certificates().await;
    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .unwrap();
    tls.alpn_protocols = vec![alpn.to_vec()];
    let config = quinn::ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(tls).unwrap(),
    ));
    quinn::Endpoint::server(config, "127.0.0.1:0".parse().unwrap()).unwrap()
}

fn peer_client(alpn: &[u8]) -> quinn::Endpoint {
    let mut tls = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(RecordingCertificateVerifier {
            expected_sha256: None,
            peer_certificate_der: Arc::new(Mutex::new(None)),
        }))
        .with_no_client_auth();
    tls.alpn_protocols = if alpn.is_empty() {
        vec![]
    } else {
        vec![alpn.to_vec()]
    };
    let config = quinn::ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(tls).unwrap(),
    ));
    let mut endpoint = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
    endpoint.set_default_client_config(config);
    endpoint
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "run through scripts/test/run-plank-transport-native-loopback.sh"]
async fn incompatible_peers_fail_tls_before_setup_or_media() {
    crate::init_crypto_once();
    // Both native entry points: pre-session setup and direct media sessions.
    for setup in [false, true] {
        for incompatible in [b"kymux".as_slice(), b"plank-native/3".as_slice()] {
            let peer = peer_server(incompatible).await;
            let address = peer.local_addr().unwrap();
            let serve = async {
                let result = peer.accept().await.unwrap().await;
                assert!(
                    result.is_err(),
                    "incompatible peer reached application streams"
                );
            };
            let connect = async {
                let result = if setup {
                    connect_setup_client(address, "localhost", "version-test", options())
                        .await
                        .map(|_| ())
                } else {
                    connect_client(address, "localhost", None, "version-test", options())
                        .await
                        .map(|_| ())
                };
                let error = format!("{:#}", result.unwrap_err());
                assert!(
                    error.contains("Incompatible PLANK transport protocol"),
                    "{error}"
                );
                assert!(error.contains("update both Host and Client"), "{error}");
            };
            tokio::time::timeout(Duration::from_secs(5), async {
                tokio::join!(serve, connect);
            })
            .await
            .expect("protocol mismatch must not wait for application timeouts");
            peer.close(0u32.into(), b"test complete");
        }

        for incompatible in [
            b"kymux".as_slice(),
            b"plank-native/3".as_slice(),
            b"".as_slice(),
        ] {
            let (cert, key) = certificates().await;
            let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
            let address = socket.local_addr().unwrap();
            drop(socket);
            let server = kynet::Connection::start_server_on_addr(
                address,
                vec![cert],
                key,
                &kynet::common::CommonServerOptions::default(),
            )
            .unwrap();
            let client = peer_client(incompatible);
            let serve = async {
                let result = if setup {
                    accept_setup_server(&server, "version-test", options())
                        .await
                        .map(|_| ())
                } else {
                    accept_server(&server, "version-test", options())
                        .await
                        .map(|_| ())
                };
                let error = format!("{:#}", result.unwrap_err());
                assert!(
                    error.contains("Incompatible PLANK transport protocol"),
                    "{error}"
                );
            };
            let connect = async {
                let result = client.connect(address, "localhost").unwrap().await;
                assert!(
                    matches!(result, Err(quinn::ConnectionError::ConnectionClosed(ref error))
                    if u64::from(error.error_code) == 0x178),
                    "{result:?}"
                );
            };
            tokio::time::timeout(Duration::from_secs(5), async {
                tokio::join!(serve, connect);
            })
            .await
            .expect("protocol mismatch must not wait for application timeouts");
            client.close(0u32.into(), b"test complete");
            server.close(0, "test complete");
        }
    }
}
