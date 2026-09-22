#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
helper=${repo_dir}/packaging/host/linux/bin/plank-host-certificate
test_directory=$(mktemp -d --tmpdir plank-host-certificate.XXXXXX)
cleanup() {
  rm -rf -- "$test_directory"
}
trap cleanup EXIT

certificate=${test_directory}/cert.pem
private_key=${test_directory}/key.pem
"$helper" "$certificate" "$private_key" hardware-test-host.test >/dev/null

openssl verify -CAfile "$certificate" "$certificate" | grep -Fq ': OK'
openssl x509 -in "$certificate" -noout -checkend 0 >/dev/null
certificate_text=$(openssl x509 -in "$certificate" -noout -text)
grep -Fq 'Public Key Algorithm: rsaEncryption' <<<"$certificate_text"
grep -Fq 'Public-Key: (3072 bit)' <<<"$certificate_text"
certificate_sans=$(openssl x509 -in "$certificate" -noout -ext subjectAltName)
grep -Fq 'DNS:hardware-test-host.test' <<<"$certificate_sans"
if grep -Fq 'IP Address:' <<<"$certificate_sans"; then
  echo 'generated certificate unexpectedly contains an IP SAN' >&2
  exit 1
fi

first_fingerprint=$(openssl x509 -in "$certificate" -noout -fingerprint -sha256)
first_key=$(openssl pkey -in "$private_key" -pubout -outform DER | openssl dgst -sha256)
"$helper" "$certificate" "$private_key" another-name.test |
  grep -Fxq 'host_certificate=valid'
second_fingerprint=$(openssl x509 -in "$certificate" -noout -fingerprint -sha256)
[[ $first_fingerprint == "$second_fingerprint" ]]

printf 'invalid certificate\n' >"$certificate"
"$helper" "$certificate" "$private_key" hardware-test-host.test |
  grep -Fq 'host_certificate=generated'
openssl x509 -in "$certificate" -noout -ext subjectAltName |
  grep -Fq 'DNS:hardware-test-host.test'
[[ $first_key == "$(openssl pkey -in "$private_key" -pubout -outform DER | openssl dgst -sha256)" ]]
# Renewal inside the thirty-day window is automatic and retains the key.
openssl req -x509 -key "$private_key" -days 1 -subj /CN=expiring \
  -addext subjectAltName=DNS:hardware-test-host.test -out "$certificate"
"$helper" "$certificate" "$private_key" hardware-test-host.test >/dev/null
openssl x509 -in "$certificate" -noout -checkend 2592000 >/dev/null
[[ $first_key == "$(openssl pkey -in "$private_key" -pubout -outform DER | openssl dgst -sha256)" ]]

printf 'damaged key\n' >"$private_key"
if "$helper" "$certificate" "$private_key" hardware-test-host.test >/dev/null 2>&1; then
  echo 'certificate helper replaced an existing damaged identity' >&2
  exit 1
fi
[[ $(<"$private_key") == 'damaged key' ]]

if "$helper" "$certificate" "$private_key" 127.0.0.1 >/dev/null 2>&1; then
  echo 'certificate helper accepted an IP address as a DNS name' >&2
  exit 1
fi
