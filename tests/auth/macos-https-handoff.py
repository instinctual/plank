#!/usr/bin/env python3
"""Real loopback TLS socket ownership: root -> desktop -> root -> desktop.

Run only on a disposable Mac builder or an explicitly authorized test Mac.
Root is needed only to launch fixture children as two UIDs; no accounts, jobs,
trust settings, sysctls, production listeners or graphical sessions are changed.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import tempfile
import time

spec = importlib.util.spec_from_file_location("https_fixture", Path(__file__).with_name("macos-https-auth.py"))
https = importlib.util.module_from_spec(spec)
spec.loader.exec_module(https)


class BindFailure(AssertionError):
    pass


def ready(process, timeout=3):
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise AssertionError("handoff listener readiness exceeded three seconds")
    line = process.stdout.readline()
    match = re.fullmatch(rb"macos_https_auth_ready port=(\d+) desktop_active=1\n", line)
    if not match:
        _, errors = process.communicate(timeout=3)
        # Only numeric product diagnostics, never dump arbitrary framework logs.
        reasons = re.findall(rb"PLANK Host control listener failed: port=\d+ error-domain=\d+ error-code=\d+", errors)
        if process.returncode == 2 and any(item.endswith(b"error-domain=1 error-code=48") for item in reasons):
            raise BindFailure("EADDRINUSE")
        raise AssertionError(f"handoff listener failed (exit={process.returncode}, "
                             f"bind_errors={[item.decode() for item in reasons]})")
    return int(match[1])


def stop(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=3)
        raise AssertionError("HTTPS worker did not drain within three seconds")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--gid", type=int, required=True)
    parser.add_argument("--expect-lingering-close", action="store_true")
    args = parser.parse_args()
    assert os.geteuid() == 0 and args.uid > 0 and args.gid > 0
    # Root's default Darwin per-user temp parent is not traversable by the
    # desktop UID. Keep the exact private fixture directory in /private/tmp.
    with tempfile.TemporaryDirectory(prefix="plank-https-handoff-", dir="/private/tmp") as temporary:
        certificate = https.create_identity(temporary, args.config)
        # Fixture credentials only. Each tested UID can read the same ephemeral
        # identity without making any private key world-readable.
        for path in [Path(temporary), *Path(temporary).iterdir()]:
            os.chown(path, args.uid, args.gid)
        processes = []
        held = []
        port = 0

        def start(uid, requested):
            process = subprocess.Popen([str(args.server), temporary],
                env={**os.environ, "PLANK_TEST_LISTEN_PORT": str(requested)},
                user=uid, group=args.gid if uid else 0, extra_groups=[],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            processes.append(process)
            return process

        try:
            # Multiple real cross-UID rebinds, without sleeps/retry-until-green.
            for stage, uid in enumerate([0, args.uid, 0, args.uid]):
                print(f"handoff_stage={'sign-in' if uid == 0 else 'desktop'}", flush=True)
                began = time.monotonic()
                server = start(uid, port)
                try:
                    assigned = ready(server)
                except BindFailure:
                    if args.expect_lingering_close and stage == 1:
                        print("macos_https_handoff_negative_control=pass detected=EADDRINUSE", flush=True)
                        return
                    raise
                assert not port or assigned == port
                port = assigned
                assert time.monotonic() - began < 3
                https.discovery(certificate, port)
                _, challenge = https.request(certificate, port, {"username": "synthetic"})
                status, authenticated = https.request(certificate, port,
                    {"conversation_id": challenge["conversation_id"], "responses": ["test"]}, "/plank/auth/respond")
                assert status == 200 and authenticated["state"] == "authenticated"
                token = authenticated["session_token"]
                assert len(token) == 44
                # The Client can reconnect before the previous graphical
                # worker finishes draining. Exercise that real TLS window,
                # including a response to a challenge issued before retirement.
                _, challenge = https.request(certificate, port, {"username": "synthetic"})
                assert challenge["state"] == "challenge"
                response = {"conversation_id": challenge["conversation_id"], "responses": ["test"]}
                server.send_signal(signal.SIGUSR1)
                assert select.select([server.stdout], [], [], 3)[0], "retirement notification missing"
                assert server.stdout.readline() == b"macos_https_auth_retired=1\n"
                assert https.request(certificate, port, response, "/plank/auth/respond") == (200, {"state": "busy"})
                assert https.request(certificate, port, {"username": "synthetic"}) == (200, {"state": "busy"})
                # Availability never authorizes access through the old worker.
                assert https.request(certificate, port, {}, raw=
                    ("GET /plank/topology HTTP/1.1\r\nHost: localhost\r\n"
                     f"Authorization: Bearer {token}\r\n\r\n").encode())[0] == 401
                # A second listener must fail even for the same UID. This gate
                # rejects a blanket SO_REUSEPORT workaround.
                competitor = start(uid, port)
                output, _ = competitor.communicate(timeout=3)
                assert competitor.returncode == 2 and b"ready" not in output
                # Pending TLS and incomplete HTTP must not leave lingering
                # sockets during retirement, nor wait for the admission timer.
                held.append(socket.create_connection(("127.0.0.1", port), timeout=2))
                with https.exchange(certificate, port,
                        b"GET /serverinfo HTTP/1.1\r\nHost: localhost\r\n\r\n") as (_, response):
                    assert response.startswith(b"HTTP/1.1 200 ")
                    # Keep a completed response's client open across stop too.
                    # This must not wait for its normal five-second deadline.
                    stop(server)
                    assert server.returncode == 0
                for connection in held:
                    connection.close()
                held.clear()
            assert not args.expect_lingering_close, "regression fixture did not detect graceful-close mutation"
            print("macos_https_cross_uid_handoff=pass transitions=3 retirement_auth_retryable=1 exclusive_listener=1 max_ready_seconds=3")
        finally:
            for connection in held:
                connection.close()
            for process in processes:
                stop(process)


if __name__ == "__main__":
    main()
