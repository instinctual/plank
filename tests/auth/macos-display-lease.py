#!/usr/bin/env python3
"""Actual Host auth/runtime with synthetic display provider; no OS display changes."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--server', required=True)
parser.add_argument('--receiver', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('fixture', root/'tests/auth/macos-https-auth.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
with tempfile.TemporaryDirectory(prefix='plank-display-lease-') as directory:
    cert = fixture.create_identity(directory, root/'probes/macos/https-cert.cnf')
    with subprocess.Popen([args.server, directory, 'display-lease'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True) as server:
        try:
            line = server.stdout.readline()
            port = int(re.search(r'macos_https_auth_ready port=(\d+)', line)[1])
            def post(value, token, path):
                body = json.dumps(value).encode()
                raw = (f'POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n'
                    f'Authorization: Bearer {token}\r\nContent-Length: {len(body)}\r\n\r\n').encode()+body
                return fixture.request(cert, port, {}, raw=raw)
            def prepare(width, height):
                token, _ = fixture.authenticate(cert, port, 'synthetic', 'test')
                return post({'schema_version':3, 'width':width, 'height':height,
                    'scale':1, 'encoding_mode':'hevc-10-420-videotoolbox'}, token, '/plank/display')
            status, reply = prepare(3840,2160)
            assert status == 200 and reply['capture']['width'] == 3840
            token, topology = fixture.authenticate(cert, port, 'synthetic', 'test')
            capture = topology['capture']
            status, stream = post({'schema_version':6, 'clipboard':False, 'microphone':False, 'camera':False,
                'capture_generation':topology['generation'], 'capture_id':capture['id'],
                'width':capture['width'], 'height':capture['height'], 'encoding_mode':'hevc-10-420-videotoolbox',
                'frame_rate':60, 'bitrate_kbps':50000, 'max_udp_payload_size':1200}, token, '/plank/launch')
            assert status == 200
            fingerprint = hashlib.sha256(Path(directory,'cert.der').read_bytes()).hexdigest()
            result = subprocess.run([args.receiver, fingerprint, '--no-media'], input=json.dumps(stream).encode(),
                capture_output=True, timeout=15)
            assert result.returncode == 0, 'synthetic receiver did not complete normal disconnect'
            deadline = time.monotonic()+3
            while True:
                _, restored = fixture.authenticate(cert, port, 'synthetic', 'test')
                if restored['capture']['width'] == 1920: break
                assert time.monotonic() < deadline, 'normal disconnect did not release prepared display'
                time.sleep(.05)
            # Valid wire request, rejected by the synthetic display provider.
            status, _ = prepare(100,100)
            assert status == 503
            _, topology = fixture.authenticate(cert, port, 'synthetic', 'test')
            assert topology['capture']['width'] == 1920
            status, reply = prepare(3840,2160)
            assert status == 200 and reply['capture']['width'] == 3840
            # Exercise the production 60s deadline; no accelerated test branch.
            time.sleep(60.3)
            _, topology = fixture.authenticate(cert, port, 'synthetic', 'test')
            assert topology['capture']['width'] == 1920
            print('display_lease_disconnect_failure_and_abandoned_prepare=PASS actual_runtime=1 real_quic=1 physical_display=0')
        finally:
            server.terminate()  # This test owns only this synthetic loopback child.
            server.wait(timeout=10)
