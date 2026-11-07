#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

case ${1:-} in
  '') performance=1 ;;
  --functional-only) performance=0 ;;
  *) echo 'Usage: run-plank-transport-native-loopback.sh [--functional-only]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || exit 2

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
crate_dir="$repo_root/protocol/plank-transport"
test_tmp=$(mktemp -d /tmp/plank-native-kyproto.XXXXXX)
trap 'rm -rf -- "$test_tmp"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -config "$repo_root/probes/macos/loopback-cert.cnf" \
  -keyout "$test_tmp/key.pem" \
  -out "$test_tmp/cert.pem" >/dev/null 2>&1
openssl x509 -in "$test_tmp/cert.pem" -outform DER -out "$test_tmp/cert.der"

export SC_NATIVE_TEST_CERTIFICATE="$test_tmp/cert.pem"
export SC_NATIVE_TEST_PRIVATE_KEY="$test_tmp/key.pem"
SC_NATIVE_TEST_CERTIFICATE_SHA256=$(openssl dgst -sha256 "$test_tmp/cert.der")
export SC_NATIVE_TEST_CERTIFICATE_SHA256=${SC_NATIVE_TEST_CERTIFICATE_SHA256##* }

cc -std=c11 -O2 -Wall -Wextra -Werror -I"$crate_dir/include" \
  "$repo_root/tests/protocol/camera-v1.c" -o "$test_tmp/camera-wire"
"$test_tmp/camera-wire" "$repo_root/tests/protocol/camera-v1.hex"
cc -std=c11 -O2 -Wall -Wextra -Werror -I"$crate_dir/include" \
  "$repo_root/tests/protocol/camera-v2.c" -o "$test_tmp/camera-encoded-wire"
"$test_tmp/camera-encoded-wire" "$repo_root/tests/protocol/camera-v2.hex"

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

if [[ ${SC_NATIVE_CARGO_PROFILE:-release} == release ]]; then
  bash "$repo_root/scripts/test/run-source-first-fec.sh" "${CARGO_TARGET_DIR:-$crate_dir/target}"
fi

# Exact test filters must execute a test, not report success with zero matches.
run_ignored() {
  cargo test "${cargo_profile_args[@]}" --locked --offline --manifest-path "$crate_dir/Cargo.toml" \
    "$1" -- --ignored --exact --nocapture | tee "$test_tmp/result.log"
  grep -q 'test result: ok. 1 passed;' "$test_tmp/result.log" || {
    echo "Required integration test did not run: $1" >&2
    return 1
  }
}

run_ignored native::version_tests::incompatible_peers_fail_tls_before_setup_or_media
run_ignored native::tests::native_kyproto_round_trip_preserves_all_initial_lanes
run_ignored native_ffi::data_tests::reliable_data_backpressure_recovers_both_receivers
run_ignored native_ffi::cancellation_tests::cancellation_interrupts_real_auth_endpoints_and_certificate_approval
run_ignored native_ffi::microphone_lane::tests::encrypted_ffi_microphone_mute_reopen_and_bounds
run_ignored native_ffi::camera_lane::tests::encrypted_camera_with_and_without_microphone
run_ignored native_ffi::camera_lane::tests::encrypted_version_mismatch_disables_only_camera

# Three required passes, not retries: set -e stops on the first failure.
if [[ $performance == 1 ]]; then
  for loss_trial in 1 2 3; do
    echo "native_loss_matrix_trial=$loss_trial"
    run_ignored native::tests::native_raptorq_survives_progressive_transport_loss_at_150_mbps
  done
fi
