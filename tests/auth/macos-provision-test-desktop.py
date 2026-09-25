#!/usr/bin/env python3
"""Provision only the operator-approved standard test account's desktop worker.

Qualification fixture, not the all-user installer. Reuses the installed signed
Host, public workstation identity and existing coordinator. Never replaces the
app, copies machine keys, changes TCC, logs in/out or restarts other roles.
"""
import importlib.util
import os
from pathlib import Path
import plistlib
import pwd

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("installer", ROOT / "scripts/maintenance/install-macos-host-development.py")
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


def main():
    assert os.getuid() == 0 and os.uname().sysname == "Darwin"
    account = pwd.getpwnam("permission-test-user")
    assert account.pw_uid > 0 and os.stat("/dev/console").st_uid == account.pw_uid
    app = Path("/Applications/PLANK Host.app")
    INSTALLER.signing_identity(app)
    label = "la.instinctual.PLANK.Host.desktop"
    machine = "la.instinctual.PLANK.Host.machine"
    domain = f"gui/{account.pw_uid}"
    INSTALLER.run("launchctl", "print", "system/" + machine)
    INSTALLER.run("launchctl", "print", domain)
    agent_path = Path(account.pw_dir) / "Library/LaunchAgents" / (label + ".plist")
    pid = os.fork()
    if pid == 0:
        # Permanent privilege drop before following any path in a user home.
        os.initgroups(account.pw_name, account.pw_gid)
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)
        os.umask(0o077)
        home = Path(account.pw_dir)
        logs = home / "Library/Logs/PLANK"
        logs.mkdir(parents=True, mode=0o700, exist_ok=True)
        log = logs / "host-desktop.log"
        assert not log.is_symlink()
        log.touch(mode=0o600, exist_ok=True)
        agent_path.parent.mkdir(parents=True, mode=0o755, exist_ok=True)
        agent = {"Label": label, "ProgramArguments": [str(app / "Contents/MacOS/plank-host"),
                 "--desktop", machine], "RunAtLoad": True,
                 "KeepAlive": True, "ThrottleInterval": 2, "LimitLoadToSessionType": "Aqua",
                 "ProcessType": "Interactive", "StandardOutPath": str(log), "StandardErrorPath": str(log)}
        data = plistlib.dumps(agent)
        if agent_path.exists() or agent_path.is_symlink():
            assert not agent_path.is_symlink() and agent_path.read_bytes() == data
        else:
            with agent_path.open("xb") as target:
                target.write(data)
            os.chmod(agent_path, 0o644)
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
    assert os.stat("/dev/console").st_uid == account.pw_uid
    if INSTALLER.run("launchctl", "print", domain + "/" + label, check=False).returncode:
        INSTALLER.run("launchctl", "bootstrap", domain, str(agent_path))
    print("Test desktop worker provisioned; independent user keys; no permission changes")


if __name__ == "__main__":
    main()
