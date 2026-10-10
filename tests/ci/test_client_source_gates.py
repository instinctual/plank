"""Exercise source gates without compiling a client or preparing dependencies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ClientSourceGateTests(unittest.TestCase):
    def test_private_sdl_does_not_embed_its_install_prefix_in_consumers(self):
        bootstrap = (ROOT / 'scripts/build/build-client-sdl.sh').read_text()
        self.assertIn('-DSDL_RPATH=OFF', bootstrap)
        verifier = (ROOT / 'scripts/build/client-sdl.sh').read_text()
        # Exercise the real fail-closed metadata gate with generated .pc files;
        # no installed SDL, devices, display or source download is needed.
        gate = verifier.split('    link_flags=$(', 1)[1].split('    [[ $(sha256sum', 1)[0]
        for inject in (False, True):
            with self.subTest(inject=inject), tempfile.TemporaryDirectory() as tmp:
                pkgconfig = Path(tmp) / 'install/lib/pkgconfig'
                pkgconfig.mkdir(parents=True)
                (pkgconfig / 'sdl3.pc').write_text(
                    'Name: SDL fixture\nDescription: Test only\nVersion: 3.4.2\nLibs: -lSDL3' +
                    (' -Wl,-rpath,/build/fixture/install/lib' if inject else '') + '\n')
                script = ('function check_metadata() { local work=$1 link_flags\n'
                          '    link_flags=$(' + gate + '\n}\ncheck_metadata "$1"')
                result = subprocess.run(['bash', '-c', script, 'gate', tmp],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1 if inject else 0, result.stderr)
                if inject:
                    self.assertIn('must not inject', result.stderr)

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
