#!/usr/bin/env python3
"""Exercise the temporary recorder without a GPU or any real desktop content."""
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import tempfile

probe, recorder = map(lambda p: str(Path(p).resolve()), sys.argv[1:])
cflags = shlex.split(subprocess.check_output(
    ["pkg-config", "--cflags", "libavcodec"], text=True))

with tempfile.TemporaryDirectory(prefix="plank-record-test-") as temporary:
    root = Path(temporary)
    stub = root / "stub.c"
    stub.write_text("""
#include <libavcodec/avcodec.h>
int avcodec_send_packet(AVCodecContext *c, const AVPacket *p)
{ (void)c; return p ? p->stream_index : 0; }
void avcodec_free_context(AVCodecContext **c) { *c = 0; }
""")
    main = root / "main.c"
    main.write_text("""
#include <assert.h>
#include <libavcodec/avcodec.h>
int main(void) {
    AVCodecContext context = {0}; AVCodecContext *p = &context;
    AVPacket packet = {0}; unsigned char data[] = {1, 2, 3};
    context.codec_type = AVMEDIA_TYPE_VIDEO; context.codec_id = AV_CODEC_ID_H264;
    packet.data = data; packet.size = 3; packet.flags = AV_PKT_FLAG_KEY;
    assert(avcodec_send_packet(p, &packet) == 0); /* H.264 is excluded. */
    context.codec_id = AV_CODEC_ID_HEVC;
    assert(avcodec_send_packet(p, &packet) == 0);
    packet.stream_index = -11;
    assert(avcodec_send_packet(p, &packet) == -11); /* Retry is not duplicated. */
    assert(avcodec_send_packet(p, 0) == 0); /* Flush has no payload. */
    avcodec_free_context(&p); assert(!p);
    p = &context; packet.stream_index = 0; packet.flags = 0; packet.size = 2;
    assert(avcodec_send_packet(p, &packet) == 0); /* Reused address, new file. */
    avcodec_free_context(&p);
    return 0;
}
""")
    subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                    *cflags, str(stub), "-o", str(root / "libstub.so")], check=True)
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", *cflags, str(main),
                    "-L" + temporary, "-lstub", "-Wl,-rpath," + temporary,
                    "-o", str(root / "exercise")], check=True)
    destination = root / "private"
    destination.mkdir(mode=0o700)
    env = dict(os.environ, LD_PRELOAD=recorder, PLANK_VIDEO_RECORD_DIR=str(destination))
    subprocess.run([str(root / "exercise")], env=env, check=True)
    files = sorted(destination.glob("*.pvr"))
    assert len(files) == 2
    for path, data, flags in zip(files, (b"\x01\x02\x03", b"\x01\x02"), (1, 0)):
        assert path.stat().st_mode & 0o777 == 0o600
        assert path.read_bytes() == b"PLANKV1\n" + struct.pack("<II", len(data), flags) + data
        result = subprocess.run([probe, "--inspect", str(path)], capture_output=True, text=True, check=True)
        assert "recording=1 packets=1" in result.stdout

    # A missing/private-policy-ineligible directory disables recording without
    # altering decoder return values. It must never create a shared capture.
    denied = root / "shared"
    denied.mkdir(mode=0o755)
    denied.chmod(0o755)
    env["PLANK_VIDEO_RECORD_DIR"] = str(denied)
    subprocess.run([str(root / "exercise")], env=env, check=True)
    assert not list(denied.iterdir())

    invalid = root / "invalid.pvr"
    for payload in (b"PLANKV1\n", b"PLANKV1\n\x01",
                    b"PLANKV1\n" + struct.pack("<II", 0, 0),
                    b"PLANKV1\n" + struct.pack("<II", 17 * 1024 * 1024, 0),
                    b"PLANKV1\n" + struct.pack("<II", 3, 0) + b"x"):
        invalid.write_bytes(payload)
        assert subprocess.run([probe, "--inspect", str(invalid)],
                              capture_output=True).returncode != 0
    with invalid.open("wb") as f:
        f.write(b"PLANKV1\n")
        f.truncate(4 * 1024**3 + 1)
    assert subprocess.run([probe, "--inspect", str(invalid)], capture_output=True).returncode != 0
print("video_recording_passthrough_and_bounds=pass")
