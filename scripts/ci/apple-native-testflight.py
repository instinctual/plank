#!/usr/bin/env python3
"""Protected GitHub-hosted Vision archive export/upload. No local signing fallback."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request


class DeliveryError(Exception):
    pass


def require(ok, message):
    if not ok:
        raise DeliveryError(message)


def runner_directory():
    require(sys.platform == "darwin" and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and os.environ.get("GITHUB_REPOSITORY") == "instinctual/plank"
            and os.environ.get("GITHUB_REF") in ("refs/heads/native-builds", "refs/heads/apple-native-integration"),
            "TestFlight requires a protected manual dispatch on an approved integration branch")
    root = Path(os.environ["RUNNER_TEMP"])
    require(root.is_absolute() and root.is_dir(), "Invalid runner scratch directory")
    return root / "plank-vision-credentials"


def cleanup(directory):
    if directory.exists():
        require(not directory.is_symlink() and directory.stat().st_uid == os.getuid(),
                "Unsafe credential cleanup path")
        shutil.rmtree(directory)


def command(stage, args, **kwargs):
    # Raw Apple output can include account metadata. Never publish it or secret argv.
    result = subprocess.run(args, capture_output=True, **kwargs)
    if result.returncode:
        text = result.stderr.decode(errors="replace") + result.stdout.decode(errors="replace")
        lines = [line.strip() for line in text.splitlines() if re.search(r"error:|error domain|failed", line, re.I)]
        # A narrow code-only diagnostic is safe in public CI; no raw Apple message.
        codes = sorted(set(re.findall(r"(?:Code=|Error Code: )(-?\d+)\b", "\n".join(lines))))
        raise DeliveryError(f"{stage} failed (exit {result.returncode}, Apple codes {','.join(codes) or 'unavailable'})")
    return result.stdout


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def raw_signature(der):
    # ES256 uses a 64-byte r||s signature; OpenSSL produces ASN.1 DER.
    require(8 <= len(der) <= 72 and der[0] == 0x30 and der[1] == len(der) - 2, "Invalid ES256 signature")
    pos = 2
    values = []
    for _ in range(2):
        require(pos + 2 <= len(der) and der[pos] == 2, "Invalid ES256 integer")
        length = der[pos + 1]
        pos += 2
        require(0 < length <= 33 and pos + length <= len(der), "Invalid ES256 length")
        value = der[pos:pos + length]
        require(not value[0] & 0x80, "Negative ES256 integer")
        value = value.lstrip(b"\0")
        require(len(value) <= 32, "Oversized ES256 integer")
        values.append(value.rjust(32, b"\0"))
        pos += length
    require(pos == len(der), "Trailing ES256 data")
    return b"".join(values)


class Store:
    def __init__(self, key_file, key_id, issuer):
        self.key_file, self.key_id, self.issuer = key_file, key_id, issuer

    def token(self):
        header = b64(json.dumps({"alg": "ES256", "kid": self.key_id, "typ": "JWT"}).encode())
        now = int(time.time())
        payload = b64(json.dumps({"iss": self.issuer, "iat": now - 5, "exp": now + 600,
                                  "aud": "appstoreconnect-v1"}).encode())
        data = (header + "." + payload).encode()
        signature = command("Apple API authentication", ["openssl", "dgst", "-sha256", "-sign", str(self.key_file)], input=data)
        return header + "." + payload + "." + b64(raw_signature(signature))

    def request(self, path, body=None):
        require(path.startswith("/") and not path.startswith("//"), "Invalid Apple API path")
        request = urllib.request.Request("https://api.appstoreconnect.apple.com/v1" + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": "Bearer " + self.token(), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read(4 * 1024 * 1024)
                return json.loads(data) if data else {}
        except urllib.error.HTTPError as error:
            raise DeliveryError(f"App Store Connect request failed (HTTP {error.code}); no credentials logged") from None


def verify_receipt(receipt, archive, source, bundle, version, build):
    require(receipt.get("signed") is False and receipt.get("platform") == "device"
            and receipt.get("configuration") == "Release"
            and receipt.get("parent_commit") == source and receipt.get("bundle_id") == bundle
            and receipt.get("version") == version and receipt.get("build_number") == build
            and receipt.get("artifact") == archive.name, "Archive provenance mismatch")
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    require(digest == receipt.get("artifact_sha256"), "Archive checksum mismatch")


def poll_build(store, app_id, build, version, deadline):
    query = urllib.parse.urlencode({"filter[app]": app_id, "filter[version]": build,
                                   "filter[preReleaseVersion.version]": version,
                                   "filter[preReleaseVersion.platform]": "VISION_OS"})
    while time.monotonic() < deadline:
        candidates = store.request("/builds?" + query)["data"]
        require(len(candidates) <= 1, "Ambiguous processed build")
        if candidates:
            item = candidates[0]
            state = item["attributes"]["processingState"]
            print(f"Apple processing: {state}", flush=True)
            require(state not in ("FAILED", "INVALID"), "Apple rejected the uploaded build; inspect App Store Connect")
            if state == "VALID":
                return item
        time.sleep(20)
    raise DeliveryError("Upload completed, but Apple processing is still pending; inspect TestFlight before uploading again")


def interrupted(signum, frame):
    raise DeliveryError("Delivery interrupted; removing temporary API credentials")


def main():
    directory = runner_directory()
    if sys.argv[1:] == ["--cleanup"]:
        cleanup(directory)
        return
    require(not sys.argv[1:], "Unexpected delivery arguments")
    # Limit credential lifetime to this process and Apple tools. No secrets in child environments.
    material = {name: os.environ.pop(name, "") for name in
                ("PLANK_ASC_KEY_ID", "PLANK_ASC_ISSUER_ID", "PLANK_ASC_PRIVATE_KEY")}
    require(all(material.values()), "Missing protected App Store Connect credentials")
    key_id, issuer = material["PLANK_ASC_KEY_ID"], material["PLANK_ASC_ISSUER_ID"]
    require(re.fullmatch(r"[A-Z0-9]{10}", key_id) and re.fullmatch(r"[A-Fa-f0-9-]{36}", issuer), "Invalid API key metadata")
    team = os.environ.get("PLANK_APPLE_TEAM_ID", "")
    app_id, group_id = os.environ.get("PLANK_VISION_APP_ID", ""), os.environ.get("PLANK_VISION_GROUP_ID", "")
    require(re.fullmatch(r"[A-Z0-9]{10}", team) and app_id.isdecimal() and re.fullmatch(r"[A-Za-z0-9-]+", group_id),
            "Configure the protected Team, App Store app and internal beta group first")
    source = os.environ["EXPECTED_SOURCE_SHA"]
    require(command("checkout verification", ["git", "rev-parse", "HEAD"]).decode().strip() == source,
            "Signing checkout does not match requested source")
    scratch = directory.parent
    incoming = scratch / "plank-vision-input"
    tar = incoming / "PlankVision.xcarchive.tar.gz"
    receipt = json.loads((incoming / "provenance.json").read_text())
    bundle, version, build = [os.environ[name] for name in
                             ("PLANK_NATIVE_BUNDLE_ID", "PLANK_NATIVE_VERSION", "PLANK_NATIVE_BUILD")]
    verify_receipt(receipt, tar, source, bundle, version, build)
    directory.mkdir(mode=0o700)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        key = directory / f"AuthKey_{key_id}.p8"
        with key.open("x") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(material.pop("PLANK_ASC_PRIVATE_KEY"))
        material.clear()
        store = Store(key, key_id, issuer)
        app = store.request(f"/apps/{app_id}")["data"]
        require(app["attributes"]["bundleId"] == bundle, "App Store application does not match this archive")
        group = store.request(f"/betaGroups/{group_id}?include=app")["data"]
        require(group["attributes"].get("isInternalGroup") is True
                and group["relationships"]["app"]["data"]["id"] == app_id,
                "Only this app's configured internal test group may receive builds")
        with tarfile.open(tar) as stream:
            require(all(Path(item.name).parts[0] == "PlankVision.xcarchive" for item in stream.getmembers()),
                    "Unexpected archive root")
            stream.extractall(directory, filter="data")
        archive = directory / "PlankVision.xcarchive"
        info = plistlib.loads((archive / "Products/Applications/PLANK.app/Info.plist").read_bytes())
        require(info["CFBundleIdentifier"] == bundle and info["CFBundleVersion"] == build
                and info["CFBundleShortVersionString"] == version, "Archived application metadata mismatch")
        options = directory / "ExportOptions.plist"
        options.write_bytes(plistlib.dumps({"method": "app-store-connect", "destination": "upload",
            "signingStyle": "automatic", "teamID": team, "manageAppVersionAndBuildNumber": False,
            "uploadSymbols": True, "testFlightInternalTestingOnly": True}))
        # Apple cloud signing: no developer's Keychain export or reusable private signing key on CI.
        command("TestFlight cloud signing/upload", ["xcodebuild", "-exportArchive", "-archivePath", str(archive),
            "-exportOptionsPlist", str(options), "-exportPath", str(directory / "export"),
            "-allowProvisioningUpdates", "-authenticationKeyPath", str(key),
            "-authenticationKeyID", key_id, "-authenticationKeyIssuerID", issuer])
        print("Vision archive uploaded; waiting for Apple processing", flush=True)
        item = poll_build(store, app_id, build, version, time.monotonic() + 25 * 60)
        # Never invent export-compliance answers for a new application.
        require(item["attributes"].get("usesNonExemptEncryption") is not None,
                "Apple processed the build. Complete its export-compliance questionnaire in TestFlight, then assign it to the internal group")
        store.request(f"/betaGroups/{group_id}/relationships/builds",
                      {"data": [{"type": "builds", "id": item["id"]}]})
        delivery = scratch / "plank-vision-delivery"
        delivery.mkdir()
        receipt.update(testflight_build_id=item["id"], processing_state="VALID", internal_group_assigned=True)
        (delivery / "testflight.json").write_text(json.dumps(receipt, indent=2) + "\n")
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(f"### PLANK Vision TestFlight\n\nVersion {version}, build {build}: processed and assigned to the internal group. "
                         "Install using TestFlight on Apple Vision Pro. No App Store release was submitted.\n")
    finally:
        material.clear()
        cleanup(directory)


if __name__ == "__main__":
    try:
        main()
    except (DeliveryError, OSError, ValueError, KeyError) as error:
        print("TestFlight: " + (str(error) if isinstance(error, DeliveryError) else "local setup/response validation failed"), file=sys.stderr)
        sys.exit(1)
