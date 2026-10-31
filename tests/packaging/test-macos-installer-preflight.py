#!/usr/bin/env python3
"""Check native Installer page wiring; optionally inspect the actual signed PKG."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
PACKAGING = ROOT / "packaging/host/macos"


class PreflightWiring(unittest.TestCase):
    def test_no_external_installer_javascript(self):
        distribution = ET.parse(PACKAGING / "distribution.xml.in").getroot()
        self.assertEqual(distribution.find("options").get("require-scripts"), "false")
        self.assertIsNone(distribution.find("options").get("allow-external-scripts"))
        self.assertIsNone(distribution.find("script"))
        self.assertIsNone(distribution.find("installation-check"))

    def test_requirements_precede_target_and_installation(self):
        sections = plistlib.loads((PACKAGING / "InstallerSections.plist").read_bytes())["SectionOrder"]
        self.assertEqual(sections, ["Introduction", "PLANKRequirements.bundle", "Target",
                                    "PackageSelection", "Install", "Summary"])
        info = plistlib.loads((PACKAGING / "installer-preflight-Info.plist.in").read_bytes())
        self.assertEqual(info["NSPrincipalClass"], "PLANKRequirementsSection")
        self.assertEqual(info["CFBundlePackageType"], "BNDL")


def check_package(package, bundle_checker):
    with tempfile.TemporaryDirectory(prefix="plank-installer-preflight-") as scratch:
        expanded = Path(scratch) / "expanded"
        subprocess.run(["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        distribution = ET.parse(expanded / "Distribution").getroot()
        if (distribution.find("options").get("allow-external-scripts") is not None or
                distribution.find("script") is not None):
            raise ValueError("External Installer JavaScript must not ship")
        sections = list(expanded.rglob("InstallerSections.plist"))
        if (len(sections) != 1 or plistlib.loads(sections[0].read_bytes()) !=
                plistlib.loads((PACKAGING / "InstallerSections.plist").read_bytes())):
            raise ValueError("Missing or incorrect native Installer page order")
        bundle = sections[0].parent / "PLANKRequirements.bundle"
        if not bundle.is_dir() or list(expanded.glob("*/Payload/**/PLANKRequirements.bundle")):
            raise ValueError("Requirements bundle must be Installer-only, never an installed payload")
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(bundle)], check=True)
        subprocess.run([str(bundle_checker), str(bundle)], check=True)
    print("macos_installer_native_preflight_package=pass installation=not-performed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--package", type=Path)
    parser.add_argument("--bundle-checker", type=Path)
    options, remaining = parser.parse_known_args()
    result = unittest.main(argv=[sys.argv[0], *remaining], exit=False).result
    if not result.wasSuccessful():
        sys.exit(1)
    if options.package:
        if not options.bundle_checker:
            parser.error("--package requires --bundle-checker")
        check_package(options.package, options.bundle_checker)
