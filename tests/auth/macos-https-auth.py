#!/usr/bin/env python3
"""Loopback TLS/auth qualification. Synthetic credentials only by default."""
import argparse
from contextlib import contextmanager
import getpass
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import plistlib
import re
import select
import socket
import subprocess
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET


def context(certificate):
    # Xcode's Python links LibreSSL 2.8.3 without TLS 1.3. The OS openssl CLI
    # supports TLS 1.3. Trust only our generated self-signed loopback fixture;
    # there is no insecure/no-verify option and this is not the product client.
    return Path(certificate)


def tls_command(certificate, port, version="-tls1_3"):
    return ["openssl", "s_client", "-connect", f"127.0.0.1:{port}", "-servername", "localhost",
            "-CAfile", str(certificate), "-verify_return_error", "-verify", "1", version,
            "-alpn", "http/1.1", "-quiet"]


class ResponseBytes:
    def __init__(self, value):
        self.value = value

    def makefile(self, *args):
        return io.BytesIO(self.value)


def read_framed_reply(process, timeout=7):
    """Consume Content-Length like Qt, not EOF from openssl's terminal client."""
    deadline = time.monotonic() + timeout
    data = bytearray()
    total = None
    while total is None or len(data) < total:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([process.stdout], [], [], remaining)[0], "TLS response timed out"
        chunk = os.read(process.stdout.fileno(), 65536)
        assert chunk, "TLS response ended before its complete Content-Length body"
        data.extend(chunk)
        assert len(data) <= 65536, "oversized fixture reply"
        if total is None and b"\r\n\r\n" in data:
            head, _ = data.split(b"\r\n\r\n", 1)
            sizes = re.findall(rb"(?im)^Content-Length: ([0-9]+)\r?$", head)
            assert len(sizes) == 1 and int(sizes[0]) <= 60000
            total = len(head) + 4 + int(sizes[0])
    assert len(data) == total, "unexpected trailing response bytes"
    return bytes(data)


@contextmanager
def exchange(tls, port, message):
    # -quiet otherwise implies -ign_eof. Keep stdin OPEN until the entire
    # reply is read, then actively close TLS as the product HTTP client does.
    process = subprocess.Popen(tls_command(tls, port) + ["-no_ign_eof"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    try:
        process.stdin.write(message)
        process.stdin.flush()
        yield process, read_framed_reply(process)
    finally:
        if process.stdin:
            process.stdin.close()
            process.stdin = None
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=3)
            raise AssertionError("TLS client did not close after consuming its reply")


def request(tls, port, body, path="/plank/auth/start", raw=None, xml=False):
    encoded = json.dumps(body).encode()
    message = raw if raw is not None else (
        f"POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
        f"Content-Length: {len(encoded)}\r\n\r\n".encode() + encoded
    )
    with exchange(tls, port, message) as (process, response):
        pass
    assert process.returncode == 0, f"TLS request failed (exit {process.returncode})"
    reply = http.client.HTTPResponse(ResponseBytes(response))
    reply.begin()
    assert reply.getheader("Cache-Control") == "no-store"
    assert reply.getheader("Connection") == "close"
    content = reply.read()
    if xml:
        assert reply.getheader("Content-Type") == "application/xml; charset=utf-8"
        return reply.status, ET.fromstring(content)
    return reply.status, json.loads(content)


def discovery(tls, port):
    # Exact current Client request shape: no legacy identifiers or cache busters.
    target = "/serverinfo"
    raw = f"GET {target} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode()
    status, root = request(tls, port, {}, raw=raw, xml=True)
    assert status == 200 and root.tag == "root" and root.attrib == {"status_code": "200"}
    expected = {"hostname": "PLANK Mac qualification",
                "uniqueid": "f92140f5-8740-4b3b-82f7-74db5353de27",
                "HttpsPort": str(port), "PlankHostMetadataVersion": "1",
                "PlankHostVersion": "macos-host-qualification", "PlankAuth": "1",
                "ServerCodecModeSupport": "0", "PlankTopologyVersion": "0",
                "PlankFeatureFlags": "0", "PairStatus": "0", "PlankOccupied": "0"}
    assert len(root) == len(expected) and {node.tag: node.text for node in root} == expected
    # Discovery is public. Occupancy is a nameless bit only; it must not
    # expose an account, UID, or an alternative GET authentication path.
    for path in ["/plank/auth/start", "/plank/auth/respond", "/serverinfo?session_token=abc",
                 "/serverinfo?uuid=abc&uuid=def", "/serverinfo?uuid=%61",
                 "/serverinfo?uniqueid=0123456789ABCDEF", "/serverinfo?uuid=abc"]:
        raw = f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode()
        assert request(tls, port, {}, raw=raw)[0] == 404
    assert request(tls, port, {}, "/serverinfo")[0] == 404
    assert request(tls, port, {}, raw=b"GET /plank/topology HTTP/1.1\r\nHost: localhost\r\n\r\n")[0] == 401
    for extra in ["Content-Length: 1\r\n", "Transfer-Encoding: chunked\r\n",
                  "Expect: 100-continue\r\n", "Content-Length: 0\r\nContent-Length: 0\r\n"]:
        raw = ("GET /serverinfo HTTP/1.1\r\nHost: localhost\r\n" + extra + "\r\n").encode()
        assert request(tls, port, {}, raw=raw)[0] == 400


def authenticate(tls, port, username, password, encoding_mode="hevc-10-420-videotoolbox"):
    status, start = request(tls, port, {"username": username})
    assert status == 200 and start["state"] == "challenge"
    assert start["messages"][0]["style"] == 1
    response = {"conversation_id": start["conversation_id"], "responses": [password]}
    status, result = request(tls, port, response, "/plank/auth/respond")
    assert status == 200 and result["state"] == "authenticated"
    assert len(result["session_token"]) == 44
    token = result["session_token"]
    for bearer, expected in [(token, "1"), ("x" * 44, "0"), ("", "0")]:
        header = f"Authorization: Bearer {bearer}\r\n" if bearer else ""
        raw = f"GET /serverinfo HTTP/1.1\r\nHost: localhost\r\n{header}\r\n".encode()
        status, info = request(tls, port, {}, raw=raw, xml=True)
        assert status == 200 and info.findtext("PairStatus") == expected
    # No token or credential is printed or written to a file.
    status, replay = request(tls, port, response, "/plank/auth/respond")
    assert status == 200 and replay["state"] == "denied"
    raw = ("GET /plank/topology HTTP/1.1\r\nHost: localhost\r\n"
           "Authorization: Bearer " + token + "\r\n\r\n").encode()
    status, topology = request(tls, port, {}, raw=raw)
    assert status == 200 and topology["schema_version"] == 13 and topology["feature_flags"] == 7897201
    capture = topology["capture"]
    assert 2 <= capture["width"] <= 8192 and capture["width"] % 2 == 0
    assert 2 <= capture["height"] <= 8192 and capture["height"] % 2 == 0
    assert capture["logical_bounds"]["width"] > 0 and capture["logical_bounds"]["height"] > 0
    assert capture["encoding_profile"]["encoding_mode"] == encoding_mode
    assert capture["encoding_profile"]["rgb_identity"] is False
    status, repeated = request(tls, port, {}, raw=raw)
    assert status == 200 and repeated == topology
    # Same request shape, unknown token; never echo it or any account data.
    assert request(tls, port, {}, raw=raw.replace(token.encode(), b"x" * 44))[0] == 401
    return token, topology


def preview(tls, port, token, topology, receiver, media, seconds=3):
    capture = topology["capture"]
    body = {"schema_version": 6, "clipboard": False, "microphone": False, "camera": False, "capture_generation": topology["generation"], "capture_id": capture["id"],
            "width": capture["width"], "height": capture["height"], "encoding_mode": "hevc-10-420-videotoolbox",
            "frame_rate": 60, "bitrate_kbps": 50000, "max_udp_payload_size": 1200}

    def launch(value, bearer, path="/plank/launch"):
        encoded = json.dumps(value).encode()
        raw = (f"POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
               f"Authorization: Bearer {bearer}\r\nContent-Length: {len(encoded)}\r\n\r\n").encode() + encoded
        return request(tls, port, {}, raw=raw)

    vector = json.loads((Path(__file__).resolve().parents[1] /
                         "protocol/media-feature-negotiation-v1.json").read_text())
    offer = vector["offer"]
    assert launch(offer, "x" * 44, "/plank/negotiate")[0] == 401
    for _ in range(2):
        assert launch(offer, token, "/plank/negotiate") == (200, vector["response"])
    if not media:
        for invalid, expected_status in ((dict(offer, transport="plank-native/1"), 426),
                                         (dict(offer, required_features=["desktop", "audio", "input", "future"]), 426),
                                         (dict(offer, schema_version=True), 400)):
            assert launch(invalid, token, "/plank/negotiate")[0] == expected_status
            assert launch(offer, token, "/plank/negotiate")[0] == 401
            token, _ = authenticate(tls, port, "synthetic", "test")

    if not media:  # Synthetic display adapter; never changes a real desktop.
        mode = {"schema_version": 3, "width": 1920, "height": 1080, "scale": 1, "encoding_mode": "hevc-10-420-videotoolbox"}
        assert launch(mode, "x" * 44, "/plank/display")[0] == 401
        for invalid in [dict(mode, width=True), dict(mode, width=1920.5),
                        dict(mode, width=-1), dict(mode, extra=0), dict(mode, schema_version=2), dict(mode, encoding_mode="invalid"),
                        dict(mode, scale=True), dict(mode, scale=1.5), dict(mode, scale=0), dict(mode, scale=3),
                        {k: v for k, v in mode.items() if k != "scale"}]:
            assert launch(invalid, token, "/plank/display")[0] == 400
            assert launch(mode, token, "/plank/display")[0] == 401
            token, _ = authenticate(tls, port, "synthetic", "test")
        assert launch(dict(mode, width=1922), token, "/plank/display")[0] == 503
        # A transient display failure retains this authorization, without a
        # second password exchange. Invalid requests above still consume it.
        status, resized = launch(mode, token, "/plank/display")
        assert status == 200 and resized["capture"]["width"] == 1920
        assert resized["capture"]["logical_bounds"]["width"] == 1920
        retina = json.loads((Path(__file__).resolve().parents[1] / "protocol/macos-display-v3.json").read_text())
        status, matched = launch(retina, token, "/plank/display")
        assert status == 200 and matched["capture"]["width"] == 3420
        assert matched["capture"]["logical_bounds"] == {"x": -1920, "y": 0, "width": 1710, "height": 1107}
        status, restored = launch(dict(mode, width=3840, height=2160, scale=2), token, "/plank/display")
        assert status == 200 and restored == topology
        status, full = launch(dict(mode, width=3840, height=2160,
                                   encoding_mode="hevc-10-444-videotoolbox"), token, "/plank/display")
        assert status == 200 and full["capture"]["encoding_profile"]["profile"] == "rext"
        assert full["capture"]["encoding_profile"]["chroma"] == "4:4:4"
        assert launch(body, token)[0] == 400  # no silent switch back to Main10
        token, _ = authenticate(tls, port, "synthetic", "test", "hevc-10-444-videotoolbox")
        status, restored = launch(dict(mode, width=3840, height=2160, scale=2), token, "/plank/display")
        assert status == 200 and restored == topology

    assert launch(body, "x" * 44)[0] == 401
    if not media:
        for invalid in (dict(body, width=1), dict(body, encoding_mode="hevc-10-444-nvenc"),
                        dict(body, capture_generation=str(uuid.uuid4()))):
            assert launch(invalid, token)[0] == 400
            assert launch(body, token)[0] == 401
            token, _ = authenticate(tls, port, "synthetic", "test")
    # The old Client still requests mono microphone support. The new Host
    # returns the exact schema4 reply with that incompatible service disabled.
    first_body = dict(body, schema_version=4, microphone=True) if not media else body
    if not media:
        first_body.pop("camera")
    status, reply = launch(first_body, token)
    assert status == 200 and reply["schema_version"] == (4 if not media else 6) and reply["state"] == "connecting"
    assert reply["udp_port"] == port and reply["max_udp_payload_size"] == 1200
    assert reply["capture"] == capture and reply["transport_token"] != token
    expected_services = {"audio": True, "input": True, "pen": "normalized", "cursor": "embedded", "clipboard": False, "microphone": False}
    if media:
        expected_services["camera"] = False
    assert reply["services"] == expected_services
    assert launch(body, token)[0] == 401  # one-use HTTP token, before QUIC activation
    assert launch({"schema_version": 3, "width": 1920, "height": 1080, "scale": 1, "encoding_mode": "hevc-10-420-videotoolbox"}, token, "/plank/display")[0] == 401
    if not media:
        fingerprint = hashlib.sha256(Path(tls).with_name("cert.der").read_bytes()).hexdigest()
        old = subprocess.Popen([str(receiver), fingerprint, "--wait-takeover"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            old.stdin.write(json.dumps(reply).encode())
            old.stdin.close()
            assert select.select([old.stdout], [], [], 7)[0], "takeover receiver did not start"
            assert old.stdout.readline() == b"takeover_receiver_ready=1\n"
            replacement, original = authenticate(tls, port, "synthetic", "test")
            change = dict(mode, width=1920, height=1080)
            status, conflict = launch(change, replacement, "/plank/display")
            assert status == 409 and conflict["error"] == "session_active"
            session_id = conflict["session_id"]
            assert str(uuid.UUID(session_id)) == session_id
            # Cancel/no consent performs no mutation and does not revoke setup.
            assert launch(change, replacement, "/plank/display") == (status, conflict)
            assert old.poll() is None
            status, stale = launch(dict(change, takeover_session_id=str(uuid.uuid4())), replacement, "/plank/display")
            assert status == 409 and stale["error"] == "session_changed"
            assert old.poll() is None
            replacement, original = authenticate(tls, port, "synthetic", "test")
            assert original == topology
            status, resized = launch(dict(change, takeover_session_id=session_id), replacement, "/plank/display")
            assert status == 200 and resized["capture"]["width"] == 1920
            assert old.wait(timeout=7) == 0
            assert old.stdout.read() == b"takeover_receiver_terminal=1\n"
            # A fresh login from the displaced peer cannot invalidate the
            # reserved setup or silently reclaim the display, even behind NAT.
            competitor, _ = authenticate(tls, port, "synthetic", "test")
            assert launch(change, competitor, "/plank/display")[0] == 409
            new_body = dict(body, capture_generation=resized["generation"],
                            width=1920, height=1080)
            assert launch(new_body, competitor)[0] == 409
            assert launch(offer, replacement, "/plank/negotiate") == (200, vector["response"])
            feature_body = json.loads(json.dumps(vector["launch"]))
            for name in ("capture_generation", "capture_id", "max_udp_payload_size"):
                feature_body[name] = new_body[name]
            for name in ("width", "height", "encoding_mode", "frame_rate", "bitrate_kbps"):
                feature_body["features"]["desktop"][name] = new_body[name]
            for name in ("clipboard", "microphone", "camera"):
                feature_body["features"][name] = None
            status, replacement_reply = launch(feature_body, replacement)
            assert status == 200 and replacement_reply["schema_version"] == 7
            assert replacement_reply["features"] == feature_body["features"]
            assert "services" not in replacement_reply
            result = subprocess.run([str(receiver), fingerprint, "--no-media"],
                                    input=json.dumps(replacement_reply).encode(), capture_output=True, timeout=15)
            assert result.returncode == 0, "replacement stream failed"
            for schema in (5, 6):
                bearer, current = authenticate(tls, port, "synthetic", "test")
                bridge = dict(new_body, schema_version=schema, capture_generation=current["generation"])
                if schema == 5:
                    bridge.pop("camera")
                status, bridge_reply = launch(bridge, bearer)
                assert status == 200 and bridge_reply["schema_version"] == schema
                assert ("camera" in bridge_reply["services"]) == (schema == 6)
                result = subprocess.run([str(receiver), fingerprint, "--no-media"],
                                        input=json.dumps(bridge_reply).encode(), capture_output=True, timeout=15)
                assert result.returncode == 0, "legacy adapter stream failed"
            print("macos_takeover=pass real_tls=1 real_quic=1 cancel_unchanged=1 same_peer_reservation=1 new_geometry=1")
            print("macos_media_compatibility=pass schemas=4,5,6,7 negotiation_authorization=1")
            return
        finally:
            if old.poll() is None:
                old.terminate()
                old.wait(timeout=5)
    fingerprint = hashlib.sha256(tls.with_name("cert.der").read_bytes()).hexdigest()
    command = [str(receiver), fingerprint] + (["--seconds", str(seconds)] if media else ["--no-media"])
    # No launch/transport credential in argv, environment, files or diagnostics.
    result = subprocess.run(command, input=json.dumps(reply).encode(), capture_output=True, timeout=seconds + 15)
    assert result.returncode == 0, "Native preview receiver failed: " + result.stderr.decode(errors="replace")
    print(result.stdout.decode().strip())


def create_identity(temporary, config):
    os.chmod(temporary, 0o700)
    cert, key = [Path(temporary) / name for name in ("cert.pem", "key.pem")]
    subprocess.run(["openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256",
                    "-nodes", "-days", "1", "-config", str(config), "-keyout", str(key),
                    "-out", str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(key, 0o600)
    subprocess.run(["openssl", "x509", "-in", str(cert), "-outform", "DER", "-out", str(Path(temporary) / "cert.der")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Apple's SecKeyCreateWithData expects PKCS#1 RSA, not OpenSSL 3's default
    # PKCS#8 wrapper. LibreSSL already emits PKCS#1 and lacks this flag.
    help_result = subprocess.run(["openssl", "rsa", "-help"], capture_output=True)
    traditional = ["-traditional"] if b"-traditional" in help_result.stdout + help_result.stderr else []
    subprocess.run(["openssl", "rsa", *traditional, "-in", str(key), "-outform", "DER", "-out", str(Path(temporary) / "key.der")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(Path(temporary) / "key.der", 0o600)
    return cert


def aqua(executable, config, receiver=None, seconds=3):
    if not os.isatty(0) or os.geteuid() == 0:
        raise AssertionError("Aqua qualification requires the desktop user's TTY")
    domain = f"gui/{os.geteuid()}"
    subprocess.run(["launchctl", "print", domain], check=True, stdout=subprocess.DEVNULL)
    password = getpass.getpass("Development account password: ")
    with tempfile.TemporaryDirectory(prefix="plank-https-aqua-") as temporary:
        cert = create_identity(temporary, config)
        label = "la.instinctual.PLANK.https-qualification." + uuid.uuid4().hex
        stage = Path(temporary)
        # This generated, one-shot qualification job is never installed in a
        # LaunchAgents directory. Finally always unregisters it and removes its
        # own fixtures/logs. No password or bearer token enters the plist/logs.
        plist = {"Label": label, "ProgramArguments": [str(executable), temporary],
                 "RunAtLoad": True, "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive",
                 "StandardOutPath": str(stage / "stdout"), "StandardErrorPath": str(stage / "stderr")}
        with (stage / "agent.plist").open("wb") as stream:
            plistlib.dump(plist, stream)
        try:
            subprocess.run(["launchctl", "bootstrap", domain, str(stage / "agent.plist")], check=True)
            deadline = time.monotonic() + 10
            match = None
            while time.monotonic() < deadline:
                output = (stage / "stdout").read_text() if (stage / "stdout").exists() else ""
                match = re.fullmatch(r"macos_https_auth_ready port=(\d+) desktop_active=1\n", output)
                if match:
                    break
                time.sleep(0.1)
            assert match, "Aqua HTTPS readiness/desktop ownership failed"
            port = int(match[1])
            discovery(context(cert), port)
            token, topology = authenticate(context(cert), port, getpass.getuser(), password)
            password = None
            if receiver:
                preview(context(cert), port, token, topology, receiver, True, seconds)
                print("macos_https_aqua_preview=pass tls13_verified=1 live_owner=1 authenticated_capture=1 native_quic=1")
            else:
                print("macos_https_aqua_account=pass tls13_verified=1 live_owner=1 replay_denied=1 authenticated_topology=1 desktop_granted=0")
        except Exception:
            # Narrow numeric/stage-only diagnostics; never dump server stderr,
            # which could gain account/session details in a future dependency.
            error_file = stage / "stderr"
            if error_file.exists():
                for line in error_file.read_text(errors="replace").splitlines():
                    if re.fullmatch(r"macos_(?:opus|capture)_failure stage=[a-z-]+(?: (?:gap_ns|code)=[0-9.+-]+)?", line):
                        print(line, flush=True)
            raise
        finally:
            password = None
            subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)


def synthetic(executable, config, receiver=None):
    with tempfile.TemporaryDirectory(prefix="plank-https-qualification-") as temporary:
        cert = create_identity(temporary, config)
        process = subprocess.Popen([str(executable), temporary], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            if not select.select([process.stdout], [], [], 10)[0]:
                raise AssertionError("HTTPS listener readiness timed out")
            line = process.stdout.readline()
            match = re.fullmatch(r"macos_https_auth_ready port=(\d+) desktop_active=1\n", line)
            if not match:
                raise AssertionError("HTTPS listener did not report ready: " + line.strip())
            port = int(match[1])
            tls = context(cert)
            discovery(tls, port)
            token, topology = authenticate(tls, port, "synthetic", "test")
            if receiver:
                preview(tls, port, token, topology, receiver, False)
            status, start = request(tls, port, {"username": "synthetic"})
            status, denied = request(tls, port, {"conversation_id": start["conversation_id"],
                                               "responses": ["wrong-synthetic-secret"]}, "/plank/auth/respond")
            assert status == 200 and denied["state"] == "denied"
            for body, path in [([], "/plank/auth/start"), ({"username": 3}, "/plank/auth/start"),
                               ({"username": "synthetic", "extra": 1}, "/plank/auth/start"),
                               ({"conversation_id": "x", "responses": ["a", "b"]}, "/plank/auth/respond")]:
                status, result = request(tls, port, body, path)
                assert status == 400 and result["state"] == "denied"
            assert request(tls, port, {}, "/not-an-endpoint")[0] == 404
            for extra in ["Transfer-Encoding: chunked\r\n", "Content-Length: 2\r\n", "Expect: 100-continue\r\n"]:
                raw = ("POST /plank/auth/start HTTP/1.1\r\nHost: localhost\r\n"
                       "Content-Type: application/json\r\nContent-Length: 2\r\n" + extra + "\r\n{}").encode()
                assert request(tls, port, {}, raw=raw)[0] == 400
            old_tls = subprocess.run(tls_command(cert, port, "-tls1_2"), input=b"", capture_output=True, timeout=7)
            assert old_tls.returncode != 0 and b"HTTP/" not in old_tls.stdout
            untrusted_command = tls_command(cert, port)
            ca_index = untrusted_command.index("-CAfile")
            del untrusted_command[ca_index:ca_index + 2]
            untrusted = subprocess.run(untrusted_command, input=b"", capture_output=True, timeout=7)
            assert untrusted.returncode != 0 and b"HTTP/" not in untrusted.stdout
            with socket.create_connection(("127.0.0.1", port), timeout=3) as plain:
                plain.sendall(b"POST /plank/auth/start HTTP/1.1\r\n\r\n")
                try:
                    assert b"HTTP/" not in plain.recv(4096)
                except ConnectionResetError:
                    pass
            # Slow request must close, not occupy an admission slot indefinitely.
            began = time.monotonic()
            slow = subprocess.run(tls_command(cert, port), input=b"POST /plank/auth/start HTTP/1.1\r\n",
                                  capture_output=True, timeout=7)
            assert b"HTTP/" not in slow.stdout and time.monotonic() - began < 6
            idle = []
            try:
                for _ in range(8):
                    idle.append(socket.create_connection(("127.0.0.1", port), timeout=2))
                time.sleep(0.2)  # Let the listener process admitted connections.
                overflow = subprocess.run(tls_command(cert, port), input=b"", capture_output=True, timeout=3)
                assert overflow.returncode != 0 and b"HTTP/" not in overflow.stdout
            finally:
                for connection in idle:
                    connection.close()
            time.sleep(0.2)
            authenticate(tls, port, "synthetic", "test")
            discovery(tls, port)  # No public metadata change after authentication.
            # No desktop/capture endpoint or real account is used by this suite.
            print("macos_https_auth=pass discovery=1 authenticated_topology=1 invalid_topology_token_rejected=1 no_media_claim=1 tls13=1 tls12_rejected=1 trust_enforced=1 plaintext_rejected=1 replay_denied=1 framing_rejected=1 slow_request_closed=1 admission_bounded=1 recovery_pass=1 synthetic_only=1")
        finally:
            process.terminate()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=3)
            # TemporaryDirectory removes only this test's exact ephemeral fixtures.


def machine_authority_chain(executable, config):
    """Exercise the real Network.framework chain, without installed Host state."""
    with tempfile.TemporaryDirectory(prefix="plank-https-chain-") as temporary:
        stage = Path(temporary)
        root = stage / "machine"
        root.mkdir(mode=0o700)
        create_identity(root, config)
        create_identity(stage, config)  # Independent worker key, not the root key.
        (stage / "authority.der").write_bytes((root / "cert.der").read_bytes())
        (stage / "leaf.cnf").write_text("basicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n")
        def crypto(arguments):
            subprocess.run(["openssl", *arguments], cwd=stage, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        crypto(["req", "-new", "-key", "key.pem", "-subj", "/CN=PLANK worker", "-out", "worker.csr"])
        crypto(["x509", "-req", "-in", "worker.csr", "-CA", "machine/cert.pem", "-CAkey", "machine/key.pem",
                "-set_serial", "123", "-days", "1", "-sha256", "-extfile", "leaf.cnf", "-out", "cert.pem"])
        crypto(["x509", "-in", "cert.pem", "-outform", "DER", "-out", "cert.der"])
        process = subprocess.Popen([str(executable), temporary], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            assert select.select([process.stdout], [], [], 10)[0], "Chain listener readiness timed out"
            match = re.fullmatch(r"macos_https_auth_ready port=(\d+) desktop_active=1\n", process.stdout.readline())
            assert match, "Chain listener not ready"
            port = int(match[1])
            command = tls_command(root / "cert.pem", port)
            command.remove("-quiet")
            result = subprocess.run(command + ["-showcerts", "-no_ign_eof"], input=b"",
                                    capture_output=True, timeout=7)
            assert result.returncode == 0, "Worker TLS chain handshake failed"
            certificates = re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", result.stdout, re.S)
            expected = [(stage / "cert.pem").read_bytes().strip(), (root / "cert.pem").read_bytes().strip()]
            assert certificates == expected, "Host did not send exactly worker leaf then machine authority"
            discovery(root / "cert.pem", port)
            authenticate(root / "cert.pem", port, "synthetic", "test")
            print("macos_https_machine_chain=pass leaf_then_authority=1 authenticated_control=1")
        finally:
            process.terminate()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", type=Path)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--real-port", type=int)
    parser.add_argument("--certificate", type=Path)
    parser.add_argument("--aqua", action="store_true")
    parser.add_argument("--preview-receiver", type=Path)
    parser.add_argument("--preview-seconds", type=int, choices=range(3, 31), default=3)
    args = parser.parse_args()
    if args.aqua:
        if not args.server or not args.config:
            parser.error("Aqua mode requires the real --server and --config")
        aqua(args.server, args.config, args.preview_receiver, args.preview_seconds)
    elif args.real_port:
        if not args.certificate or not os.isatty(0):
            parser.error("Real verification requires a TTY and the exact certificate")
        password = getpass.getpass("Development account password: ")
        authenticate(context(args.certificate), args.real_port, getpass.getuser(), password)
        password = None
        print("macos_https_real_account=pass tls13_verified=1 replay_denied=1 desktop_granted=0")
    else:
        if not args.server or not args.config:
            parser.error("Synthetic suite requires --server and --config")
        synthetic(args.server, args.config, args.preview_receiver)
        machine_authority_chain(args.server, args.config)


if __name__ == "__main__":
    main()
