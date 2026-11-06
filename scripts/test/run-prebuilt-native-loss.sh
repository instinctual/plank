#!/bin/bash
# Run the strict performance gate on qualified hardware, without compiling there.
set -euo pipefail
umask 077
[[ $# == 2 && -x $1 && -f $2 ]] || {
    echo 'Usage: run-prebuilt-native-loss.sh /absolute/test-executable /absolute/loopback-cert.cnf' >&2
    exit 2
}
binary=$1
configuration=$2
test_name=native::tests::native_raptorq_survives_progressive_transport_loss_at_150_mbps
"$binary" --list | grep -Fx -- "$test_name: test" >/dev/null
scratch=$(mktemp -d /tmp/plank-native-loss.XXXXXX)
trap 'rm -f -- "$scratch/key.pem" "$scratch/cert.pem" "$scratch/cert.der"; rmdir "$scratch"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$configuration" -keyout "$scratch/key.pem" -out "$scratch/cert.pem" >/dev/null 2>&1
openssl x509 -in "$scratch/cert.pem" -outform DER -out "$scratch/cert.der"
export SC_NATIVE_TEST_CERTIFICATE="$scratch/cert.pem"
export SC_NATIVE_TEST_PRIVATE_KEY="$scratch/key.pem"
fingerprint=$(openssl dgst -sha256 "$scratch/cert.der")
export SC_NATIVE_TEST_CERTIFICATE_SHA256=${fingerprint##* }
for trial in 1 2 3; do
    echo "native_loss_matrix_trial=$trial"
    "$binary" --ignored --exact "$test_name" --nocapture
done
