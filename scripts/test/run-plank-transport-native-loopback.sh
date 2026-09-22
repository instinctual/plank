#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
crate_dir="$repo_root/protocol/plank-transport"
test_tmp=$(mktemp -d /tmp/plank-native-kyproto.XXXXXX)
trap 'rm -rf -- "$test_tmp"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=localhost' \
  -keyout "$test_tmp/key.pem" \
  -out "$test_tmp/cert.pem" >/dev/null 2>&1
openssl x509 -in "$test_tmp/cert.pem" -outform DER -out "$test_tmp/cert.der"

export SC_NATIVE_TEST_CERTIFICATE="$test_tmp/cert.pem"
export SC_NATIVE_TEST_PRIVATE_KEY="$test_tmp/key.pem"
SC_NATIVE_TEST_CERTIFICATE_SHA256=$(sha256sum "$test_tmp/cert.der")
export SC_NATIVE_TEST_CERTIFICATE_SHA256=${SC_NATIVE_TEST_CERTIFICATE_SHA256%% *}

cargo_profile_args=()
# Performance qualification uses optimized product code. Explicit debug runs
# are still useful diagnostics, but are not release performance qualification.
case ${SC_NATIVE_CARGO_PROFILE:-release} in
  release) cargo_profile_args+=(--release) ;;
  debug) ;;
  *) echo "SC_NATIVE_CARGO_PROFILE must be release or debug" >&2; exit 2 ;;
esac
if [[ -n ${PLANK_TRANSPORT_CARGO_FEATURES:-} ]]; then
  cargo_profile_args+=(--features "$PLANK_TRANSPORT_CARGO_FEATURES")
fi

# Dependency tests are not included by an ordinary product cargo test. Run the
# actual audio/video FEC parsers and receiver state machines with our lockfile.
cargo test "${cargo_profile_args[@]}" --locked --offline --manifest-path "$crate_dir/Cargo.toml" \
  -p plank-transport -p kyproto --lib protocol::driver::av

cargo test "${cargo_profile_args[@]}" --locked --offline --manifest-path "$crate_dir/Cargo.toml" \
  native::version_tests::incompatible_peers_fail_tls_before_setup_or_media \
  -- --ignored --exact --nocapture

cargo test "${cargo_profile_args[@]}" --locked --offline --manifest-path "$crate_dir/Cargo.toml" \
  native::tests::native_kyproto_round_trip_preserves_all_initial_lanes \
  -- --ignored --exact --nocapture

cargo test "${cargo_profile_args[@]}" --locked --offline --manifest-path "$crate_dir/Cargo.toml" \
  native_ffi::data_tests::reliable_data_overflow_fails_both_receivers \
  -- --ignored --exact --nocapture

cargo test "${cargo_profile_args[@]}" --locked --offline --manifest-path "$crate_dir/Cargo.toml" \
  native_ffi::cancellation_tests::cancellation_interrupts_real_auth_endpoints_and_promotion \
  -- --ignored --exact --nocapture

# Three required passes, not retries: set -e stops on the first failure.
for loss_trial in 1 2 3; do
  echo "native_loss_matrix_trial=$loss_trial"
  cargo test "${cargo_profile_args[@]}" --locked --offline --manifest-path "$crate_dir/Cargo.toml" \
    native::tests::native_raptorq_survives_progressive_transport_loss_at_150_mbps \
    -- --ignored --exact --nocapture
done
