#!/usr/bin/env python3
"""Run the real native installer against isolated, unprivileged filesystem fixtures."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
BINARY = os.environ["PLANK_CONFIGURE_TEST_BINARY"]
HOST_TEMPLATE = ROOT / "packaging/host/macos/config/plank-host.conf"
CLIENT_TEMPLATE = ROOT / "packaging/client/config/plank-client.conf"


class Configuration(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="plank-config-test-")
        self.root = Path(self.temporary.name).resolve()
        self.config, self.state = self.root / "etc", self.root / "state"
        self.state.mkdir(mode=0o755)
        self.state.chmod(0o755)
        self.uuid = str(uuid.uuid4())

    def tearDown(self):
        self.temporary.cleanup()

    def invoke(self, mode="host-prepare", success=True):
        result = subprocess.run([BINARY, mode, str(self.config), str(self.state),
            str(CLIENT_TEMPLATE if mode == "client" else HOST_TEMPLATE)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stderr)

    def legacy(self, **changes):
        values = dict(Address="0.0.0.0", Port=29999, Name="Example workstation", UUID=self.uuid)
        values.update(changes)
        path = self.state / "host.plist"
        path.write_bytes(plistlib.dumps(values))
        path.chmod(0o644)
        return path

    def snapshot(self):
        return {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}

    def test_fresh_and_idempotent(self):
        self.invoke("host-check")
        self.assertFalse(self.config.exists())
        self.invoke()
        self.assertEqual((self.config / "host.conf").read_bytes(), HOST_TEMPLATE.read_bytes())
        identity = plistlib.loads((self.state / "identity.plist").read_bytes())
        self.assertEqual(set(identity), {"UUID"})
        uuid.UUID(identity["UUID"])
        before = self.snapshot()
        self.invoke()
        self.invoke("host-finish")
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.state / "host.plist").exists())
        for p in (self.config, self.state):
            self.assertEqual(p.stat().st_mode & 0o777, 0o755)
        for p in (self.config / "host.conf", self.state / "identity.plist"):
            self.assertEqual(p.stat().st_mode & 0o777, 0o644)

    def test_legacy_conversion_retains_identity_until_payload_is_installed(self):
        legacy = self.legacy()
        tls = self.state / "SignIn"
        tls.mkdir(mode=0o700)
        key = tls / "key.pem"
        key.write_bytes(b"synthetic key fixture")
        key.chmod(0o600)
        self.invoke("host-check")
        self.invoke()
        self.assertTrue(legacy.exists())
        self.assertIn("port = 29999", (self.config / "host.conf").read_text())
        self.assertIn("host_name = Example workstation", (self.config / "host.conf").read_text())
        self.assertEqual(plistlib.loads((self.state / "identity.plist").read_bytes()), {"UUID": self.uuid})
        before = self.snapshot()
        self.invoke()  # Interrupted preinstall, retried before app replacement.
        self.assertEqual(before, self.snapshot())
        self.invoke("host-finish")
        self.assertFalse(legacy.exists())
        self.assertEqual(key.read_bytes(), b"synthetic key fixture")
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        self.invoke("host-finish")

    def test_custom_new_ini_wins_and_remains_byte_identical(self):
        self.legacy()
        self.config.mkdir(mode=0o755)
        self.config.chmod(0o755)
        custom = self.config / "host.conf"
        custom.write_bytes(b"# Keep my comment\n[network]\nport = 30123\n[general]\nhost_name = Custom\n")
        custom.chmod(0o644)
        original = custom.read_bytes()
        self.invoke()
        self.invoke("host-finish")
        self.assertEqual(custom.read_bytes(), original)

    def test_bad_legacy_rejected_without_new_identity(self):
        for changes in ({"Port": True}, {"Port": 65536}, {"UUID": "bad"}, {"Address": "127.0.0.1"},
                        {"Name": "bad\nname"}, {"Name": " padded "}, {"Extra": "unknown"}):
            self.legacy(**changes)
            before = self.snapshot()
            self.invoke(success=False)
            self.assertEqual(self.snapshot(), before)

    def test_conflicting_uuid_never_reset(self):
        self.invoke()
        self.legacy()
        before = self.snapshot()
        for mode in ("host-prepare", "host-check", "host-finish"):
            self.invoke(mode, success=False)
            self.assertEqual(before, self.snapshot())

    def test_existing_tls_without_uuid_fails_closed(self):
        (self.state / "SignIn").mkdir(mode=0o700)
        self.invoke(success=False)
        self.assertFalse((self.state / "identity.plist").exists())

    def test_invalid_current_file_cannot_trigger_legacy_fallback(self):
        self.legacy()
        self.invoke()
        path = self.config / "host.conf"
        for data in (b"[network]\nport=0", b"[video]\ncapture=anything", b"x" * 32769):
            path.write_bytes(data)
            before = self.snapshot()
            self.invoke(success=False)
            self.invoke("host-finish", success=False)
            self.assertEqual(before, self.snapshot())

    def test_permissions_and_hardlinks(self):
        self.invoke()
        for path in (self.config / "host.conf", self.state / "identity.plist"):
            path.chmod(0o666)
            self.invoke(success=False)
            path.chmod(0o644)
            alias = self.root / "hardlink"
            os.link(path, alias)
            self.invoke(success=False)
            alias.unlink()
        self.config.chmod(0o775)
        self.invoke(success=False)
        self.config.chmod(0o755)
        self.invoke()

    def test_symlink_files_and_parents_rejected(self):
        outside = self.root / "outside"
        outside.write_bytes(b"unchanged")
        self.config.mkdir(mode=0o755)
        self.config.chmod(0o755)
        link = self.config / "host.conf"
        link.symlink_to(outside)
        self.invoke(success=False)
        self.assertEqual(outside.read_bytes(), b"unchanged")
        link.unlink()
        self.config.rmdir()
        self.config.symlink_to(self.state, target_is_directory=True)
        self.invoke(success=False)
        self.config.unlink()
        parent = self.root / "linked-parent"
        parent.symlink_to(self.state, target_is_directory=True)
        self.config = parent / "child"
        self.invoke(success=False)
        self.assertFalse((self.state / "child").exists())

    def test_client_default_and_custom_policy_preserved(self):
        self.invoke("client")
        path = self.config / "client.conf"
        self.assertEqual(path.read_bytes(), CLIENT_TEMPLATE.read_bytes())
        self.assertFalse((self.state / "identity.plist").exists())
        for custom in (b"# private administrator additions\n[network]\nport=30001\n", b""):
            path.write_bytes(custom)
            self.invoke("client")
            self.assertEqual(path.read_bytes(), custom)
        path.chmod(0o666)
        self.invoke("client", success=False)

    def test_host_client_coexist(self):
        self.invoke("client")
        before = (self.config / "client.conf").read_bytes()
        self.invoke()
        host_before = self.snapshot()
        self.invoke("client")
        self.assertEqual(self.snapshot(), host_before)
        self.assertEqual((self.config / "client.conf").read_bytes(), before)

    def test_client_installer_payload_roundtrip(self):
        # Build and expand a synthetic package, never run Installer or touch /etc.
        payload = self.root / "payload"
        app = payload / "Applications/PLANK Client.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "la.instinctual.PLANK.Client", "CFBundleVersion": "1.1.015",
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "plank-client", "LSMinimumSystemVersion": "15.0"}))
        shutil.copyfile(BINARY, app / "Contents/MacOS/plank-client")
        (app / "Contents/MacOS/plank-client").chmod(0o755)
        shutil.copyfile(CLIENT_TEMPLATE, app / "Contents/Resources/client.conf.example")
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(ROOT / "packaging/client/macos/pkg-preinstall", scripts / "preinstall")
        (scripts / "preinstall").chmod(0o755)
        shutil.copyfile(BINARY, scripts / "plank-configure")
        (scripts / "plank-configure").chmod(0o755)
        shutil.copyfile(CLIENT_TEMPLATE, scripts / "client.conf.example")
        component = self.root / "client-component.pkg"
        product = self.root / "client.pkg"
        requirements = self.root / "requirements.plist"
        requirements.write_text((ROOT / "packaging/client/macos/requirements.plist.in").read_text().replace("@MIN_VERSION@", "15.0"))
        for command in (
            ["pkgbuild", "--root", str(payload), "--component-plist", str(ROOT / "packaging/client/macos/component.plist"),
             "--scripts", str(scripts), "--identifier", "la.instinctual.PLANK.Client", "--version", "1.1.015",
             "--install-location", "/", "--ownership", "recommended", str(component)],
            ["productbuild", "--package", str(component), "--product", str(requirements), str(product)],
            ["pkgutil", "--expand-full", str(product), str(self.root / "expanded")]):
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
        expanded = self.root / "expanded"
        self.assertEqual(len(list(expanded.rglob("client.conf.example"))), 2)
        self.assertEqual(len(list(expanded.rglob("preinstall"))), 1)
        self.assertFalse(list(expanded.rglob("LaunchAgents")))
        self.assertFalse(list(expanded.rglob("LaunchDaemons")))
        self.assertFalse(list(expanded.rglob("client.conf")))  # Config created only if absent, never overwritten by payload.
        info = next(expanded.rglob("PackageInfo")).read_text()
        self.assertNotIn("<relocate>", info)
        self.assertIn("arm64", (expanded / "Distribution").read_text())
        self.assertIn("15.0", (expanded / "Distribution").read_text())


if __name__ == "__main__":
    unittest.main()
