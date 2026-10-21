#!/usr/bin/env python3
"""Disposable package-upgrade fixtures; no real product installation claim."""
import importlib.util
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
        self.write('usr/lib/plank/libfixture.so.1', 'fixture\n')
        (self.stage / 'usr/lib/plank/libfixture.so').symlink_to('libfixture.so.1')
        self.desktop = ('[Desktop Entry]\nName=PLANK Client\nExec=plank-client\n'
                        'Icon=plank-client\nStartupWMClass=' + AUDIT.DESKTOP + '\n')
        self.write(f'usr/share/applications/{AUDIT.DESKTOP}.desktop', self.desktop)
        self.control = ('Package: plank-client\nVersion: 1.2.00\n'
                        'Architecture: amd64\nMaintainer: Fixture <fixture@example.invalid>\n'
                        'Description: Uninstalled package fixture\n')
        self.write('DEBIAN/control', self.control)
        self.write('DEBIAN/conffiles', '/etc/plank/client.conf\n')
        for name in ('postinst', 'postrm'):
            self.write('DEBIAN/' + name, (ROOT / 'packaging/client/linux/deb' / name).read_text())
            (self.stage / 'DEBIAN' / name).chmod(0o755)

    def write(self, relative, data):
        path = self.stage / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)

    def package(self, name='fixture'):
        destination = self.root / (name + '.deb')
        subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(self.stage), str(destination)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return destination

    def test_normal_identity_for_main_and_feature_builds(self):
        for version in ('1.2.00', '1.2.01-qt-fix'):
            with self.subTest(version=version):
                self.write('DEBIAN/control', self.control.replace('1.2.00', version))
                self.assertIn('usr/bin/plank-client', AUDIT.validate(self.package()))

    def test_rejects_separate_package(self):
        self.write('DEBIAN/control', self.control.replace('Package: plank-client\n',
                                                         'Package: plank-client-qt\n'))
        with self.assertRaisesRegex(ValueError, 'ordinary plank-client'):
            AUDIT.validate(self.package())

    def test_rejects_separate_configuration(self):
        self.write('etc/plank/client-qt.conf', 'obsolete configuration\n')
        with self.assertRaisesRegex(ValueError, 'outside Client namespace'):
            AUDIT.validate(self.package())

    def test_rejects_separate_library_directory(self):
        self.write('usr/lib/plank-client-qt/libfixture.so.1', 'obsolete library\n')
        with self.assertRaisesRegex(ValueError, 'unexpected directory'):
            AUDIT.validate(self.package())

    def test_rejects_replacement_metadata(self):
        self.write('DEBIAN/control', self.control + 'Replaces: unrelated-product\n')
        with self.assertRaisesRegex(ValueError, 'Replaces'):
            AUDIT.validate(self.package())

    def test_rejects_wrong_config_ownership(self):
        self.write('DEBIAN/conffiles', '/usr/bin/plank-client\n')
        with self.assertRaisesRegex(ValueError, 'conffile'):
            AUDIT.validate(self.package())

    def test_rejects_unreviewed_hook(self):
        self.write('DEBIAN/postrm', '#!/bin/sh\nexit 0\n')
        with self.assertRaisesRegex(ValueError, 'lifecycle script'):
            AUDIT.validate(self.package())

    def test_rejects_url_registration(self):
        self.write(f'usr/share/applications/{AUDIT.DESKTOP}.desktop',
                   self.desktop + 'MimeType=x-scheme-handler/plank;\n')
        with self.assertRaisesRegex(ValueError, 'URL handlers'):
            AUDIT.validate(self.package())

    def test_rejects_cross_namespace_symlink(self):
        link = self.stage / 'usr/lib/plank/libfixture.so'
        link.unlink()
        link.symlink_to('../plank-client-qt/libfixture.so.1')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            AUDIT.validate(self.package())

    def test_upgrade_preserves_admin_and_user_state(self):
        # Synthetic files in an isolated dpkg root; hooks must honor DPKG_ROOT.
        self.write('DEBIAN/control', self.control.replace('1.2.00', '1.1.039'))
        self.write('usr/bin/plank-client', 'old client\n')
        previous = self.package('previous')
        self.write('DEBIAN/control', self.control)
        self.write('usr/bin/plank-client', 'Qt client\n')
        # Package default changed; the administrator's conffile still wins.
        self.write('etc/plank/client.conf', 'new default\n')
        candidate = self.package('candidate')
        AUDIT.validate(candidate)
        install_root = self.root / 'installed'
        install_root.mkdir()
        def dpkg(*args):
            subprocess.run(['dpkg', '--root=' + str(install_root), '--force-not-root',
                            '--force-script-chrootless', '--force-confold', *args], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        dpkg('--install', str(previous))
        preserved = {
            'etc/plank/client.conf': 'administrator configuration\n',
            'home/test/.config/Instinctual/PLANK.conf': 'bookmarks and preferences\n',
            'home/test/.local/share/PLANK/pinned-host.pem': 'existing trusted certificate\n',
        }
        for name, content in preserved.items():
            target = install_root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        dpkg('--install', str(candidate))
        self.assertEqual((install_root / 'usr/bin/plank-client').read_text(), 'Qt client\n')
        self.assertFalse((install_root / 'usr/bin/plank-client-qt').exists())
        status = subprocess.check_output(['dpkg-query', '--admindir=' + str(install_root / 'var/lib/dpkg'),
                                         '-W', '-f=${Version} ${Status}', 'plank-client'], text=True)
        self.assertEqual(status, '1.2.00 install ok installed')
        for name, content in preserved.items():
            self.assertEqual((install_root / name).read_text(), content)
        dpkg('--remove', 'plank-client')
        self.assertFalse((install_root / 'usr/bin/plank-client').exists())
        for name, content in preserved.items():
            self.assertEqual((install_root / name).read_text(), content)


class IdentityContractTests(unittest.TestCase):
    def test_integrated_source_is_required_for_ordinary_package(self):
        result = subprocess.run(['bash', '-c',
            'source "$1"; plank_client_require_session_runtime "$2"',
            'fixture', str(ROOT / 'scripts/package/client-package-identity.sh'), str(ROOT / 'apps/client')],
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('client_qt_runtime_gate=pass', result.stdout)
        for relative in ('scripts/build/build-client-package-binaries.sh',
                         'scripts/package/build-client-deb.sh'):
            self.assertIn('plank_client_require_session_runtime', (ROOT / relative).read_text())
        self.assertIn('--binary "$moonlight_binary"', (ROOT / 'scripts/package/build-client-deb.sh').read_text())

    def test_rejects_a_renamed_sdl_session(self):
        spec = importlib.util.spec_from_file_location('runtime', ROOT / 'scripts/test/check-client-qt-runtime.py')
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            for name in ('app/app.pro', 'app/streaming/session.cpp', 'app/streaming/qt/sessionruntime.cpp'):
                target = source / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text((ROOT / 'apps/client' / name).read_text())
            runtime.check_source(source)
            session = source / 'app/streaming/session.cpp'
            session.write_text(session.read_text().replace('runtime->start(qtWindow);', 'execInternal();'))
            with self.assertRaisesRegex(ValueError, 'ordinary session loop'):
                runtime.check_source(source)

    @unittest.skipUnless(shutil.which('nm'), 'requires binary inspection tool')
    def test_rejects_a_binary_without_qt_session_owners(self):
        spec = importlib.util.spec_from_file_location('runtime', ROOT / 'scripts/test/check-client-qt-runtime.py')
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        with self.assertRaises(ValueError):
            runtime.check_binary(Path('/usr/bin/true'))

    def test_build_and_package_share_normal_identity(self):
        values = subprocess.check_output(['bash', '-c',
            'source "$1"; plank_client_package_identity; '
            'printf "%s\\n" "$client_package" "$client_app_name" "$client_config" "$client_lib_name"',
            'fixture', str(ROOT / 'scripts/package/client-package-identity.sh')], text=True)
        self.assertEqual(values.splitlines(), ['plank-client', 'PLANK', 'client.conf', 'plank'])


if __name__ == '__main__':
    unittest.main()
