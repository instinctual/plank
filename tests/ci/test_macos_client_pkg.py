"""Keep the signed Client pipeline PKG-only without weakening package gates."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'scripts/package/build-macos-client-pkg.sh'


class MacClientPkgTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = PACKAGE.read_text()

    def test_shell_syntax(self):
        subprocess.run(['bash', '-n', str(PACKAGE)], check=True)

    def test_ci_uses_pkg_entrypoint(self):
        ci = (ROOT / 'scripts/ci/build.sh').read_text()
        self.assertIn('scripts/package/build-macos-client-pkg.sh', ci)
        self.assertNotIn('build-macos-client-dmg.sh', ci)
        self.assertFalse((ROOT / 'scripts/package/build-macos-client-dmg.sh').exists())

    def test_only_the_final_pkg_is_collected(self):
        self.assertIn('pkg="$output/plank-client_${PLANK_PACKAGE_VERSION}_arm64.pkg"', self.script)
        commands = [line for line in self.script.splitlines()
                    if line.startswith('plank_collect_package ')]
        self.assertEqual(commands, [
            'plank_collect_package "$source_root" client macos arm64 '
            '"macos-${PLANK_MAC_CLIENT_MIN_MACOS%%.*}" "$pkg"',
        ])
        for obsolete in ('hdiutil', '.dmg', '$dmg', '$output/image'):
            self.assertNotIn(obsolete, self.script)

    def test_single_notarization_retains_all_distribution_checks(self):
        required = (
            'codesign --verify --deep --strict "$app"',
            'productbuild --package',
            'pkgutil --check-signature "$pkg"',
            'xcrun notarytool submit "$pkg"',
            'test "$(plutil -extract status raw "$output/pkg-notary.json")" = Accepted',
            'xcrun stapler staple "$pkg"',
            'xcrun stapler validate "$pkg"',
            'spctl --assess --type install --verbose=2 "$pkg"',
            'shasum -a 256 "$pkg"',
            "echo 'macos_client_pkg_gate=pass install=not-performed'",
            'plank_collect_package ',
        )
        positions = [self.script.index(command) for command in required]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(self.script.count('xcrun notarytool submit '), 1)
        self.assertIn('--sign "$PLANK_MACOS_INSTALLER_IDENTITY" --timestamp "$pkg"', self.script)


if __name__ == '__main__':
    unittest.main()
