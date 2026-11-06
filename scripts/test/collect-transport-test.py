#!/usr/bin/env python3
"""Export only the isolated native test executable and public provenance.

Run on a credential-free hosted builder. Never collect Cargo/signing directories,
runtime certificates, or product installation payloads.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
directory = root / "build/transport-qualification"
artifacts = [json.loads(line) for line in (directory / "compiler.jsonl").read_text().splitlines()]
executables = [Path(row["executable"]) for row in artifacts
               if row.get("reason") == "compiler-artifact"
               and row.get("target", {}).get("name") == "plank_transport"
               and row.get("profile", {}).get("test") and row.get("executable")]
if len(executables) != 1 or not executables[0].is_file():
    raise SystemExit("Expected exactly one native transport test executable")
source = executables[0].resolve()
if not source.is_relative_to((root / "protocol/plank-transport/target").resolve()):
    raise SystemExit("Transport test executable is outside its expected build tree")
destination = directory / "export"
destination.mkdir(parents=True, exist_ok=True)
binary = destination / "plank-transport-test"
shutil.copyfile(source, binary)
binary.chmod(0o755)
metadata = {
    "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "kymux_commit": subprocess.check_output(["git", "rev-parse", "HEAD:third_party/kyber-kymux"], cwd=root, text=True).strip(),
    "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "role": "loopback qualification only; not an installable Host or Client",
    "features": ["sender-timing"],
    "deployment_target": "26.7",
}
(destination / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
