"""Exercise source gates without compiling a client or preparing dependencies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ClientSourceGateTests(unittest.TestCase):
    def test_source_gate_rejects_sdl_api_and_link_inputs(self):
        for filename, content in (('code.cpp', 'SDL_GetTicks();'),
                                  ('app.pro', 'PKGCONFIG += sdl3'),
                                  ('audio.mm', '#include <SDL3/SDL.h>')):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as tmp:
                app = Path(tmp) / 'app'
                app.mkdir()
                (app / filename).write_text(content)
                result = subprocess.run(['python3', str(ROOT / 'scripts/test/check-client-no-sdl.py'), tmp],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                (app / filename).write_text('// SDL_GetTicks historical attribution\n')
                result = subprocess.run(['python3', str(ROOT / 'scripts/test/check-client-no-sdl.py'), tmp],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_svg_reader_is_an_explicit_build_and_runtime_dependency(self):
        for filename in ('scripts/ci/install-linux-deps.sh',
                         'docs/development/build/builder-vm-bootstrap.md',
                         'packaging/client/linux/deb/control.in',
                         'scripts/package/build-client-deb.sh'):
            with self.subTest(filename=filename):
                self.assertIn('qt6-svg-plugins', (ROOT / filename).read_text())
        self.assertIn('QT_INSTALL_PLUGINS)/imageformats/libqsvg.so',
                      (ROOT / 'scripts/ci/install-linux-deps.sh').read_text())

    def packet_size_gate(self, files):
        self.assertIsNotNone(shutil.which('rg'), 'source-gate tests require ripgrep')
        script = (ROOT / 'scripts/build/build-client-package-binaries.sh').read_text()
        gate = script.split('# Native KyProto owns media packetization.', 1)[1]
        gate = gate[gate.index('if rg -n '):].split('for required_mtu_token', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            for relative, content in files.items():
                path = Path(directory) / 'app' / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            return subprocess.run(
                ['bash', '-c', 'source_dir="$1"\n' + gate, 'gate', directory],
                capture_output=True, text=True, check=False)

    def test_packet_size_prose_is_not_legacy_code(self):
        result = self.packet_size_gate({
            'res/changelog.md': 'Preserve valid packets during packet-size recovery.\n',
            'backend/current.cpp': 'int quicUdpPayloadMtu = 1200;\n',
        })
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_retired_packet_size_controls_remain_rejected(self):
        for relative, content in (
            ('backend/cli.cpp', 'option("packet-size");\n'),
            ('backend/preferences.h', 'int packetSize MEMBER packetSize;\n'),
            ('gui/Settings.qml', 'text: "Physical path MTU"\n'),
            ('app.pro', 'DEFINES += SER_PACKETSIZE\n'),
        ):
            with self.subTest(relative=relative):
                result = self.packet_size_gate({relative: content})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('legacy packet-size configuration', result.stderr)


if __name__ == '__main__':
    unittest.main()
