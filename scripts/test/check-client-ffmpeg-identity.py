#!/usr/bin/env python3
"""Reject identity-GBR patches placed outside HEVC hardware format selection."""
import pathlib
import re
import sys


def check(source: str) -> None:
    # Bound the check to this function: FFmpeg also has a pixel-format switch
    # in map_to_alpha_format(), which cannot enable a hardware decoder.
    match = re.search(r"static enum AVPixelFormat get_format\([^)]*\)\s*\{", source)
    if not match:
        raise ValueError("HEVC get_format() is missing")
    start = match.end()
    depth = 1
    end = start
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth:
        raise ValueError("HEVC get_format() is incomplete")
    body = source[start:end - 1]
    for rgb, yuv in (("GBRP", "YUV444P"), ("GBRP10", "YUV444P10")):
        aliases = rf"case AV_PIX_FMT_{rgb}:\s*case AV_PIX_FMT_{yuv}:"
        if not re.search(aliases, body):
            raise ValueError(f"HEVC get_format() does not offer the {rgb} hardware aliases")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: check-client-ffmpeg-identity.py HEVCDEC_SOURCE")
    try:
        check(pathlib.Path(sys.argv[1]).read_text())
    except (OSError, ValueError) as error:
        sys.exit(str(error))
    print("client_ffmpeg_identity_format_selection_gate=pass")
