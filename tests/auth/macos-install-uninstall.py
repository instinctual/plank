#!/usr/bin/env python3
"""Authorized dedicated-Mac install/uninstall/reinstall qualification.

Requires the operator's session to be disconnected. Preserves identities/logs,
never reads private-key contents and never logs out, reboots or requests consent.
"""
import argparse
import configparser
import hashlib
import os
from pathlib import Path
import plistlib
import pwd
import socket
import stat
import subprocess
import sys
import time


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    print(result.stdout, end="", flush=True)
    if result.returncode:
        print(result.stderr, end="", flush=True)
        raise RuntimeError(f"Qualification command failed: {args[0]} (exit {result.returncode})")
    return result


def metadata(path):
    st = path.lstat()
    assert stat.S_ISREG(st.st_mode) and stat.S_IMODE(st.st_mode) == 0o600 and st.st_nlink == 1
    return st.st_ino, st.st_size, st.st_mtime_ns, st.st_uid, st.st_mode


def reachable(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--retire-user-agent", action="append", default=[])
    args = parser.parse_args()
    assert os.getuid() == 0 and os.uname().sysname == "Darwin"
    console = os.stat("/dev/console").st_uid
    assert console > 0
    account = pwd.getpwuid(console)
    candidate = args.app / "Contents/MacOS/plank-host"
    assert hashlib.sha256(candidate.read_bytes()).hexdigest() == args.sha256
    run("codesign", "--verify", "--strict", str(args.app))
    version = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())["PLANKVersion"]
    installed = Path("/Applications/PLANK Host.app")
    state = Path("/Library/Application Support/PLANK")
    config_path = Path("/etc/plank/host.conf")
    public = config_path.read_bytes()
    parsed = configparser.ConfigParser(interpolation=None)
    parsed.read_string(public.decode("utf-8"))
    port = parsed.getint("network", "port", fallback=28989)
    identities = [state / "SignIn"]
    for name in sorted(set(args.retire_user_agent + [account.pw_name])):
        identities.append(Path(pwd.getpwnam(name).pw_dir) / "Library/Application Support/PLANK/Host")
    files = [state / "identity.plist"] + [directory / name for directory in identities for name in ("key.pem", "key.der", "cert.pem", "cert.der")]
    before = {path: metadata(path) for path in files}
    logs = [Path(account.pw_dir) / "Library/Logs/PLANK/host-desktop.log",
            Path("/Library/Logs/PLANK/host-machine.log"), Path("/Library/Logs/PLANK/host-sign-in.log")]
    log_inodes = {path: path.lstat().st_ino for path in logs}
    jobs = [Path("/Library/LaunchDaemons/la.instinctual.PLANK.Host.machine.plist"),
            Path("/Library/LaunchAgents/la.instinctual.PLANK.Host.desktop.plist"),
            Path("/Library/LaunchAgents/la.instinctual.PLANK.Host.sign-in.plist")]

    def preserved():
        assert os.stat("/dev/console").st_uid == console, "Console changed; stop qualification"
        assert all(metadata(path) == value for path, value in before.items()), "Identity metadata changed"
        assert all(path.lstat().st_ino == value for path, value in log_inodes.items()), "Log was replaced"
        assert config_path.read_bytes() == public, "Public configuration changed"
        print("identity_files_unchanged=1 public_configuration_preserved=1 logs_preserved=1", flush=True)

    def ready():
        assert hashlib.sha256((installed / "Contents/MacOS/plank-host").read_bytes()).hexdigest() == args.sha256
        assert plistlib.loads((installed / "Contents/Info.plist").read_bytes())["PLANKVersion"] == version
        run("codesign", "--verify", "--strict", str(installed))
        deadline = time.monotonic() + 15
        while not reachable(port):
            if time.monotonic() >= deadline:
                raise RuntimeError("Installed Host listener did not become ready")
            time.sleep(0.2)
        assert all(path.is_file() and not path.is_symlink() and path.stat().st_uid == 0 for path in jobs)
        run(sys.executable, str(args.source / "tests/auth/macos-permission-check.py"), "--uid", str(console))
        preserved()
        print("installed_version=" + version + " listener_ready=1 signed_aqua_preflight=1", flush=True)

    installer = [sys.executable, str(args.source / "scripts/maintenance/install-macos-host-development.py"), "--app", str(args.app)]
    retirement = [part for name in args.retire_user_agent for part in ("--retire-user-agent", name)]
    run(*installer, *retirement)
    ready()
    run(sys.executable, str(installed / "Contents/Resources/uninstall-macos-host-development.py"))
    assert not installed.exists() and not any(path.exists() for path in jobs)
    assert not reachable(port), "Host listener survived uninstall"
    preserved()
    print("uninstall_pass=1 app_removed=1 jobs_removed=1 listener_removed=1", flush=True)
    run(*installer)
    ready()
    print("reinstall_pass=1 no_login_logout_reboot=1 no_tcc_changes=1 live_media_not_tested=1", flush=True)


if __name__ == "__main__":
    main()
