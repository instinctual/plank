#!/usr/bin/env python3
"""Protected disposable-runner signing; never run on an operator's Mac."""
import base64
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys

SECRET_NAMES = (
    "PLANK_DEVELOPER_ID_APPLICATION_P12", "PLANK_DEVELOPER_ID_INSTALLER_P12",
    "PLANK_DEVELOPER_ID_APPLICATION_PASSWORD", "PLANK_DEVELOPER_ID_INSTALLER_PASSWORD",
    "PLANK_APPLE_ID", "PLANK_APPLE_APP_PASSWORD", "PLANK_MACOS_HOST_PROVISION_PROFILE",
)


class SigningError(Exception):
    pass


def command(stage, args):
    # Never log command arguments or Apple-tool output containing credentials.
    # Child environments no longer contain the GitHub secret injection.
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise SigningError(f"{stage} failed (exit {result.returncode}); check the protected signing inputs")
    return result.stdout


def runner_directory():
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"):
        raise SigningError("Signing requires a manually dispatched GitHub-hosted Mac")
    root = Path(os.environ["RUNNER_TEMP"])
    if not root.is_absolute() or not root.is_dir():
        raise SigningError("Invalid runner scratch directory")
    return root / "plank-macos-signing"


def cleanup(directory):
    if not directory.exists():
        return
    if directory.is_symlink() or directory.stat().st_uid != os.getuid():
        raise SigningError("Refusing unsafe signing scratch cleanup")
    state = directory / "search-list.json"
    if state.exists():
        previous = json.loads(state.read_text())
        if not isinstance(previous, list) or not all(isinstance(p, str) and p.startswith("/") for p in previous):
            raise SigningError("Invalid saved keychain search list")
        command("restore keychain search list", ["security", "list-keychains", "-d", "user", "-s", *previous])
    keychain = directory / "signing.keychain-db"
    if keychain.exists():
        command("delete temporary keychain", ["security", "delete-keychain", str(keychain)])
    shutil.rmtree(directory)


def signing_identity(output, kind, team):
    matches = re.findall(r'\b([0-9A-Fa-f]{40}) "' + re.escape(kind)
                         + r': [^"\n]+ \(' + re.escape(team) + r'\)"', output)
    if len(matches) != 1:
        raise SigningError(f"Expected exactly one {kind} identity for the configured team")
    return matches[0].upper()


def interrupted(signum, frame):
    raise SigningError("Signing interrupted; removing temporary credentials")


def main():
    directory = runner_directory()
    if sys.argv[1:] == ["--cleanup"]:
        cleanup(directory)
        return
    if sys.argv[1:]:
        raise SigningError("Unexpected signing arguments")
    role = os.environ.get("PLANK_CI_PRODUCT")
    team = os.environ.get("PLANK_MACOS_TEAM_ID", "")
    if role not in ("macos-host", "macos-client", "macos-fullscreen-probe") or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SigningError("Invalid product or Developer Team ID")
    material = {name: os.environ.pop(name, "") for name in SECRET_NAMES}
    missing = [name for name, value in material.items() if not value and
               (role == "macos-host" or name != "PLANK_MACOS_HOST_PROVISION_PROFILE")]
    if missing:
        raise SigningError("Missing protected environment secrets: " + ", ".join(missing))
    # Exact one-shot path: refuse reuse rather than trusting stale credentials.
    directory.mkdir(mode=0o700)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        profile = material.pop("PLANK_MACOS_HOST_PROVISION_PROFILE", "")
        if role == "macos-host":
            try:
                data = base64.b64decode("".join(profile.split()), validate=True)
            except ValueError:
                raise SigningError("Invalid Host profile encoding") from None
            if not data or len(data) > 1024 * 1024:
                raise SigningError("Invalid Host profile size")
            path = directory / "host.provisionprofile"
            with path.open("xb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(data)
            os.environ["PLANK_MACOS_APP_PROVISION_PROFILE"] = str(path)
        # Product dependencies were bootstrapped and cached by credential-free
        # workflow steps. Never repeat bootstrap after receiving signing inputs.
        # The standalone diagnostic probe has no dependency bootstrap/cache.
        root = Path(os.environ["PLANK_SOURCE_ROOT"])
        probe = role == "macos-fullscreen-probe"
        probe_script = root / "scripts/package/build-macos-fullscreen-probe.sh"
        probe_output = str(Path(os.environ["PLANK_WORK_ROOT"]) / "fullscreen-probe") if probe else ""
        if probe:
            Path(os.environ["PLANK_WORK_ROOT"]).mkdir(parents=True, exist_ok=True)
            result = subprocess.run(["bash", str(probe_script), "--build", str(root), probe_output])
            if result.returncode:
                raise SigningError(f"Credential-free probe build failed (exit {result.returncode})")
        previous = shlex.split(command("read keychain search list", ["security", "list-keychains", "-d", "user"]))
        state = directory / "search-list.json"
        state.write_text(json.dumps(previous))
        state.chmod(0o600)
        keychain = str(directory / "signing.keychain-db")
        password = secrets.token_urlsafe(48)
        command("create temporary keychain", ["security", "create-keychain", "-p", password, keychain])
        command("configure temporary keychain", ["security", "set-keychain-settings", "-lut", "21600", keychain])
        command("unlock temporary keychain", ["security", "unlock-keychain", "-p", password, keychain])
        command("select temporary keychain", ["security", "list-keychains", "-d", "user", "-s", keychain, *previous])
        for kind in ("APPLICATION", "INSTALLER"):
            encoded = material.pop(f"PLANK_DEVELOPER_ID_{kind}_P12")
            path = directory / (kind.lower() + ".p12")
            try:
                data = base64.b64decode("".join(encoded.split()), validate=True)
            except ValueError:
                raise SigningError("Invalid encrypted certificate export encoding") from None
            with path.open("xb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(data)
            command("import " + kind.lower() + " identity", ["security", "import", str(path), "-k", keychain,
                    "-P", material.pop(f"PLANK_DEVELOPER_ID_{kind}_PASSWORD"),
                    "-T", "/usr/bin/codesign", "-T", "/usr/bin/productsign", "-T", "/usr/bin/productbuild"])
            path.unlink()
        command("authorize Apple signing tools", ["security", "set-key-partition-list", "-S", "apple-tool:,apple:",
                "-s", "-k", password, keychain])
        identities = command("validate signing identities", ["security", "find-identity", "-v", keychain])
        os.environ["PLANK_MACOS_SIGNING_IDENTITY"] = signing_identity(identities, "Developer ID Application", team)
        os.environ["PLANK_MACOS_INSTALLER_IDENTITY"] = signing_identity(identities, "Developer ID Installer", team)
        command("validate notarization credentials", ["xcrun", "notarytool", "store-credentials", "plank-ci",
                "--apple-id", material.pop("PLANK_APPLE_ID"), "--team-id", team,
                "--password", material.pop("PLANK_APPLE_APP_PASSWORD"), "--keychain", keychain])
        material.clear()
        os.environ.update(PLANK_CI_SIGNED="true", PLANK_NOTARY_PROFILE="plank-ci", PLANK_NOTARY_KEYCHAIN=keychain)
        print("protected_signing_inputs=ready", flush=True)
        build = (["bash", str(probe_script), "--package", str(root), probe_output] if probe else
                 ["bash", str(root / "scripts/ci/build.sh"), role])
        result = subprocess.run(build)
        if result.returncode:
            raise SigningError(f"Signed build/package gates failed (exit {result.returncode})")
    finally:
        os.environ.pop("PLANK_MACOS_APP_PROVISION_PROFILE", None)
        material.clear()
        cleanup(directory)
    print("protected_signing_cleanup=pass", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (SigningError, OSError, ValueError) as error:
        # Do not print subprocess objects, tracebacks, exported bytes or secrets.
        print("macos_signing=failed: " + (str(error) if isinstance(error, SigningError) else "local signing setup error"), file=sys.stderr)
        sys.exit(1)
