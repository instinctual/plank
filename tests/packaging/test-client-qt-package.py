#!/usr/bin/env python3
"""Disposable, uninstalled DEB fixtures; no product build/installation claim."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('qt_package', ROOT / 'scripts/test/check-client-qt-package.py')
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


@unittest.skipUnless(shutil.which('dpkg-deb'), 'requires the Ubuntu package tool')
class QtPackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.stage = self.root / 'stage'
        self.stage.mkdir()
        for name in AUDIT.EXACT:
            self.write(name, 'fixture\n')
        self.write('usr/lib/plank-client-qt/libfixture.so.1', 'fixture\n')
        (self.stage / 'usr/lib/plank-client-qt/libfixture.so').symlink_to('libfixture.so.1')
        desktop = f'usr/share/applications/{AUDIT.DESKTOP}.desktop'
        self.write(desktop, (ROOT / f'packaging/client/linux/qt/{AUDIT.DESKTOP}.desktop').read_text())
        self.control = ('Package: plank-client-qt\nVersion: 1.1.041-ubuntu-qt-session\n'
                        'Architecture: amd64\nMaintainer: Fixture <fixture@example.invalid>\n'
                        'Description: Uninstalled package fixture\n')
        self.write('DEBIAN/control', self.control)
        self.write('DEBIAN/conffiles', '/etc/plank/client-qt.conf\n')
        for name in ('postinst', 'postrm'):
            self.write('DEBIAN/' + name, (ROOT / 'packaging/client/linux/deb' / name).read_text())
            (self.stage / 'DEBIAN' / name).chmod(0o755)

    def write(self, relative, data):
        path = self.stage / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)

    def package(self):
        destination = self.root / 'fixture.deb'
        subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(self.stage), str(destination)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return destination

    def test_separate_namespace(self):
        self.assertIn('usr/bin/plank-client-qt', AUDIT.validate(self.package()))

    def test_rejects_production_files(self):
        self.write('etc/plank/client.conf', 'production collision\n')
        with self.assertRaisesRegex(ValueError, 'outside experimental namespace'):
            AUDIT.validate(self.package())

    def test_rejects_production_library_directory(self):
        self.write('usr/lib/plank/libfixture.so.1', 'production collision\n')
        with self.assertRaisesRegex(ValueError, 'unexpected directory'):
            AUDIT.validate(self.package())

    def test_rejects_replacement_metadata(self):
        self.write('DEBIAN/control', self.control + 'Replaces: plank-client\n')
        with self.assertRaisesRegex(ValueError, 'Replaces'):
            AUDIT.validate(self.package())

    def test_rejects_wrong_config_ownership(self):
        self.write('DEBIAN/conffiles', '/etc/plank/client.conf\n')
        with self.assertRaisesRegex(ValueError, 'conffile'):
            AUDIT.validate(self.package())

    def test_rejects_deletion_hook(self):
        self.write('DEBIAN/postrm', '#!/bin/sh\nexit 0\n')
        with self.assertRaisesRegex(ValueError, 'lifecycle script'):
            AUDIT.validate(self.package())

    def test_rejects_url_registration(self):
        self.write(f'usr/share/applications/{AUDIT.DESKTOP}.desktop',
                   (ROOT / f'packaging/client/linux/qt/{AUDIT.DESKTOP}.desktop').read_text() +
                   'MimeType=x-scheme-handler/plank;\n')
        with self.assertRaisesRegex(ValueError, 'URL handlers'):
            AUDIT.validate(self.package())

    def test_rejects_cross_namespace_symlink(self):
        link = self.stage / 'usr/lib/plank-client-qt/libfixture.so'
        link.unlink()
        link.symlink_to('../plank/libfixture.so.1')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            AUDIT.validate(self.package())

    def test_compares_real_package_payloads(self):
        candidate = self.package()
        production = self.root / 'production'
        production.mkdir()
        (production / 'DEBIAN').mkdir()
        (production / 'DEBIAN/control').write_text(self.control.replace('plank-client-qt', 'plank-client'))
        (production / 'usr/bin').mkdir(parents=True)
        (production / 'usr/bin/plank-client').write_text('production\n')
        output = self.root / 'production.deb'
        def build():
            subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(production), str(output)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        build()
        AUDIT.validate(candidate, output)
        (production / 'usr/bin/plank-client-qt').write_text('collision\n')
        build()
        with self.assertRaisesRegex(ValueError, 'overlaps production'):
            AUDIT.validate(candidate, output)


class IdentityContractTests(unittest.TestCase):
    def test_build_and_package_share_names(self):
        for variant, expected in [('production', ['plank-client', 'PLANK', 'client.conf', 'plank']),
                                  ('qt', ['plank-client-qt', 'PLANK Client Qt', 'client-qt.conf', 'plank-client-qt'])]:
            values = subprocess.check_output(['bash', '-c',
                'source "$1"; plank_client_package_identity; '
                'printf "%s\\n" "$client_package" "$client_app_name" "$client_config" "$client_lib_name"',
                'fixture', str(ROOT / 'scripts/package/client-package-identity.sh')],
                text=True, env={**os.environ, 'PLANK_CLIENT_VARIANT': variant})
            self.assertEqual(values.splitlines(), expected)


if __name__ == '__main__':
    unittest.main()
