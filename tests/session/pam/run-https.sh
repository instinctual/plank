#!/usr/bin/env bash
set -euo pipefail
test_identity=$(mktemp -d)
trap 'rm -f -- "$test_identity/key.pem" "$test_identity/cert.pem"; rmdir -- "$test_identity"' EXIT
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=auth-test.invalid -keyout "$test_identity/key.pem" \
  -out "$test_identity/cert.pem" >/dev/null 2>&1
PLANK_TEST_TLS_CERT="$test_identity/cert.pem" PLANK_TEST_TLS_KEY="$test_identity/key.pem" \
  "$1" --gtest_filter='AuthHttps.*'
