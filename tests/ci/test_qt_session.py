from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class QtSessionWorkflowTests(unittest.TestCase):
    def test_hosted_explicit_credentials_free_job(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        job = workflow.split('  linux-client-qt-tests:\n')[1].split('  macos:\n')[0]
        self.assertIn("github.event_name == 'workflow_dispatch'", job)
        self.assertIn("inputs.product == 'linux-client-qt-tests' && !inputs.signed", job)
        self.assertIn('runs-on: ubuntu-26.04', job)
        self.assertIn('needs: policy', job)
        self.assertIn('product: linux-client', job)
        self.assertIn('scripts/ci/bootstrap.sh linux-client', job)
        self.assertIn('scripts/ci/test-qt-session.sh', job)
        self.assertIn('qt-session-reports/', job)
        for forbidden in ('self-hosted', 'secrets.', 'environment:', 'build-client-deb.sh'):
            self.assertNotIn(forbidden, job)

    def test_keeps_qualification_and_runtime_gates(self):
        script = (ROOT / 'scripts/ci/test-qt-session.sh').read_text()
        for gate in ('GITHUB_ACTIONS', 'ubuntu:26.04', '6.10.2',
                     'test-client-qt-package.py', 'run-qt-session-tests.sh',
                     'run-qt-session-compositor.sh', 'QT_SCALE_FACTOR=1.25',
                     'PLANK_QT_SESSION_SANITIZERS=1', 'detect_leaks=1', 'halt_on_error=1',
                     'PLANK_CLIENT_VARIANT=production', 'build-client-package-binaries.sh',
                     'hardware_acceptance=not-performed'):
            self.assertIn(gate, script)
        self.assertNotIn('build-client-deb.sh', script)
        runner = (ROOT / 'scripts/test/run-qt-session-tests.sh').read_text()
        self.assertIn('qtsoftwarevideo.pro', runner)
        self.assertIn('timeout 120 ./qtsoftwarevideo', runner)


if __name__ == '__main__':
    unittest.main()
