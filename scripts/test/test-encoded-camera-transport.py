#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""C/Rust PCAM schemas plus authenticated optional-lane component tests.

Creates local test credentials only. Opens no camera or product session.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--encoded-records", type=Path)
parser.add_argument("--received-payload", type=Path)
args = parser.parse_args()
if bool(args.encoded_records) != bool(args.received_payload):
    parser.error("Pass both generated encoded records and received payload paths")
root = Path(__file__).resolve().parents[2]
report = {"passed": False, "physicalCameraUsed": False, "productSessionUsed": False, "tests": {}}
args.output.parent.mkdir(parents=True, exist_ok=True)
try:
    with tempfile.TemporaryDirectory(prefix="plank-camera-contract-") as temp:
        temp = Path(temp)
        for version in (1, 2):
            subprocess.run([shutil.which("cc"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                "-I" + str(root / "protocol/plank-transport/include"), str(root / f"tests/protocol/camera-v{version}.c"),
                "-o", str(temp / f"wire-{version}")], check=True)
            subprocess.run([str(temp / f"wire-{version}"), str(root / f"tests/protocol/camera-v{version}.hex")], check=True)
            report["tests"][f"sharedCVectorV{version}"] = True
        cargo = ["cargo", "test", "--locked", "--offline", "--manifest-path", str(root / "protocol/plank-transport/Cargo.toml"), "--lib"]
        subprocess.run(cargo + ["camera", "--", "--nocapture"], check=True)
        report["tests"]["rustWireAndBoundedQueues"] = True
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
            "-keyout", str(temp / "key.pem"), "-out", str(temp / "cert.pem")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "x509", "-in", str(temp / "cert.pem"), "-outform", "DER", "-out", str(temp / "cert.der")], check=True)
        env = dict(os.environ, SC_NATIVE_TEST_CERTIFICATE=str(temp / "cert.pem"), SC_NATIVE_TEST_PRIVATE_KEY=str(temp / "key.pem"),
            SC_NATIVE_TEST_CERTIFICATE_SHA256=hashlib.sha256((temp / "cert.der").read_bytes()).hexdigest())
        for name in ("encrypted_camera_with_and_without_microphone", "encrypted_version_mismatch_disables_only_camera"):
            subprocess.run(cargo + ["native_ffi::camera_lane::tests::" + name, "--", "--ignored", "--exact", "--nocapture"], env=env, check=True, timeout=60)
        if args.encoded_records:
            env["PLANK_TEST_CAMERA_RECORDS"] = str(args.encoded_records.resolve())
            env["PLANK_TEST_CAMERA_PAYLOAD"] = str(args.received_payload.resolve())
            subprocess.run(cargo + ["native_ffi::camera_lane::tests::encrypted_encoded_fixture_roundtrip", "--", "--ignored", "--exact", "--nocapture"], env=env, check=True, timeout=60)
            report["tests"]["ninetyMacHardwareEncodedFramesPreservedThroughTLS"] = True
        report["tests"]["encryptedV1V2DirectSetupMicActivationAndShortBuffer"] = True
        report["tests"]["versionMismatchDisablesCameraAndPreservesDataLane"] = True
        report["passed"] = True
except Exception as error:
    report["error"] = str(error)
    raise
finally:
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
