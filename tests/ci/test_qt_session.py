from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class QtSessionWorkflowTests(unittest.TestCase):
    def test_hosted_explicit_credentials_free_job(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        job = workflow.split('  linux-client-qt-tests:\n')[1].split('  macos:\n')[0]
        self.assertIn("github.event_name == 'workflow_dispatch'", job)
        self.assertIn("inputs.product == 'linux-client-qt-tests' || inputs.product == 'linux-client-qt'", job)
        self.assertIn('&& !inputs.signed', job)
        self.assertIn('runs-on: ubuntu-26.04', job)
        self.assertIn('needs: policy', job)
        self.assertIn('product: linux-client', job)
        self.assertIn('scripts/ci/bootstrap.sh linux-client', job)
        self.assertIn('scripts/ci/test-qt-session.sh', job)
        self.assertIn('qt-session-reports/', job)
        for forbidden in ('self-hosted', 'secrets.', 'environment:'):
            self.assertNotIn(forbidden, job)
        package = job.split('- name: Package the independently installable Qt candidate')[1]
        self.assertIn("if: ${{ inputs.product == 'linux-client-qt' }}", package)
        self.assertIn('PLANK_CLIENT_VARIANT: qt', package)
        self.assertIn('qt-runtime-build/app/plank-client-qt', package)
        self.assertIn('scripts/package/build-client-deb.sh', package)

    def test_keeps_qualification_and_runtime_gates(self):
        script = (ROOT / 'scripts/ci/test-qt-session.sh').read_text()
        for gate in ('GITHUB_ACTIONS', 'ubuntu:26.04', '6.10.2',
                     'test-client-qt-package.py', 'run-qt-session-tests.sh',
                     'run-qt-session-compositor.sh', 'QT_SCALE_FACTOR=1.25',
                     'PLANK_QT_SESSION_SANITIZERS=1', 'detect_leaks=1', 'halt_on_error=1',
                     'PLANK_CLIENT_VARIANT=production', 'build-client-package-binaries.sh',
                     'VK_DRIVER_FILES', 'LIBGL_ALWAYS_SOFTWARE=1',
                     'PLANK_QT_CLIENT_BINARY', 'PLANK_QT_LAUNCHER_REPORTS',
                     'hardware_acceptance=not-performed'):
            self.assertIn(gate, script)
        self.assertNotIn('build-client-deb.sh', script)
        runner = (ROOT / 'scripts/test/run-qt-session-tests.sh').read_text()
        self.assertIn('qtsoftwarevideo.pro', runner)
        self.assertIn('timeout 120 ./qtsoftwarevideo', runner)
        self.assertIn('qtsystemproperties.pro', runner)
        self.assertIn('QT_SCALE_FACTOR=1.25 ./qtsystemproperties', runner)
        smoke = (ROOT / 'scripts/test/smoke-qt-client.py').read_text()
        self.assertIn("environment['SDL_VIDEO_DRIVER'] = 'plank-disabled-for-qt-test'", smoke)
        self.assertIn('process.terminate()', smoke)
        self.assertIn('process.wait(timeout=20)', smoke)

    def test_bitrate_gate_distinguishes_session_ui_from_global_preferences(self):
        script = (ROOT / 'scripts/build/build-client-package-binaries.sh').read_text()
        # Execute the real gate, not a second implementation of its patterns.
        gate = script.split('# Global preferences must not own bitrate;')[1].split("if rg -n 'NVENC")[0]
        gate = gate[gate.index('\nif rg '):]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            for path in ('settings', 'streaming/qt', 'cli'):
                (source / 'app' / path).mkdir(parents=True)
            settings = source / 'app/settings/streamingpreferences.h'
            settings.write_text('// no global bitrate\n')
            (source / 'app/streaming/qt/sessionwindow.h').write_text(
                'Q_PROPERTY(int bitrateKbps READ bitrateKbps WRITE setBitrateKbps NOTIFY bitrateChanged)\n')
            def check():
                return subprocess.run(['bash', '-c', 'set -euo pipefail; source_dir=$1\n' + gate,
                                       'gate-test', str(source)], text=True, capture_output=True)
            self.assertEqual(check().returncode, 0)
            for token in ('Q_PROPERTY(int bitrateKbps MEMBER bitrateKbps)',
                          'Q_PROPERTY(int rate READ bitrateKbps MEMBER bitrateKbps)',
                          '#define SER_BITRATE "bitrate"',
                          'getDefaultBitrate()', 'StreamingPreferences.bitrateKbps',
                          'm_Preferences.bitrateKbps', 'preferences->bitrateKbps'):
                with self.subTest(token=token):
                    settings.write_text(token + '\n')
                    self.assertEqual(check().returncode, 1)
            settings.write_text('// no global bitrate\n')
            for token in ('plank-bitrate-kbps', 'addValueOption("bitrate")'):
                with self.subTest(token=token):
                    (source / 'app/cli/start.cpp').write_text(token + '\n')
                    self.assertEqual(check().returncode, 1)

    def test_probe_uses_production_style(self):
        # This policy job has no submodules. The Client's runtime tests assert
        # their Material style separately after product bootstrap.
        source = (ROOT / 'probes/qt-session/main.cpp').read_text()
        for required in ('QQuickStyle::setStyle(QStringLiteral("Material"))',
                         '"QT_QUICK_CONTROLS_MATERIAL_THEME", "Dark"',
                         '"QT_QUICK_CONTROLS_MATERIAL_VARIANT", "Dense"',
                         '"QT_QUICK_CONTROLS_MATERIAL_ACCENT", "#5A9CE6"'):
            self.assertIn(required, source)
        self.assertLess(source.index('QQuickStyle::setStyle'),
                        source.index('QGuiApplication app('))


if __name__ == '__main__':
    unittest.main()
