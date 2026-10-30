#!/usr/bin/env python3
"""Exercise target selection and real Mach-O minimum-OS validation."""
import importlib.util
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    'target_check', ROOT / 'scripts/test/check-macos-client-target.py')
target_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(target_check)


class TargetSelection(unittest.TestCase):
    def run_target(self, target, sdk):
        script = '''
uname() { if [[ $1 == -s ]]; then echo Darwin; else echo arm64; fi; }
xcrun() { if [[ $* == *--show-sdk-version* ]]; then echo "$TEST_SDK"; else echo /sdk; fi; }
source "$1/scripts/build/macos-client-target.sh"
plank_macos_client_target || exit $?
echo "$MACOSX_DEPLOYMENT_TARGET"
'''
        env = dict(os.environ, TEST_SDK=sdk)
        env.pop('PLANK_MAC_CLIENT_MIN_MACOS', None)
        if target is not None:
            env['PLANK_MAC_CLIENT_MIN_MACOS'] = target
        return subprocess.run(['bash', '-c', script, 'test', str(ROOT)],
                              env=env, text=True, capture_output=True)

    def test_one_default_package_requires_new_sdk(self):
        result = self.run_target(None, '27.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '15.0')
        self.assertNotEqual(self.run_target(None, '26.2').returncode, 0)

    def test_explicit_target_does_not_lower_sdk_requirement(self):
        for sdk in ('27.0', '27.1', '28.0'):
            result = self.run_target('15.0', sdk)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '15.0')
        self.assertNotEqual(self.run_target('15.0', '26.2').returncode, 0)
        self.assertNotEqual(self.run_target('15.0', '14.5').returncode, 0)

    def test_rejects_unsupported_or_malformed_inputs(self):
        for target, sdk in [('14.0', '27.0'), ('27.0', '27.0'),
                            ('15;false', '27.0'), ('15.0', 'unknown')]:
            self.assertNotEqual(self.run_target(target, sdk).returncode, 0)

    def test_all_client_entrypoints_share_target_policy(self):
        for entrypoint in ('scripts/build/bootstrap-macos-client-deps.sh',
                           'scripts/build/build-macos-client.sh',
                           'scripts/package/build-macos-client-pkg.sh',
                           'scripts/package/stage-macos-client-dev.sh'):
            script = (ROOT / entrypoint).read_text()
            self.assertIn('/scripts/build/macos-client-target.sh"', script, entrypoint)
            self.assertIn('\nplank_macos_client_target\n', script, entrypoint)
            self.assertNotIn('PLANK_MAC_CLIENT_MIN_MACOS:-27.0', script, entrypoint)

    def test_host_default_is_independent_of_client_policy(self):
        host = (ROOT / 'scripts/build/build-macos-host.sh').read_text()
        self.assertIn('plank_macos_host_target', host)
        self.assertNotIn('macos-client-target.sh', host)
        transport = (ROOT / 'scripts/build/build-macos-transport.sh').read_text()
        self.assertIn('plank_macos_host_target', transport)
        policy = (ROOT / 'scripts/build/macos-host-target.sh').read_text()
        self.assertIn('PLANK_MACOS_HOST_MIN_OS:-26.7', policy)


@unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64',
                     'Requires Apple arm64 compiler')
class BinaryTarget(unittest.TestCase):
    def test_real_dependency_and_app_metadata(self):
        import plistlib
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'test.c'
            source.write_text('int sample(void) { return 0; }\n')
            library = root / 'test.dylib'
            for minimum, passed in [('13.0', True), ('15.0', True), ('26.0', False)]:
                subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64',
                                '-mmacosx-version-min=' + minimum, str(source),
                                '-o', str(library)], check=True, capture_output=True)
                self.assertEqual(target_check.check(root, '15.0')['passed'], passed)
            subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64',
                            '-mmacosx-version-min=15.0', str(source),
                            '-o', str(library)], check=True, capture_output=True)
            (root / 'Contents').mkdir()
            plist = root / 'Contents/Info.plist'
            for declared, passed in [('27.0', False), ('${MACOSX_DEPLOYMENT_TARGET}', False), ('15.0', True)]:
                plist.write_bytes(plistlib.dumps({'LSMinimumSystemVersion': declared}))
                self.assertEqual(target_check.check(root, '15.0')['passed'], passed)
            library.unlink()
            self.assertFalse(target_check.check(root, '15.0')['passed'])


if __name__ == '__main__':
    unittest.main()
