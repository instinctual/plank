#!/usr/bin/env python3
"""Actual Qt Client launch over TLS 1.3; synthetic loopback server, no desktop."""
import argparse
import base64
import copy
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
    vector = json.loads((Path(__file__).resolve().parents[1] /
                        "protocol/media-feature-negotiation-v1.json").read_text())
    modes = ("success", "wrong-pin", "certificate-swap", "redirect", "denied", "permissions",
             "oversized", "malformed", "wrong-port", "audio", "timeout", "auth-busy",
             "auth-first", "auth-recovery-known", "auth-recovery-unknown", "auth-changed",
             "auth-mid-change", "auth-replace-cancel", "auth-replace-accept",
             "legacy-4", "legacy-5", "legacy-6", "legacy-unknown", "legacy-pin-change",
             "negotiate-denied", "negotiate-incompatible", "negotiate-malformed",
             "negotiate-oversized", "negotiate-timeout", "negotiate-redirect",
             "negotiate-required", "negotiate-optional", "negotiate-profile")
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
                    if mode.startswith("legacy-") and self.path == "/serverinfo":
                        if self.headers.get("Authorization") != "Bearer " + token:
                            faults.append("invalid pinned server information authorization")
                        requests.append("version")
                        version = {"legacy-4": "1.0.156", "legacy-5": "1.1.002-native-media-investigation",
                                   "legacy-6": "1.1.003", "legacy-unknown": "1.0.155"}.get(mode, "1.0.156")
                        self.respond(200, ('<root status_code="200"><PlankHostVersion>' + version +
                                           '</PlankHostVersion></root>').encode())
                        return
                    if mode.startswith("auth-") and self.path.startswith("/serverinfo"):
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
                    if mode.startswith("auth-") and mode != "auth-busy":
                        if self.headers.get("Authorization"):
                            faults.append("bearer in new authentication")
                        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                        if self.path == "/plank/auth/start":
                            requests.append("auth")
                            if body != {"username": "synthetic"}:
                                faults.append("invalid authentication start")
                            if mode == "auth-mid-change":
                                context.load_cert_chain(root / "cert2.pem", root / "key2.pem")
                            self.respond(200, b'{"state":"challenge","conversation_id":"fixture","messages":[{"style":1}]}')
                        elif self.path == "/plank/auth/respond":
                            requests.append("password")
                            if body != {"conversation_id": "fixture", "responses": ["fixture-password"]}:
                                faults.append("invalid authentication response")
                            self.respond(200, json.dumps({"state": "authenticated", "session_token": token}).encode())
                        else:
                            faults.append("unexpected authentication path")
                            self.respond(403, b"{}")
                        return
                    if mode == "auth-busy":
                        requests.append("auth")
                        if self.path != "/plank/auth/start" or self.headers.get("Authorization"):
                            faults.append("unexpected authentication request")
                        self.rfile.read(int(self.headers.get("Content-Length", "0")))
                        self.respond(200, b'{"state":"busy"}')
                        return
                    if self.path == "/plank/negotiate":
                        requests.append("negotiate")
                        if self.headers.get("Authorization") != "Bearer " + token:
                            faults.append("invalid negotiation authorization")
                        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                        expected = copy.deepcopy(vector["offer"])
                        if sys.platform != "darwin":
                            expected["features"]["clipboard"] = []
                        if not sys.platform.startswith("linux"):
                            expected["features"]["camera"] = []
                        if body != expected:
                            faults.append("negotiation offer mismatch")
                        if mode.startswith("legacy-"):
                            if mode == "legacy-pin-change":
                                context.load_cert_chain(root / "cert2.pem", root / "key2.pem")
                            self.respond(404, b"{}")
                            return
                        if mode in ("negotiate-denied", "negotiate-incompatible", "negotiate-redirect"):
                            self.respond({"negotiate-denied": 403, "negotiate-incompatible": 426,
                                          "negotiate-redirect": 307}[mode],
                                         b'{"error":"protocol_incompatible"}',
                                         Location="https://127.0.0.1:1/must-not-follow")
                            return
                        if mode == "negotiate-timeout":
                            time.sleep(6)
                        if mode in ("negotiate-oversized", "negotiate-malformed"):
                            self.respond(200, b"x" * (40000 if mode == "negotiate-oversized" else 1))
                            return
                        response = copy.deepcopy(vector["response"])
                        for name, choices in expected["features"].items():
                            if not choices:
                                response["features"][name] = None
                        if mode == "negotiate-optional":
                            response["features"].pop("microphone")
                            response["features"]["future_optional"] = {"schema_version": 9}
                        if mode == "negotiate-required":
                            response["required_features"].append("future_required")
                        if mode == "negotiate-profile":
                            response["features"]["desktop"]["encoding_mode"] = "hevc-10-444-videotoolbox"
                        self.respond(200, json.dumps(response).encode())
                        return
                    requests.append("launch")
                    if self.path != "/plank/launch" or self.headers.get("Authorization") != "Bearer " + token:
                        faults.append("unexpected launch target or authorization")
                    body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                    expected = {"schema_version": 6, "capture_generation": topology["generation"],
                                "capture_id": topology["capture"]["id"], "width": topology["capture"]["width"],
                                "height": topology["capture"]["height"], "encoding_mode": "hevc-10-420-videotoolbox",
                                "frame_rate": 60, "bitrate_kbps": 50000, "max_udp_payload_size": 1200,
                                "clipboard": sys.platform == "darwin", "microphone": True, "camera": sys.platform.startswith("linux")}
                    schema = int(mode[-1]) if mode in ("legacy-4", "legacy-5", "legacy-6") else 7
                    if schema < 7:
                        expected["schema_version"] = schema
                        if schema < 6:
                            expected.pop("camera")
                        if schema == 4:
                            expected["microphone"] = False
                    else:
                        expected = copy.deepcopy(vector["launch"])
                        expected["capture_generation"] = topology["generation"]
                        expected["capture_id"] = topology["capture"]["id"]
                        desktop = expected["features"]["desktop"]
                        desktop.update(width=topology["capture"]["width"], height=topology["capture"]["height"], bitrate_kbps=50000)
                        if sys.platform != "darwin":
                            expected["features"]["clipboard"] = None
                        if not sys.platform.startswith("linux"):
                            expected["features"]["camera"] = None
                        if mode == "negotiate-optional":
                            expected["features"]["microphone"] = None
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
                    response = {"schema_version": schema, "state": "connecting",
                                "udp_port": self.server.server_port,
                                "max_udp_payload_size": 1200, "capture": topology["capture"],
                                "transport_token": base64.b64encode(b"x" * 32).decode(),
                                "services": {"audio": True, "input": True, "pen": "normalized", "cursor": "embedded", "clipboard": False, "microphone": False, "camera": False}}
                    if schema < 6:
                        response["services"].pop("camera")
                    if schema == 7:
                        response.pop("services")
                        response.update(transport=expected["transport"], required_features=expected["required_features"],
                                        features=copy.deepcopy(expected["features"]))
                        for name in ("clipboard", "microphone", "camera"):
                            response["features"][name] = None
                    if mode == "wrong-port":
                        response["udp_port"] = 1
                    if mode == "audio":
                        response["features"]["audio"] = None
                    self.respond(200, json.dumps(response).encode())

            server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            worker = threading.Thread(target=server.serve_forever)
            worker.start()
            try:
                prior = "cert2.pem" if mode in ("auth-changed", "auth-replace-cancel", "auth-replace-accept") else "cert1.pem"
                result = subprocess.run([args.client, mode, str(server.server_port)],
                                        input=json.dumps({"token": token, "certificate": (root / prior).read_text()}), text=True,
                                        env={**os.environ, "XDG_DATA_HOME": str(root / mode)},
                                        capture_output=True, timeout=12)
                if any(secret in result.stdout + result.stderr for secret in (token, "fixture-password", "do-not-log-this-response")):
                    raise RuntimeError(f"{mode}: sensitive response reached diagnostics")
                if result.returncode:
                    raise RuntimeError(f"{mode}: Client qualification failed ({result.returncode}): {result.stderr}")
                expected_requests = ["discovery", "auth"] if mode == "auth-busy" else ["topology"] if mode in ("wrong-pin", "certificate-swap") else ["topology", "negotiate", "launch"]
                if mode.startswith("legacy-"):
                    expected_requests = ["topology", "negotiate"]
                    if mode != "legacy-pin-change":
                        expected_requests.append("version")
                    if mode in ("legacy-4", "legacy-5", "legacy-6"):
                        expected_requests.append("launch")
                elif mode.startswith("negotiate-") and mode != "negotiate-optional":
                    expected_requests = ["topology", "negotiate"]
                if mode in ("auth-first", "auth-recovery-known", "auth-replace-accept"):
                    expected_requests = ["discovery", "auth", "password"]
                elif mode in ("auth-recovery-unknown", "auth-changed", "auth-replace-cancel"):
                    expected_requests = []
                elif mode == "auth-mid-change":
                    expected_requests = ["discovery", "auth"]
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
