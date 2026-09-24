#!/usr/bin/env python3
"""Portable permission regressions plus a real unsigned PKG roundtrip on macOS."""
import importlib.util
import os
from pathlib import Path
import platform
import plistlib
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "permissions", ROOT / "scripts/test/check-macos-host-permissions.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class Permissions(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name) / "payload"
        self.app = self.root / gate.APP
        # Deliberately reproduce a private builder's default, then explicitly
        # create distributable metadata. Private scratch stays owner-only.
        previous = os.umask(0o077)
        try:
            self.app.mkdir(parents=True)
            for directory in ("Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature",
                              gate.CAMERA + "/Contents/MacOS", gate.CAMERA + "/Contents/_CodeSignature"):
                (self.app / directory).mkdir(parents=True)
            for name in gate.REQUIRED_APP | gate.EXECUTABLES:
                path = self.app / name
                if not path.is_dir():
                    path.write_text("synthetic fixture\n")
            (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "org.example.permission-fixture",
                "CFBundleVersion": "1.0", "CFBundleExecutable": "plank-host",
                "CFBundlePackageType": "APPL",
            }))
            for role in ("machine", "desktop", "sign-in"):
                folder = "LaunchDaemons" if role == "machine" else "LaunchAgents"
                path = self.root / "Library" / folder / f"la.instinctual.PLANK.Host.{role}.plist"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("synthetic fixture\n")
            for name in ("Contents/Info.plist", "Contents/MacOS/plank-microphone", "Contents/_CodeSignature/CodeResources"):
                path = self.root / gate.DRIVER / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("synthetic fixture\n")
        finally:
            os.umask(previous)
        for path in [self.root, *self.root.rglob("*")]:
            relative = path.relative_to(self.app).as_posix() if path.is_relative_to(self.app) else ""
            driver_binary = path == self.root / gate.DRIVER / "Contents/MacOS/plank-microphone"
            path.chmod(0o755 if path.is_dir() or relative in gate.EXECUTABLES or driver_binary else 0o644)

    def bom(self):
        return "\n".join(
            f"{'.' if p == self.root else './' + p.relative_to(self.root).as_posix()}\t"
            f"{stat.filemode(p.lstat().st_mode)} "
            for p in [self.root, *self.root.rglob("*")])

    def test_valid(self):
        gate.check_tree(self.app, app_only=True)
        gate.check_tree(self.root)
        gate.check_bom(self.bom())
        self.assertEqual(stat.S_IMODE(Path(self.scratch.name).stat().st_mode), 0o700)

    def test_private_directory(self):
        for name in (".", gate.APP, gate.APP + "/Contents/_CodeSignature", "Library/LaunchAgents"):
            with self.subTest(name=name):
                path = self.root / name
                path.chmod(0o700)
                with self.assertRaises(ValueError):
                    gate.check_tree(self.root)
                with self.assertRaises(ValueError):
                    gate.check_bom(self.bom())
                path.chmod(0o755)

    def test_private_resource(self):
        for name in ("Contents/Resources/plank.icns", "Contents/_CodeSignature/CodeResources"):
            with self.subTest(name=name):
                path = self.app / name
                path.chmod(0o600)
                with self.assertRaises(ValueError):
                    gate.check_tree(self.root)
                with self.assertRaises(ValueError):
                    gate.check_bom(self.bom())
                path.chmod(0o644)

    def test_unsafe_write_and_missing_execute(self):
        path = self.app / "Contents/MacOS/plank-host"
        for mode in (0o777, 0o644, 0o4755):
            path.chmod(mode)
            with self.assertRaises(ValueError):
                gate.check_tree(self.root)

    def test_symlink(self):
        path = self.app / "Contents/Resources/plank.icns"
        path.unlink()
        path.symlink_to("../Info.plist")
        with self.assertRaises(ValueError):
            gate.check_tree(self.root)

    def test_missing(self):
        (self.app / "Contents/Info.plist").unlink()
        with self.assertRaises(ValueError):
            gate.check_tree(self.root)

    def test_bom_rejects_duplicate_and_traversal(self):
        for record in (".\tdrwxr-xr-x", "../escape\t-rw-r--r--"):
            with self.assertRaises(ValueError):
                gate.check_bom(self.bom() + "\n" + record)

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS pkgutil/pkgbuild")
    def test_real_package_roundtrip(self):
        package = Path(self.scratch.name) / "fixture.pkg"
        subprocess.run(["pkgbuild", "--root", str(self.root), "--identifier",
                        "org.example.permission-fixture", "--version", "1.0", str(package)], check=True)
        gate.check_package(package)


if __name__ == "__main__":
    unittest.main()
