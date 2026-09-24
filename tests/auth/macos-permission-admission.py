#!/usr/bin/env python3
"""Actual Host runtime, synthetic permission denial; no TCC, capture or input."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location("fixture", root / "tests/auth/macos-https-auth.py")
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    for denial in ("screen-denied", "input-denied"):
        with tempfile.TemporaryDirectory(prefix="plank-permission-admission-") as directory:
            cert = fixture.create_identity(directory, root / "probes/macos/https-cert.cnf")
            with subprocess.Popen([args.server, directory, denial], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True) as server:
                try:
                    line = server.stdout.readline()  # server itself has a 65s alarm
                    match = re.search(r"macos_https_auth_ready port=(\d+)", line)
                    assert match, line
                    port = int(match[1])
                    token, topology = fixture.authenticate(cert, port, "synthetic", "test")
                    capture = topology["capture"]
                    requests = {
                        "/plank/display": {"schema_version": 3, "width": 1920, "height": 1080, "scale": 1,
                            "encoding_mode": "hevc-10-420-videotoolbox"},
                        "/plank/launch": {"schema_version": 6, "clipboard": False, "microphone": False, "camera": False, "capture_generation": topology["generation"],
                            "capture_id": capture["id"], "width": capture["width"], "height": capture["height"],
                            "encoding_mode": "hevc-10-420-videotoolbox", "frame_rate": 60,
                            "bitrate_kbps": 50000, "max_udp_payload_size": 1200}}
                    for path, body in requests.items():
                        # Exceed the 16-token limit twice without waiting for
                        # expiry. Each failed setup must release only its token.
                        for _ in range(32):
                            token, current = fixture.authenticate(cert, port, "synthetic", "test")
                            assert current == topology  # failed preparation never mutates display
                            for bearer, expected in (("x" * 44, 401), (token, 403), (token, 401)):
                                encoded = json.dumps(body).encode()
                                raw = (f"POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                                       f"Authorization: Bearer {bearer}\r\nContent-Length: {len(encoded)}\r\n\r\n").encode() + encoded
                                status, reply = fixture.request(cert, port, {}, raw=raw)
                                assert status == expected, (denial, path, status)
                                if expected == 403:
                                    assert reply == {"state": "denied", "error": "host_permissions_required"}
                                else:
                                    assert "error" not in reply
                    print(f"{denial}: 64 failed setups released, replay denied, topology unchanged; pass")
                finally:
                    server.terminate()
                    server.wait(timeout=10)


if __name__ == "__main__":
    main()
