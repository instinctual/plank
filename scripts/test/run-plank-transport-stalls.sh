#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
umask 077
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_tmp=$(mktemp -d /tmp/plank-transport-stalls.XXXXXX)
trap 'rm -rf -- "$test_tmp"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost' \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -keyout "$test_tmp/key.pem" -out "$test_tmp/cert.pem" >/dev/null 2>&1
export SC_NATIVE_TEST_CERTIFICATE="$test_tmp/cert.pem"
export SC_NATIVE_TEST_PRIVATE_KEY="$test_tmp/key.pem"
cargo test --release --locked --offline \
  --manifest-path "$repo_root/protocol/plank-transport/Cargo.toml" \
  --features quinn-telemetry \
  native::transport_stalls::bounded_window_survives_ack_holds_and_recovers_from_stalls \
  -- --ignored --exact --nocapture
