"""Keep standalone Host checks aligned with the production-source test build."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HostSourceGateTests(unittest.TestCase):
    def test_macos_microphone_consumers_link_the_signing_requirement(self):
        for name in ('scripts/build/build-macos-host.sh',
                     'scripts/test/build-macos-preview.sh',
                     'scripts/test/build-macos-native-video.sh'):
            with self.subTest(script=name):
                build = (ROOT / name).read_text()
                self.assertIn('apps/host/macos/media/microphone-session.m', build)
                self.assertIn('apps/host/macos/session/agent-registry.m', build)

    def test_pam_channel_gate_uses_the_pam_suite_language_standard(self):
        suite = (ROOT / 'tests/session/pam/CMakeLists.txt').read_text()
        standard = re.search(r'set\(CMAKE_CXX_STANDARD (\d+)\)', suite).group(1)
        build = (ROOT / 'scripts/build/build-host-package-binaries.sh').read_text()
        command = build.split('"$repo_dir/tests/session/test-pam-broker-channel.cpp"', 1)[0]
        command = command.rsplit('/opt/rh/gcc-toolset-14/root/usr/bin/g++', 1)[1]
        self.assertEqual(re.findall(r'-std=c\+\+(\d+)', command), [standard])


if __name__ == '__main__':
    unittest.main()
