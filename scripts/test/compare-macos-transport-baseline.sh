#!/bin/bash
# Compare unchanged main production sources with the identical current harness.
# A diagnostic result never overrides a failing candidate qualification step.
set -euo pipefail
umask 077
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
baseline_commit=283dced79f30d9372c314b7178785f641ee96fdd
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/plank-fec-baseline.XXXXXX")
baseline="$scratch/source"
export CARGO_TARGET_DIR="$root/protocol/plank-transport/target"
git -C "$root" fetch --no-tags --recurse-submodules=no origin "$baseline_commit"
git -C "$root" worktree add --detach "$baseline" "$baseline_commit"
git -C "$baseline" -c protocol.file.allow=always \
    -c "submodule.third_party/kyber-kymux.url=$root/third_party/kyber-kymux" \
    submodule update --init third_party/kyber-kymux
python3 - "$root" "$baseline" <<'PY'
from pathlib import Path
import shutil, sys
current, baseline = map(Path, sys.argv[1:])
relative = Path('protocol/plank-transport/src')
name = 'native.rs'
# Changes before the first test module would invalidate the production control.
assert (current/relative/name).read_text().split('#[cfg(test)]', 1)[0] == (baseline/relative/name).read_text().split('#[cfg(test)]', 1)[0]
for name in ('native.rs', 'test_loss_proxy.rs', 'test_loss_performance.rs'):
    shutil.copyfile(current/relative/name, baseline/relative/name)
PY
export_dir="$root/build/transport-qualification/export/baseline"
mkdir -p "$export_dir"
git -C "$baseline" diff --binary > "$export_dir/test-only.patch"
cargo test --no-run --locked --offline --release --lib --manifest-path "$baseline/protocol/plank-transport/Cargo.toml" --features quinn-telemetry,macos-source-first --message-format=json-render-diagnostics > "$scratch/compiler.jsonl"
python3 - "$root" "$baseline" "$scratch/compiler.jsonl" "$export_dir" <<'PY'
from pathlib import Path
import hashlib, json, shutil, subprocess, sys
root, baseline, messages, destination = map(Path, sys.argv[1:])
rows = [json.loads(line) for line in messages.read_text().splitlines()]
binaries = [Path(row['executable']) for row in rows if row.get('reason') == 'compiler-artifact' and row.get('target', {}).get('name') == 'plank_transport' and row.get('profile', {}).get('test') and row.get('executable')]
assert len(binaries) == 1 and binaries[0].resolve().is_relative_to((root/'protocol/plank-transport/target').resolve())
binary = destination/'plank-transport-test'
shutil.copyfile(binaries[0], binary)
binary.chmod(0o755)
metadata = {
    'production_root': subprocess.check_output(['git','rev-parse','HEAD'],cwd=baseline,text=True).strip(),
    'kymux': subprocess.check_output(['git','rev-parse','HEAD:third_party/kyber-kymux'],cwd=baseline,text=True).strip(),
    'harness_root': subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    'test_patch_sha256': hashlib.sha256((destination/'test-only.patch').read_bytes()).hexdigest(),
    'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'role': 'unchanged production baseline; test-only patch; no installable package',
    'features': ['quinn-telemetry','macos-source-first'],
}
(destination/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
PY
trap 'rm -f -- "$scratch/key.pem" "$scratch/cert.pem" "$scratch/cert.der"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$root/probes/macos/loopback-cert.cnf" -keyout "$scratch/key.pem" -out "$scratch/cert.pem" >/dev/null 2>&1
openssl x509 -in "$scratch/cert.pem" -outform DER -out "$scratch/cert.der"
export SC_NATIVE_TEST_CERTIFICATE="$scratch/cert.pem"
export SC_NATIVE_TEST_PRIVATE_KEY="$scratch/key.pem"
fingerprint=$(openssl dgst -sha256 "$scratch/cert.der")
export SC_NATIVE_TEST_CERTIFICATE_SHA256=${fingerprint##* }
echo "diagnostic_only=unchanged-main-baseline production_root=$baseline_commit product_gate_unchanged=true"
for trial in 1 2 3; do
    echo "unchanged_macos_baseline_trial=$trial"
    "$export_dir/plank-transport-test" --ignored --exact native::tests::native_raptorq_survives_progressive_transport_loss_at_150_mbps --nocapture
done
