#!/usr/bin/env python3
"""Protect approved artwork and exercise Apple's real ICNS conversion on macOS."""
import hashlib
from pathlib import Path
import platform
import plistlib
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "branding/assets"
APPROVED = {
    "host": "b0ccbfda00574584bc78ed264267d994e35d5f92fe4a1d1943e301c9bca40afd",
    "client": "767155d871df145c483c934690d0d0da5c683254a1fb7173fba5b71642a579c6",
}
ORIGINAL = "85d2272d664e0894102f307afc5743b0b86ee478d4e5d7c1edb0d6cc16348c70"


def png_dimensions(path):
    with path.open("rb") as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError("Not a PNG with an IHDR")
    return struct.unpack(">II", header[16:24])


class SourceIcons(unittest.TestCase):
    def test_approved_pair_is_retained_without_modification(self):
        for role, digest in APPROVED.items():
            with self.subTest(role=role):
                path = ASSETS / f"plank-{role}-macos.png"
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)
                self.assertEqual(png_dimensions(path), (1254, 1254))
        self.assertEqual(len(set(APPROVED.values())), 2)

    def test_original_and_linux_artwork_are_unchanged(self):
        self.assertEqual(hashlib.sha256((ASSETS / "plank-logo.png").read_bytes()).hexdigest(), ORIGINAL)
        # Host-only builds deliberately do not initialize the Client submodule.
        runtime = ROOT / "apps/client/app/res/plank-logo.png"
        if runtime.is_file():
            self.assertEqual(hashlib.sha256(runtime.read_bytes()).hexdigest(), ORIGINAL)
        for script in ("scripts/build/build-client-package-binaries.sh",
                       "scripts/package/build-client-deb.sh"):
            self.assertIn("branding/assets/plank-logo.png", (ROOT / script).read_text())

    def test_host_chooses_host_icon_before_signing(self):
        build = (ROOT / "scripts/build/build-macos-host.sh").read_text()
        self.assertIn("branding/assets/plank-host-macos.png", build)
        self.assertNotIn("branding/assets/plank-logo.png", build)
        self.assertIn("Contents/Resources/plank.icns", build)
        self.assertLess(build.index("iconutil -c icns"),
                        build.index('--entitlements "$output/camera-host-entitlements.plist"'))
        info = plistlib.loads((ROOT / "packaging/host/macos/host-info.plist").read_bytes())
        self.assertEqual(info["CFBundleIconFile"], "plank.icns")

    def test_client_base_build_chooses_client_icon(self):
        build = (ROOT / "scripts/build/build-macos-client.sh").read_text()
        self.assertIn("branding/assets/plank-client-macos.png", build)
        self.assertNotIn("branding/assets/plank-logo.png", build)
        self.assertIn("Set :CFBundleIconFile plank", build)
        self.assertIn('rm "$resources/moonlight.icns"', build)
        self.assertLess(build.index("make -j"), build.index("iconutil -c icns"))

    def test_packagers_inherit_the_base_client_icon(self):
        for path in ("scripts/package/build-macos-client-dmg.sh",
                     "scripts/package/stage-macos-client-dev.sh"):
            script = (ROOT / path).read_text()
            self.assertIn("scripts/build/build-macos-client.sh", script)
            self.assertIn('ditto "$build/app/plank-client.app" "$app"', script)
            self.assertNotIn("macos-app-icon.m", script)
        script = (ROOT / "scripts/package/build-macos-client-dmg.sh").read_text()
        self.assertIn('cmp "$build/app/plank-client.app/Contents/Resources/plank.icns"', script)

    def test_icon_gate_runs_in_both_mac_builds(self):
        for role in APPROVED:
            script = (ROOT / f"scripts/build/build-macos-{role}.sh").read_text()
            self.assertIn("tests/packaging/test-macos-app-icons.py", script)


@unittest.skipUnless(platform.system() == "Darwin", "Requires Apple's icon compiler")
class NativeIcons(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="plank-icon-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.work = Path(cls.temporary.name)
        cls.converter = cls.work / "macos-app-icon"
        subprocess.run([
            "xcrun", "clang", "-fobjc-arc", "-mmacosx-version-min=15.0",
            "-Wall", "-Wextra", "-Werror", str(ROOT / "scripts/package/macos-app-icon.m"),
            "-framework", "Foundation", "-framework", "CoreGraphics",
            "-framework", "ImageIO", "-o", str(cls.converter),
        ], check=True, capture_output=True)

    def test_approved_icons_compile_and_roundtrip_all_sizes(self):
        expected = {
            f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png": (base * scale,) * 2
            for base in (16, 32, 128, 256, 512) for scale in (1, 2)
        }
        largest = []
        for role in APPROVED:
            with self.subTest(role=role):
                iconset = self.work / f"{role}.iconset"
                iconset.mkdir()
                subprocess.run([str(self.converter), str(ASSETS / f"plank-{role}-macos.png"),
                                str(iconset)], check=True, capture_output=True)
                self.assertEqual({p.name for p in iconset.iterdir()}, set(expected))
                for name, size in expected.items():
                    self.assertEqual(png_dimensions(iconset / name), size)
                package = self.work / f"{role}.icns"
                subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(package)],
                               check=True, capture_output=True)
                data = package.read_bytes()
                self.assertEqual(data[:4], b"icns")
                self.assertEqual(struct.unpack(">I", data[4:8])[0], len(data))
                roundtrip = self.work / f"{role}-roundtrip.iconset"
                subprocess.run(["iconutil", "-c", "iconset", str(package), "-o", str(roundtrip)],
                               check=True, capture_output=True)
                for name, size in expected.items():
                    self.assertEqual(png_dimensions(roundtrip / name), size)
                largest.append((roundtrip / "icon_512x512@2x.png").read_bytes())
        self.assertNotEqual(largest[0], largest[1])

    def test_missing_input_fails_without_output(self):
        output = self.work / "missing-input.iconset"
        output.mkdir()
        result = subprocess.run([str(self.converter), str(self.work / "missing.png"), str(output)],
                                capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(output.iterdir()), [])

    def test_missing_output_directory_fails(self):
        result = subprocess.run([str(self.converter), str(ASSETS / "plank-host-macos.png"),
                                 str(self.work / "missing-output.iconset")], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
