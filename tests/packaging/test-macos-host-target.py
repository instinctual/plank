#!/usr/bin/env python3
"""Host backport floors, sealed installer policy and real binary rejection."""
import importlib.util
import os
from pathlib import Path
import plistlib
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    'binary_target', ROOT / 'scripts/test/check-macos-client-target.py')
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class HostTarget(unittest.TestCase):
    def select(self, target=None, system='27.0', sdk='27.0', arch='arm64'):
        script = '''
set -euo pipefail
uname() { if [[ $1 = -s ]]; then echo Darwin; else echo "$TEST_ARCH"; fi; }
sw_vers() { echo "$TEST_SYSTEM"; }
xcrun() { if [[ $* = *--show-sdk-version* ]]; then echo "$TEST_SDK"; else echo /sdk; fi; }
source "$1/scripts/build/macos-host-target.sh"
plank_macos_host_target
echo "$MACOSX_DEPLOYMENT_TARGET"
'''
        env = dict(os.environ, TEST_SYSTEM=system, TEST_SDK=sdk, TEST_ARCH=arch)
        env.pop('PLANK_MACOS_HOST_MIN_OS', None)
        if target is not None:
            env['PLANK_MACOS_HOST_MIN_OS'] = target
        return subprocess.run(['bash', '-c', script, 'test', str(ROOT)],
                              env=env, capture_output=True, text=True)

    def test_one_default_package_supports_26_7_and_newer(self):
        self.assertEqual(self.select().stdout.strip(), '26.7')
        for system in ('26.7', '26.7.1', '27.0', '28.0'):
            result = self.select(system=system)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '26.7')
        self.assertEqual(self.select('27.0').stdout.strip(), '27.0')
        self.assertNotEqual(self.select('27.0', system='26.7').returncode, 0)

    def test_rejects_older_os_sdk_architecture_and_malformed_targets(self):
        for arguments in (
            {'system': '26.6'}, {'system': '15.7'}, {'system': 'unknown'},
            {'sdk': '26.2'}, {'sdk': 'unknown'}, {'arch': 'x86_64'},
        ):
            self.assertNotEqual(self.select('26.7', **arguments).returncode, 0)
        for target in ('26.0', '26.6', '15.0', '26.7;false', 'unknown'):
            self.assertNotEqual(self.select(target).returncode, 0)

    def test_default_bundle_metadata_matches_shared_floor(self):
        minimum = self.select().stdout.strip()
        for name in ('host-info.plist', 'microphone-info.plist', 'output-info.plist'):
            with self.subTest(bundle=name):
                info = plistlib.loads((ROOT / 'packaging/host/macos' / name).read_bytes())
                self.assertEqual(info['LSMinimumSystemVersion'], minimum)

    def test_installer_uses_sealed_floor_and_rejects_unknown_values(self):
        template = (ROOT / 'packaging/host/macos/pkg-common.sh').read_text()
        for minimum in ('26.7', '27.0', 'unknown'):
            for system in ('26.6', '26.7', '26.7.1', '27.0'):
                for arch in ('arm64', 'x86_64'):
                    # Source pure policy only; never call preflight or installer.
                    with tempfile.TemporaryDirectory() as temporary:
                        policy = Path(temporary) / 'pkg-common.sh'
                        policy.write_text(template.replace('@MIN_MACOS@', minimum))
                        result = subprocess.run([
                            'bash', '-c', 'source "$1"; platform_compatible "$2" "$3"',
                            'test', str(policy), system, arch,
                        ], capture_output=True)
                    accepted = (minimum != 'unknown' and arch == 'arm64' and
                                tuple(map(int, system.split('.'))) >=
                                tuple(map(int, minimum.split('.'))))
                    self.assertEqual(result.returncode == 0, accepted,
                                     (minimum, system, arch))

    def test_camera_metadata_matches_candidate_without_changing_entitlements(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            for minimum in ('default', '26.7', '27.0'):
                output = base / minimum
                output.mkdir()
                app = output / 'Host.app'
                (app / 'Contents').mkdir(parents=True)
                arguments = [
                    'python3', str(ROOT / 'scripts/package/prepare-macos-camera.py'),
                    '--app', str(app), '--output', str(output), '--version', '1.2.02',
                    '--team', 'PLANKTEST0', '--identity', '-',
                ]
                if minimum != 'default':
                    arguments += ['--minimum-macos', minimum]
                subprocess.run(arguments, check=True, capture_output=True)
                extension = app / 'Contents/Library/SystemExtensions/la.instinctual.PLANK.Host.Camera.systemextension'
                info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
                self.assertEqual(info['LSMinimumSystemVersion'],
                                 '26.7' if minimum == 'default' else minimum)
            self.assertEqual((base / '26.7/camera-host-entitlements.plist').read_bytes(),
                             (base / '27.0/camera-host-entitlements.plist').read_bytes())
            self.assertEqual((base / '26.7/camera-extension-entitlements.plist').read_bytes(),
                             (base / '27.0/camera-extension-entitlements.plist').read_bytes())


@unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64',
                     'Requires Apple arm64 compiler')
class HostBinaryTarget(unittest.TestCase):
    def test_newer_linked_binary_or_bundle_metadata_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'test.c'
            source.write_text('int sample(void) { return 0; }\n')
            (root / 'Contents').mkdir()
            metadata = root / 'Contents/Info.plist'
            metadata.write_bytes(plistlib.dumps({'LSMinimumSystemVersion': '26.7'}))
            for minimum, passed in [('26.7', True), ('27.0', False)]:
                subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64',
                                '-mmacosx-version-min=' + minimum, str(source),
                                '-o', str(root / 'test.dylib')], check=True, capture_output=True)
                self.assertEqual(CHECKER.check(root, '26.7')['passed'], passed)


if __name__ == '__main__':
    unittest.main()
