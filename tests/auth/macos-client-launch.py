#!/usr/bin/env python3
"""Actual Qt Client launch over TLS 1.3; synthetic loopback server, no desktop."""
import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import secrets
import ssl
import sys
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", required=True)
    parser.add_argument("--topology", required=True)
    parser.add_argument("--certificate-config", required=True)
    args = parser.parse_args()
    topology = json.loads(Path(args.topology).read_text())
    modes = ("success", "wrong-pin", "certificate-swap", "redirect", "denied", "permissions",
             "oversized", "malformed", "wrong-port", "audio", "timeout", "auth-busy")
    with tempfile.TemporaryDirectory(prefix="plank-client-launch-") as directory:
        root = Path(directory)
        for number in (1, 2):
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes",
                            "-days", "1", "-config", args.certificate_config,
                            "-keyout", str(root / f"key{number}.pem"),
                            "-out", str(root / f"cert{number}.pem")],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for mode in modes:
            token = secrets.token_urlsafe(32)
            requests = []
            faults = []
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
            context.load_cert_chain(root / "cert1.pem", root / "key1.pem")

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *_):
                    pass

                def respond(self, status, data, **headers):
                    try:
                        self.send_response(status)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(data)))
                        self.send_header("Connection", "close")
                        for key, value in headers.items():
                            self.send_header(key, value)
                        self.end_headers()
                        self.wfile.write(data)
                    except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                        pass  # Expected when the Client rejects/stops the reply.
                    self.close_connection = True

                def do_GET(self):
                    if mode == "auth-busy" and self.path.startswith("/serverinfo"):
                        if self.headers.get("Authorization"):
                            faults.append("credentials in trust preflight")
                        requests.append("discovery")
                        self.respond(200, b'<root status_code="200"/>')
                        return
                    if (self.path != "/plank/topology" or
                            self.headers.get("Authorization") != "Bearer " + token):
                        faults.append("unexpected topology request")
                        self.respond(403, b"{}")
                        return
                    requests.append("topology")
                    if mode == "certificate-swap":
                        context.load_cert_chain(root / "cert2.pem", root / "key2.pem")
                    self.respond(200, json.dumps(topology).encode())

                def do_POST(self):
                    if mode == "auth-busy":
                        requests.append("auth")
                        if self.path != "/plank/auth/start" or self.headers.get("Authorization"):
                            faults.append("unexpected authentication request")
                        self.rfile.read(int(self.headers.get("Content-Length", "0")))
                        self.respond(200, b'{"state":"busy"}')
                        return
                    requests.append("launch")
                    if self.path != "/plank/launch" or self.headers.get("Authorization") != "Bearer " + token:
                        faults.append("unexpected launch target or authorization")
                    body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                    expected = {"schema_version": 3, "capture_generation": topology["generation"],
                                "capture_id": topology["capture"]["id"], "width": topology["capture"]["width"],
                                "height": topology["capture"]["height"], "encoding_mode": "hevc-10-420-videotoolbox",
                                "frame_rate": 60, "bitrate_kbps": 50000, "max_udp_payload_size": 1200,
                                "clipboard": sys.platform == "darwin"}
                    if body != expected:
                        faults.append("launch tuple mismatch")
                    if mode == "redirect":
                        self.respond(307, b"{}", Location="https://127.0.0.1:1/must-not-follow")
                        return
                    if mode == "denied":
                        self.respond(403, b'{"message":"do-not-log-this-response"}')
                        return
                    if mode == "permissions":
                        self.respond(403, b'{"state":"denied","error":"host_permissions_required"}')
                        return
                    if mode == "timeout":
                        time.sleep(6)
                    if mode in ("oversized", "malformed"):
                        self.respond(200, b"x" * (40000 if mode == "oversized" else 1))
                        return
                    response = {"schema_version": 3, "state": "connecting",
                                "udp_port": self.server.server_port,
                                "max_udp_payload_size": 1200, "capture": topology["capture"],
                                "transport_token": base64.b64encode(b"x" * 32).decode(),
                                "services": {"audio": True, "input": True, "pen": "normalized", "cursor": "embedded", "clipboard": False}}
                    if mode == "wrong-port":
                        response["udp_port"] = 1
                    if mode == "audio":
                        response["services"]["audio"] = False
                    self.respond(200, json.dumps(response).encode())

            server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            worker = threading.Thread(target=server.serve_forever)
            worker.start()
            try:
                result = subprocess.run([args.client, mode, str(server.server_port)],
                                        input=json.dumps({"token": token, "certificate": (root / "cert1.pem").read_text()}), text=True,
                                        env={**os.environ, "XDG_DATA_HOME": str(root / mode)},
                                        capture_output=True, timeout=12)
                if token in result.stdout + result.stderr or "do-not-log-this-response" in result.stdout + result.stderr:
                    raise RuntimeError(f"{mode}: sensitive response reached diagnostics")
                if result.returncode:
                    raise RuntimeError(f"{mode}: Client qualification failed ({result.returncode}): {result.stderr}")
                expected_requests = ["discovery", "auth"] if mode == "auth-busy" else ["topology"] if mode in ("wrong-pin", "certificate-swap") else ["topology", "launch"]
                if requests != expected_requests or faults:
                    raise RuntimeError(f"{mode}: incorrect HTTP request sequence")
                print(f"{mode}: pass", flush=True)
            finally:
                server.shutdown()
                worker.join()
                server.server_close()
    print(f"macos_client_https_launch: {len(modes)} scenarios passed")


if __name__ == "__main__":
    main()
