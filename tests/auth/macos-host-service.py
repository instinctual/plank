#!/usr/bin/env python3
"""Run the actual Host machine/graphical executable, without OS login or input.

Temporary launchd jobs and role-private TLS configuration, not an installer.
No synthetic verifier is linked into the tested executable. No password needed:
public TLS discovery and denial checks precede graceful shutdown/replacement.
"""
import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import subprocess
import tempfile
import time
import uuid


def command(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=15)


def until(check, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.1)
    raise AssertionError("Host service assembly did not reach its expected state")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("binary", type=Path)
    parser.add_argument("sha256")
    parser.add_argument("desktop_uid", type=int)
    args = parser.parse_args()
    assert os.getuid() == 0 and args.desktop_uid > 0
    assert os.stat("/dev/console").st_uid == args.desktop_uid, "Keep the existing desktop; no session change required"
    assert hashlib.sha256(args.binary.read_bytes()).hexdigest() == args.sha256
    spec = importlib.util.spec_from_file_location("https_fixture", args.source / "tests/auth/macos-https-auth.py")
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    # Root's per-user TMPDIR is not traversable by an Aqua account. Only the
    # outer executable/log directory is shared; keys stay role-private below it.
    with tempfile.TemporaryDirectory(prefix="plank-host-service-", dir="/private/tmp") as temporary:
        stage = Path(temporary)
        os.chmod(stage, 0o755)
        executable = stage / "plank-host"
        if args.binary.parent.name == "MacOS" and args.binary.parents[2].suffix == ".app":
            # Preserve the signed Info.plist/resource envelope. Extracting only
            # the executable invalidates an application signature's bundle slots.
            app = stage / args.binary.parents[2].name
            shutil.copytree(args.binary.parents[2], app)
            executable = app / "Contents/MacOS/plank-host"
            command("codesign", "--verify", "--strict", str(app))
        else:
            shutil.copyfile(args.binary, executable)
        os.chmod(executable, 0o755)
        assert hashlib.sha256(executable.read_bytes()).hexdigest() == args.sha256
        command("codesign", "--verify", "--strict", str(executable))
        identity = stage / "identity"
        identity.mkdir(mode=0o700)
        certificate = fixture.create_identity(str(identity), args.source / "probes/macos/https-cert.cnf")
        # Host startup validates byte-equivalent PKCS#1 DER/PEM inputs. req
        # writes PKCS#8 PEM by default; canonicalize the test key once, without
        # changing its identity or broadening the Host's accepted file formats.
        command("openssl", "rsa", "-in", str(identity / "key.pem"), "-out", str(identity / "rsa.pem"))
        os.replace(identity / "rsa.pem", identity / "key.pem")
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        config = {"Address": "127.0.0.1", "Port": port, "Name": "PLANK Host assembly",
                  "UUID": str(uuid.uuid4())}
        (identity / "host.plist").write_bytes(plistlib.dumps(config))
        for path in identity.iterdir():
            os.chmod(path, 0o600)
            os.chown(path, args.desktop_uid, -1)
        os.chown(identity, args.desktop_uid, -1)
        label = "la.instinctual.PLANK.host-assembly." + str(uuid.uuid4())
        domain = f"gui/{args.desktop_uid}"
        service = {"Label": label, "ProgramArguments": [str(executable), "--machine", label],
                   "MachServices": {label: True}, "RunAtLoad": True,
                   "StandardOutPath": str(stage / "machine.out"), "StandardErrorPath": str(stage / "machine.err")}
        graphical = {"Label": label + ".graphical",
                     "ProgramArguments": [str(executable), "--graphical", label, "desktop", str(identity)],
                     "RunAtLoad": True, "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive",
                     "StandardOutPath": str(stage / "graphical.out"), "StandardErrorPath": str(stage / "graphical.err")}
        for name, value in (("machine", service), ("graphical", graphical)):
            (stage / (name + ".plist")).write_bytes(plistlib.dumps(value))
            for suffix in ("out", "err"):
                path = stage / (name + "." + suffix)
                path.touch(mode=0o600)
                if name == "graphical":
                    os.chown(path, args.desktop_uid, -1)
        machine_job, graphical_job = "system/" + label, domain + "/" + graphical["Label"]
        try:
            command("launchctl", "bootstrap", "system", str(stage / "machine.plist"))
            # Two process lifetimes, same live desktop and coordinator. This
            # checks cleanup/re-admission, not another OS login/logout cycle.
            for iteration in range(2):
                assert os.stat("/dev/console").st_uid == args.desktop_uid
                command("launchctl", "bootstrap", domain, str(stage / "graphical.plist"))
                until(lambda: "PLANK Host listening" in (stage / "graphical.err").read_text())
                raw = b"GET /serverinfo HTTP/1.1\r\nHost: localhost\r\n\r\n"
                status, response = fixture.request(certificate, port, {}, raw=raw, xml=True)
                assert status == 200 and response.findtext("hostname") == config["Name"]
                assert response.findtext("HttpsPort") == str(port)
                version = response.findtext("PlankHostVersion")
                assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z][a-z0-9.-]*)?", version)
                if args.binary.parent.name == "MacOS" and args.binary.parents[2].suffix == ".app":
                    assert version == plistlib.loads((args.binary.parents[2] / "Contents/Info.plist").read_bytes())["PLANKVersion"]
                assert response.findtext("ServerCodecModeSupport") == "1049088"
                assert response.findtext("PlankTopologyVersion") == "13"
                assert response.findtext("PlankFeatureFlags") == "7897201"
                assert response.findtext("PlankOccupied") == "1"
                assert fixture.request(certificate, port, {}, raw=b"GET /plank/topology HTTP/1.1\r\nHost: localhost\r\n\r\n")[0] == 401
                assert fixture.request(certificate, port, {}, raw=b"GET /applist HTTP/1.1\r\nHost: localhost\r\n\r\n")[0] == 401
                command("launchctl", "kill", "SIGTERM", graphical_job)
                until(lambda: "last exit code = 0" in command("launchctl", "print", graphical_job).stdout)
                assert "control, video, audio and input drained" in (stage / "graphical.err").read_text()
                until(lambda: (stage / "machine.err").read_text().count("ownership released=1") == iteration + 1)
                command("launchctl", "bootout", graphical_job)
                (stage / "graphical.err").write_text("")
            print("macos_host_service=pass actual_host_binary=1 tls_discovery=1 unauthorized_denied=1 graceful_shutdown=1 process_replacement=1 os_login_logout=0 capture=0 input=0")
        except Exception:
            for name in ("machine.err", "graphical.err"):
                for line in (stage / name).read_text(errors="replace").splitlines():
                    if "PLANK Host" in line:
                        print(line, flush=True)
            result = command("launchctl", "print", graphical_job, check=False)
            for line in result.stdout.splitlines():
                if "last exit code" in line or "state =" in line:
                    print(line.strip(), flush=True)
            raise
        finally:
            command("launchctl", "bootout", graphical_job, check=False)
            command("launchctl", "bootout", machine_job, check=False)


if __name__ == "__main__":
    main()
