// SPDX-License-Identifier: AGPL-3.0-or-later

//! Validated configuration shared by the native C endpoint API.
use crate::*;
use anyhow::{Context, Result, bail};
use std::ffi::{CStr, c_char};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

const DEFAULT_HANDSHAKE_TIMEOUT_MS: u32 = 10_000;
const DEFAULT_IDLE_TIMEOUT_MS: u32 = 10_000;
const DEFAULT_KEEP_ALIVE_INTERVAL_MS: u32 = 2_000;
const MAX_ADDRESS_LENGTH: usize = 512;
const MAX_SERVER_NAME_LENGTH: usize = 253;
const MAX_PATH_LENGTH: usize = 4_096;
const MAX_TOKEN_LENGTH: usize = 1_024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum EndpointState {
    Invalid = 0,
    Idle = 1,
    Starting = 2,
    PeerValidation = 3,
    SetupReady = 4,
    Ready = 5,
    Stopping = 6,
    Stopped = 7,
    Failed = 8,
}

#[derive(Clone)]
pub(crate) enum EndpointConfig {
    Server {
        bind_address: SocketAddr,
        certificate_path: PathBuf,
        private_key_path: PathBuf,
        session_token: String,
        setup_mode: bool,
        options: RuntimeOptions,
    },
    Client {
        remote_address: SocketAddr,
        server_name: String,
        certificate_sha256: Option<String>,
        session_token: String,
        setup_mode: bool,
        options: RuntimeOptions,
    },
}

#[derive(Clone, Copy)]
pub(crate) struct RuntimeOptions {
    pub(crate) handshake_timeout: Duration,
    pub(crate) idle_timeout: Duration,
    pub(crate) keep_alive_interval: Duration,
    pub(crate) max_udp_payload_size: Option<u16>,
    pub(crate) initial_video_bitrate_bps: u64,
}

#[repr(C)]
pub struct PlankTransportConfig {
    pub struct_size: u32,
    pub abi_version: u32,
    pub mode: u32,
    pub handshake_timeout_ms: u32,
    pub idle_timeout_ms: u32,
    pub keep_alive_interval_ms: u32,
    pub session_mode: u32,
    pub max_udp_payload_size: u32,
    pub initial_video_bitrate_kbps: u32,
    pub bind_address: *const c_char,
    pub remote_address: *const c_char,
    pub server_name: *const c_char,
    pub certificate_path: *const c_char,
    pub private_key_path: *const c_char,
    pub certificate_sha256: *const c_char,
    pub session_token: *const c_char,
}

unsafe fn required_string(value: *const c_char, field: &str, maximum: usize) -> Result<String> {
    if value.is_null() {
        bail!("{field} is required");
    }
    let value = unsafe { CStr::from_ptr(value) };
    let bytes = value.to_bytes();
    if bytes.is_empty() || bytes.len() > maximum {
        bail!("{field} length is invalid");
    }
    Ok(value
        .to_str()
        .with_context(|| format!("{field} is not UTF-8"))?
        .to_owned())
}

fn configured_duration(value_ms: u32, default_ms: u32, field: &str) -> Result<Duration> {
    let value_ms = if value_ms == 0 { default_ms } else { value_ms };
    if !(100..=120_000).contains(&value_ms) {
        bail!("{field} must be between 100 and 120000 milliseconds");
    }
    Ok(Duration::from_millis(u64::from(value_ms)))
}

fn configured_max_udp_payload_size(value: u32) -> Result<Option<u16>> {
    if value == 0 {
        return Ok(None);
    }
    if !(1200..=65_527).contains(&value) {
        bail!("max_udp_payload_size must be zero or between 1200 and 65527 bytes");
    }
    Ok(Some(value as u16))
}

pub(crate) unsafe fn parse_config(config: *const PlankTransportConfig) -> Result<EndpointConfig> {
    if config.is_null() {
        bail!("config is required");
    }
    let config = unsafe { &*config };
    if config.struct_size as usize != std::mem::size_of::<PlankTransportConfig>() {
        bail!("config structure size mismatch");
    }
    if config.abi_version != ABI_VERSION {
        bail!("unsupported ABI version {}", config.abi_version);
    }
    let options = RuntimeOptions {
        handshake_timeout: configured_duration(
            config.handshake_timeout_ms,
            DEFAULT_HANDSHAKE_TIMEOUT_MS,
            "handshake_timeout_ms",
        )?,
        idle_timeout: configured_duration(
            config.idle_timeout_ms,
            DEFAULT_IDLE_TIMEOUT_MS,
            "idle_timeout_ms",
        )?,
        keep_alive_interval: configured_duration(
            config.keep_alive_interval_ms,
            DEFAULT_KEEP_ALIVE_INTERVAL_MS,
            "keep_alive_interval_ms",
        )?,
        max_udp_payload_size: configured_max_udp_payload_size(config.max_udp_payload_size)?,
        initial_video_bitrate_bps: u64::from(config.initial_video_bitrate_kbps)
            .saturating_mul(1_000),
    };
    if config.session_mode > 1 {
        bail!("unsupported session_mode {}", config.session_mode);
    }
    let setup_mode = config.session_mode == 1;
    if options.keep_alive_interval >= options.idle_timeout {
        bail!("keep_alive_interval_ms must be less than idle_timeout_ms");
    }

    match config.mode {
        1 => {
            let bind_address = unsafe {
                required_string(config.bind_address, "bind_address", MAX_ADDRESS_LENGTH)?
            }
            .parse()
            .context("bind_address is not a socket address")?;
            let certificate_path = PathBuf::from(unsafe {
                required_string(config.certificate_path, "certificate_path", MAX_PATH_LENGTH)?
            });
            let private_key_path = PathBuf::from(unsafe {
                required_string(config.private_key_path, "private_key_path", MAX_PATH_LENGTH)?
            });
            let session_token = unsafe {
                required_string(config.session_token, "session_token", MAX_TOKEN_LENGTH)?
            };
            Ok(EndpointConfig::Server {
                bind_address,
                certificate_path,
                private_key_path,
                session_token,
                setup_mode,
                options,
            })
        }
        2 => {
            let remote_address = unsafe {
                required_string(config.remote_address, "remote_address", MAX_ADDRESS_LENGTH)?
            }
            .parse()
            .context("remote_address is not a socket address")?;
            let server_name = unsafe {
                required_string(config.server_name, "server_name", MAX_SERVER_NAME_LENGTH)?
            };
            let certificate_sha256 = if config.certificate_sha256.is_null() {
                None
            } else {
                let value = unsafe {
                    required_string(config.certificate_sha256, "certificate_sha256", 64)?
                };
                let decoded =
                    hex::decode(&value).context("certificate_sha256 is not valid hexadecimal")?;
                if decoded.len() != 32 {
                    bail!("certificate_sha256 must contain exactly 32 bytes");
                }
                Some(value)
            };
            let session_token = unsafe {
                required_string(config.session_token, "session_token", MAX_TOKEN_LENGTH)?
            };
            Ok(EndpointConfig::Client {
                remote_address,
                server_name,
                certificate_sha256,
                session_token,
                setup_mode,
                options,
            })
        }
        mode => bail!("unsupported endpoint mode {mode}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::native_ffi::*;
    use std::ffi::CString;
    use std::ptr;

    fn base_config() -> PlankTransportConfig {
        PlankTransportConfig {
            struct_size: std::mem::size_of::<PlankTransportConfig>() as u32,
            abi_version: ABI_VERSION,
            mode: 0,
            handshake_timeout_ms: 0,
            idle_timeout_ms: 0,
            keep_alive_interval_ms: 0,
            session_mode: 0,
            max_udp_payload_size: 0,
            initial_video_bitrate_kbps: 0,
            bind_address: ptr::null(),
            remote_address: ptr::null(),
            server_name: ptr::null(),
            certificate_path: ptr::null(),
            private_key_path: ptr::null(),
            certificate_sha256: ptr::null(),
            session_token: ptr::null(),
        }
    }

    #[test]
    fn public_header_abi_values_are_stable() {
        assert_eq!(plank_transport_abi_version(), 13);
        assert_eq!(EndpointState::Idle as u32, 1);
        assert_eq!(EndpointState::PeerValidation as u32, 3);
        assert_eq!(EndpointState::SetupReady as u32, 4);
        assert_eq!(EndpointState::Failed as u32, 8);
        assert_eq!(PLANK_TRANSPORT_DROPPED, 2);
        assert_eq!(PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL, -5);
    }

    #[test]
    fn maximum_udp_payload_size_is_bounded_by_quic() {
        assert_eq!(configured_max_udp_payload_size(0).unwrap(), None);
        assert_eq!(configured_max_udp_payload_size(1200).unwrap(), Some(1200));
        assert_eq!(configured_max_udp_payload_size(1344).unwrap(), Some(1344));
        assert_eq!(
            configured_max_udp_payload_size(65_527).unwrap(),
            Some(65_527)
        );
        assert!(configured_max_udp_payload_size(1199).is_err());
        assert!(configured_max_udp_payload_size(65_528).is_err());
    }

    #[test]
    fn server_config_is_copied_and_validated() {
        let bind = CString::new("127.0.0.1:47489").unwrap();
        let cert = CString::new("/tmp/cert.pem").unwrap();
        let key = CString::new("/tmp/key.pem").unwrap();
        let token = CString::new("session-token").unwrap();
        let mut config = base_config();
        config.mode = 1;
        config.bind_address = bind.as_ptr();
        config.certificate_path = cert.as_ptr();
        config.private_key_path = key.as_ptr();
        config.session_token = token.as_ptr();

        let parsed = unsafe { parse_config(&config) }.unwrap();
        match parsed {
            EndpointConfig::Server { bind_address, .. } => {
                assert_eq!(bind_address, "127.0.0.1:47489".parse().unwrap());
            }
            EndpointConfig::Client { .. } => panic!("unexpected client config"),
        }
    }

    #[test]
    fn client_accepts_profile_validation_or_an_exact_certificate_hash() {
        let remote = CString::new("127.0.0.1:47489").unwrap();
        let name = CString::new("localhost").unwrap();
        let hash = CString::new("00").unwrap();
        let token = CString::new("session-token").unwrap();
        let mut config = base_config();
        config.mode = 2;
        config.remote_address = remote.as_ptr();
        config.server_name = name.as_ptr();
        config.certificate_sha256 = hash.as_ptr();
        config.session_token = token.as_ptr();

        assert!(unsafe { parse_config(&config) }.is_err());

        config.certificate_sha256 = ptr::null();
        let parsed = unsafe { parse_config(&config) }.unwrap();
        match parsed {
            EndpointConfig::Client {
                certificate_sha256, ..
            } => assert!(certificate_sha256.is_none()),
            EndpointConfig::Server { .. } => panic!("unexpected server config"),
        }
    }

    #[test]
    fn create_start_failure_and_destroy_are_safe() {
        let bind = CString::new("127.0.0.1:0").unwrap();
        let cert = CString::new("/definitely/missing/cert.pem").unwrap();
        let key = CString::new("/definitely/missing/key.pem").unwrap();
        let token = CString::new("session-token").unwrap();
        let mut config = base_config();
        config.mode = 1;
        config.bind_address = bind.as_ptr();
        config.certificate_path = cert.as_ptr();
        config.private_key_path = key.as_ptr();
        config.session_token = token.as_ptr();
        let mut endpoint = ptr::null_mut();

        assert_eq!(
            unsafe { plank_transport_native_endpoint_create(&config, &mut endpoint) },
            PLANK_TRANSPORT_OK
        );
        assert!(!endpoint.is_null());
        assert_eq!(
            unsafe { plank_transport_native_endpoint_start(endpoint) },
            PLANK_TRANSPORT_OK
        );
        assert_eq!(
            unsafe { plank_transport_native_endpoint_wait_ready(endpoint, 2_000) },
            PLANK_TRANSPORT_ERROR_RUNTIME
        );
        assert_eq!(
            unsafe { plank_transport_native_endpoint_state(endpoint) },
            EndpointState::Failed as u32
        );
        let required =
            unsafe { plank_transport_native_endpoint_last_error(endpoint, ptr::null_mut(), 0) };
        assert!(required > 1);
        unsafe { plank_transport_native_endpoint_destroy(endpoint) };
    }

    #[test]
    fn stop_before_start_is_idempotent() {
        let bind = CString::new("127.0.0.1:0").unwrap();
        let cert = CString::new("/tmp/cert.pem").unwrap();
        let key = CString::new("/tmp/key.pem").unwrap();
        let token = CString::new("session-token").unwrap();
        let mut config = base_config();
        config.mode = 1;
        config.bind_address = bind.as_ptr();
        config.certificate_path = cert.as_ptr();
        config.private_key_path = key.as_ptr();
        config.session_token = token.as_ptr();
        let mut endpoint = ptr::null_mut();

        assert_eq!(
            unsafe { plank_transport_native_endpoint_create(&config, &mut endpoint) },
            PLANK_TRANSPORT_OK
        );
        assert_eq!(
            unsafe { plank_transport_native_endpoint_stop(endpoint) },
            PLANK_TRANSPORT_OK
        );
        assert_eq!(
            unsafe { plank_transport_native_endpoint_stop(endpoint) },
            PLANK_TRANSPORT_OK
        );
        unsafe { plank_transport_native_endpoint_destroy(endpoint) };
    }
}
