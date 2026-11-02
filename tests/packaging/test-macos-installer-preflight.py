#!/usr/bin/env python3
"""Check standard Installer packaging and FileVault rejection before changes."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
PACKAGING = ROOT / "packaging/host/macos"


def check_distribution(distribution):
    options = distribution.find("options")
    if (options is None or options.get("require-scripts") != "false" or
            options.get("allow-external-scripts") not in (None, "false") or
            any(distribution.find(tag) is not None
                for tag in ("script", "installation-check", "volume-check"))):
        raise ValueError("Installer must not run custom code before installation")


def check_expanded_package(expanded):
    check_distribution(ET.parse(expanded / "Distribution").getroot())
    if (list(expanded.rglob("InstallerSections.plist")) or
            list(expanded.rglob("PLANKRequirements.bundle")) or
            (expanded / "Plugins").exists()):
        raise ValueError("Custom Installer plug-ins must not ship")
    preinstalls = list(expanded.glob("*/Scripts/preinstall"))
    if (len(preinstalls) != 1 or
            preinstalls[0].read_bytes() != (PACKAGING / "pkg-preinstall").read_bytes()):
        raise ValueError("Missing or changed FileVault preinstall safeguard")


class InstallerPreflight(unittest.TestCase):
    def test_no_early_custom_code(self):
        check_distribution(ET.parse(PACKAGING / "distribution.xml.in").getroot())

    def test_packaged_plugins_and_missing_guard_are_rejected(self):
        with tempfile.TemporaryDirectory() as scratch:
            expanded = Path(scratch)
            (expanded / "Distribution").write_bytes((PACKAGING / "distribution.xml.in").read_bytes())
            script = expanded / "host-component.pkg/Scripts/preinstall"
            script.parent.mkdir(parents=True)
            script.write_bytes((PACKAGING / "pkg-preinstall").read_bytes())
            check_expanded_package(expanded)
            sections = expanded / "InstallerSections.plist"
            sections.write_text("unexpected custom page")
            with self.assertRaisesRegex(ValueError, "plug-ins"):
                check_expanded_package(expanded)
            sections.unlink()
            plugin = expanded / "Plugins"
            plugin.mkdir()
            with self.assertRaisesRegex(ValueError, "plug-ins"):
                check_expanded_package(expanded)
            plugin.rmdir()
            script.write_text("#!/bin/bash\nexit 0\n")
            with self.assertRaisesRegex(ValueError, "safeguard"):
                check_expanded_package(expanded)

    def test_filevault_must_be_confirmed_off_before_any_changes(self):
        cases = (("FileVault is Off.", 0, True),
                 ("FileVault is On.", 0, False),
                 ("Encryption in progress: 50%", 0, False),
                 ("Decryption in progress: 50%", 0, False),
                 ("Unknown status", 0, False),
                 ("", 1, False),
                 ("FileVault is Off.", 1, False))
        for status, exit_code, accepted in cases:
            with self.subTest(status=status, exit_code=exit_code), tempfile.TemporaryDirectory() as scratch:
                base = Path(scratch)
                calls = base / "calls"
                # Run the production preinstall with only its system-query
                # executable and service/filesystem helpers replaced by fixtures.
                query = base / "fdesetup"
                query.write_text('#!/bin/bash\n[[ $1 = status ]] || exit 99\n'
                                 'printf "%s\\n" "$FIXTURE_STATUS"\nexit "$FIXTURE_EXIT"\n')
                query.chmod(0o755)
                (base / "pkg-common.sh").write_text('''
fail() { echo "PLANK: $*" >&2; exit 1; }
record() { printf '%s\\n' "$1" >> "$FIXTURE_CALLS"; }
preflight() { [[ $1 = / ]] || fail 'Invalid fixture volume'; record preflight; }
initialize_state() { record initialize_state; }
console_uid() { echo 501; }
stop_roles() { record stop_roles; }
''')
                preinstall = base / "preinstall"
                preinstall.write_text((PACKAGING / "pkg-preinstall").read_text().replace(
                    "/usr/bin/fdesetup", shlex.quote(str(query))))
                result = subprocess.run(["/bin/bash", str(preinstall), "fixture.pkg", "/", "/"],
                                        env=dict(os.environ, FIXTURE_STATUS=status,
                                                 FIXTURE_EXIT=str(exit_code), FIXTURE_CALLS=str(calls)),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                self.assertEqual(calls.read_text().splitlines(),
                                 ["preflight", "initialize_state", "stop_roles"] if accepted else ["preflight"])
                if not accepted:
                    self.assertIn("FileVault", result.stderr)
                    self.assertIn("System Settings", result.stderr)


def check_package(package):
    with tempfile.TemporaryDirectory(prefix="plank-installer-preflight-") as scratch:
        expanded = Path(scratch) / "expanded"
        subprocess.run(["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        check_expanded_package(expanded)
    print("macos_installer_preflight_package=pass plugins=absent filevault_guard=retained installation=not-performed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--package", type=Path)
    options, remaining = parser.parse_known_args()
    result = unittest.main(argv=[sys.argv[0], *remaining], exit=False).result
    if not result.wasSuccessful():
        sys.exit(1)
    if options.package:
        check_package(options.package)
