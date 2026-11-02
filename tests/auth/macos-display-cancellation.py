#!/usr/bin/env python3
"""Cancel the actual runtime during a gated display change; no OS display or credentials."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--server', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('fixture', root/'tests/auth/macos-https-auth.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
with tempfile.TemporaryDirectory(prefix='plank-display-cancel-') as directory:
    cert = fixture.create_identity(directory, root/'probes/macos/https-cert.cnf')
    with subprocess.Popen([args.server, directory], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env={**os.environ, 'PLANK_TEST_DISPLAY_TRANSACTION':'cancel'}, text=True) as server:
        try:
            line = server.stdout.readline()
            port = int(re.search(r'macos_https_auth_ready port=(\d+)', line)[1])
            token, _ = fixture.authenticate(cert, port, 'synthetic', 'test')
            body = json.dumps({'schema_version':3, 'width':3840, 'height':2160,
                               'scale':1, 'encoding_mode':'hevc-10-420-videotoolbox'}).encode()
            raw = (f'POST /plank/display HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n'
                   f'Authorization: Bearer {token}\r\nContent-Length: {len(body)}\r\n\r\n').encode()+body
            def blocked_prepare():
                try:
                    return fixture.request(cert, port, {}, raw=raw)
                except (AssertionError, OSError):
                    return None  # Cancellation may close HTTP before sending its failure.
            with ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(blocked_prepare)
                deadline = time.monotonic()+5
                while not Path(directory, 'display-entered').exists():
                    assert time.monotonic() < deadline, 'preparation could not acquire runtime lock concurrently'
                    time.sleep(.01)
                started = time.monotonic()
                server.terminate()
                output, errors = server.communicate(timeout=5)
                assert server.returncode == 0, errors
                assert 'display_cancelled_without_lock_wait=1' in output
                assert 'macos_display_released' in output
                assert 'macos_host_runtime_drained=1' in output
                assert 'display_lock_held_during_restore' not in output
                result = pending.result(timeout=8)
                assert result is None or result[0] != 200, result
                print(f'display_cancel_restore_and_shutdown=PASS elapsed={time.monotonic()-started:.2f}s actual_runtime=1')
        finally:
            if server.poll() is None:
                server.terminate()
                server.wait(timeout=10)
