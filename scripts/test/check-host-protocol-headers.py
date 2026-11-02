#!/usr/bin/env python3
"""Keep the Linux Host's protocol dependency declaration-only."""
import argparse
from pathlib import Path
import re

HEADERS = {"Limelight.h", "plank.h"}


def validate(root):
    root = Path(root)
    for retired in (".gitmodules", "enet", "nanors"):
        if (root / retired).exists():
            raise ValueError("retired Host protocol dependency: " + retired)
    source = root / "src"
    if not source.is_dir() or {p.name for p in source.iterdir()} != HEADERS:
        raise ValueError("Host protocol tree must contain only the two qualified headers")
    if not (root / "LICENSE.txt").is_file():
        raise ValueError("Host protocol license is missing")
    for header in HEADERS:
        text = (source / header).read_text()
        if re.search(r"\benet\b|\benet_\w*|\bLiGetEstimatedRttInfo\b", text, re.I):
            raise ValueError("retired ENet declaration in " + header)
    cmake = (root / "CMakeLists.txt").read_text()
    if not re.search(r"add_library\(plank_host_protocol\s+INTERFACE\)", cmake):
        raise ValueError("Host protocol CMake target must remain header-only")
    if re.search(r"\benet\b|nanors|add_subdirectory|target_link_libraries|aux_source_directory", cmake, re.I):
        raise ValueError("retired Host protocol library build dependency")
    for path in root.rglob("*"):
        if ".git" in path.relative_to(root).parts:
            continue
        if path.is_file() and path.suffix.lower() in {".c", ".cc", ".cpp", ".cxx"}:
            raise ValueError("Host protocol dependency must not contain compiled implementation")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("protocol_root", type=Path)
    args = parser.parse_args()
    try:
        validate(args.protocol_root)
    except (OSError, ValueError) as exc:
        parser.exit(1, str(exc) + "\n")
    print("host_protocol_headers_only_gate=pass")
