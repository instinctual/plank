#!/bin/bash
# Diagnostic comparison, never a replacement for the ordinary product gate.
set -euo pipefail
umask 077
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
binary="$root/build/transport-qualification/export/plank-transport-test"
test -x "$binary" || exit 0
scratch=$(mktemp -d)
trap 'rm -f -- "$scratch/key.pem" "$scratch/cert.pem" "$scratch/cert.der" "$scratch/buffer.dylib"; rmdir "$scratch"' EXIT
cc -dynamiclib -O2 -Wall -Wextra -Werror "$root/probes/network/plank-transport/macos-receive-buffer.c" -o "$scratch/buffer.dylib"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$root/probes/macos/loopback-cert.cnf" -keyout "$scratch/key.pem" -out "$scratch/cert.pem" >/dev/null 2>&1
openssl x509 -in "$scratch/cert.pem" -outform DER -out "$scratch/cert.der"
export SC_NATIVE_TEST_CERTIFICATE="$scratch/cert.pem"
export SC_NATIVE_TEST_PRIVATE_KEY="$scratch/key.pem"
fingerprint=$(openssl dgst -sha256 "$scratch/cert.der")
export SC_NATIVE_TEST_CERTIFICATE_SHA256=${fingerprint##* }
echo 'diagnostic_only=socket-buffer-comparison product_gate_unchanged=true'
for trial in 1 2 3; do
    echo "receive_buffer_comparison_trial=$trial"
    DYLD_INSERT_LIBRARIES="$scratch/buffer.dylib" "$binary" --ignored --exact native::tests::native_raptorq_survives_progressive_transport_loss_at_150_mbps --nocapture
done
