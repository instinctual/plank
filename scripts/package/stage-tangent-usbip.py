#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Stage pinned signed VHCI bytes and complete corresponding source, at build time."""
import argparse
import hashlib
import json
import lzma
from pathlib import Path
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / "packaging/host/linux/usbip/inputs.json"
MAX_ARCHIVE = 1024 * 1024


def verify(data, expected, name):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("checksum mismatch for " + name)


def fetch(cache, entry):
    destination = cache / entry["name"]
    if destination.exists():
        if destination.stat().st_size > MAX_ARCHIVE:
            raise ValueError("cached driver archive exceeds its size bound")
        data = destination.read_bytes()
        verify(data, entry["sha256"], entry["name"])
        return destination
    with urllib.request.urlopen(entry["url"], timeout=30) as response:
        data = response.read(MAX_ARCHIVE + 1)
    if len(data) > MAX_ARCHIVE:
        raise ValueError("driver archive exceeds the reviewed size bound")
    verify(data, entry["sha256"], entry["name"])
    temporary = destination.with_suffix(destination.suffix + ".part")
    temporary.write_bytes(data)
    temporary.replace(destination)
    return destination


def verify_cache(cache, pin):
    for name in ("binary", "source"):
        entry = pin[name]
        path = cache / entry["name"]
        if path.stat().st_size > MAX_ARCHIVE:
            raise ValueError("cached driver archive exceeds its size bound")
        verify(path.read_bytes(), entry["sha256"], entry["name"])


def member(archive, name):
    # Archives have already passed their pinned digest. Extract exactly one
    # member to stdout; cpio never gets to create paths or symlinks on disk.
    payload = subprocess.check_output(["rpm2cpio", str(archive)])
    result = subprocess.run(["cpio", "-i", "--quiet", "--to-stdout", name],
                            input=payload, capture_output=True, check=True)
    if not result.stdout:
        raise ValueError("missing driver archive member: " + name)
    return result.stdout


def install_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(0o644)


def verify_payload(payload, pin):
    module = (payload / "usr/lib/modules" / pin["kernel_abi"] /
              "extra/plank/vhci-hcd.ko.xz")
    # RPM's generic ELF stripping must not invalidate the embedded signature.
    # Compression is lossless and kmod loads the original signed bytes.
    verify(lzma.decompress(module.read_bytes()), pin["module"]["sha256"],
           "packaged signed VHCI module")
    source = payload / "usr/share/doc/plank-host/usbip/corresponding-source.src.rpm"
    verify(source.read_bytes(), pin["source"]["sha256"], "packaged corresponding source")
    if not (payload / "usr/share/licenses/plank-host/LICENSE-USBIP-GPLv2").is_file():
        raise ValueError("packaged USB/IP license is missing")


def stage(payload, cache, pin):
    if payload.resolve() == Path("/"):
        raise ValueError("refusing to stage into the running system")
    cache.mkdir(parents=True, exist_ok=True)
    binary = fetch(cache, pin["binary"])
    source = fetch(cache, pin["source"])
    module = member(binary, pin["module"]["member"])
    verify(module, pin["module"]["sha256"], "vhci-hcd.ko")
    module_path = (payload / "usr/lib/modules" / pin["kernel_abi"] /
                   "extra/plank/vhci-hcd.ko.xz")
    install_bytes(module_path, lzma.compress(module, check=lzma.CHECK_CRC32))
    license_path = payload / "usr/share/licenses/plank-host/LICENSE-USBIP-GPLv2"
    install_bytes(license_path, member(source, "GPL-v2.0.txt"))
    doc = payload / "usr/share/doc/plank-host/usbip"
    install_bytes(doc / "corresponding-source.src.rpm", source.read_bytes())
    install_bytes(doc / "inputs.json", json.dumps(pin, indent=2).encode() + b"\n")
    install_bytes(doc / "README.md", (PIN.parent / "README.md").read_bytes())
    # Independently read back the staged payload, not just the download cache.
    verify_payload(payload, pin)
    return module_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--payload", type=Path)
    mode.add_argument("--prepare", action="store_true")
    mode.add_argument("--verify-cache", action="store_true")
    mode.add_argument("--verify-payload", type=Path)
    mode.add_argument("--kernel-abi", action="store_true")
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args()
    pin = json.loads(PIN.read_text())
    if args.kernel_abi:
        print(pin["kernel_abi"])
        return
    if args.verify_payload:
        verify_payload(args.verify_payload, pin)
        print("tangent_usbip_finished_payload=pass")
        return
    if args.cache is None:
        parser.error("--cache is required for driver inputs")
    for tool in ("rpm2cpio", "cpio"):
        if not shutil.which(tool):
            parser.error("missing build tool: " + tool)
    if args.prepare:
        args.cache.mkdir(parents=True, exist_ok=True)
        for name in ("binary", "source"):
            fetch(args.cache, pin[name])
        verify_cache(args.cache, pin)
        print("tangent_usbip_inputs=pass")
        return
    if args.verify_cache:
        verify_cache(args.cache, pin)
        print("tangent_usbip_input_hashes=pass")
        return
    stage(args.payload, args.cache, pin)
    print("tangent_usbip_payload_and_corresponding_source=pass")


if __name__ == "__main__":
    main()
