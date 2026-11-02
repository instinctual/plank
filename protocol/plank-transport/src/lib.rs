// SPDX-License-Identifier: AGPL-3.0-or-later

//! Native KyProto transport and its synchronous C API.
mod config;
use config::{EndpointConfig, RuntimeOptions, parse_config};
pub use config::{EndpointState, PlankTransportConfig};
use std::sync::Once;

pub mod camera;
pub mod camera_encoded;
mod camera_record;
pub mod microphone;
pub mod native;
pub mod native_ffi;
pub mod rate_control;

pub const ABI_VERSION: u32 = 13;

pub const PLANK_TRANSPORT_OK: i32 = 0;
pub const PLANK_TRANSPORT_TIMEOUT: i32 = 1;
pub const PLANK_TRANSPORT_DROPPED: i32 = 2;
pub const PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT: i32 = -1;
pub const PLANK_TRANSPORT_ERROR_INVALID_STATE: i32 = -2;
pub const PLANK_TRANSPORT_ERROR_RUNTIME: i32 = -3;
pub const PLANK_TRANSPORT_ERROR_PANIC: i32 = -4;
pub const PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL: i32 = -5;

fn init_crypto_once() {
    static CRYPTO_INIT: Once = Once::new();
    CRYPTO_INIT.call_once(kynet::init_crypto);
}

fn catch_result(function: impl FnOnce() -> i32) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(function))
        .unwrap_or(PLANK_TRANSPORT_ERROR_PANIC)
}

#[unsafe(no_mangle)]
pub extern "C" fn plank_transport_abi_version() -> u32 {
    ABI_VERSION
}
