#!/usr/bin/env python3
"""Extract the production qualification access units, not substitute videos."""
import argparse
import hashlib
import pathlib
import re

parser = argparse.ArgumentParser()
parser.add_argument("client", type=pathlib.Path)
parser.add_argument("output", type=pathlib.Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
video = args.client / "app/streaming/video"
for filename in ("ffmpeg-testframes.h", "applevideo-test-frame.h"):
    source = (video / filename).read_text()
    for name, body in re.findall(r"\b(k_\w+TestFrame)\[[^]]*\]\s*=\s*\{(.*?)\};", source, re.S):
        if "AV1" in name:
            continue
        data = bytes(int(byte, 16) for byte in re.findall(r"0x([0-9a-fA-F]{2})\b", body))
        assert data.startswith(b"\0\0\0\1"), name
        path = args.output / (name + (".hevc" if "HEVC" in name else ".h264"))
        path.write_bytes(data)
        print(hashlib.sha256(data).hexdigest(), len(data), path.name)
