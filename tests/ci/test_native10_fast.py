"""The component path compiles exact production headers without a product build."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Native10FastTests(unittest.TestCase):
    def test_minimal_job_keeps_candidate_and_hardware_gates_separate(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        job = workflow.split('\n  linux-native10-tests:\n')[1].split('\n  linux-client-vaapi-probe:\n')[0]
        self.assertIn("inputs.product == 'linux-native10-tests'", job)
        self.assertIn("github.event_name == 'workflow_dispatch'", job)
        self.assertIn('rockylinux/rockylinux:9.7@sha256:', job)
        self.assertIn('gcc-toolset-14-libasan-devel', job)
        self.assertIn('gcc-toolset-14-libubsan-devel', job)
        for forbidden in ('bootstrap.sh', 'install-linux-deps.sh', 'build-host-rpm.sh',
                          'sccache', 'secrets.', 'self-hosted'):
            self.assertNotIn(forbidden, job)
        script = ROOT / 'scripts/ci/native10-fast.sh'
        subprocess.run(['bash', '-n', str(script)], check=True)
        text = script.read_text()
        for required in ('--depth 1 apps/host/linux', '--depth 1 third-party/build-deps',
                         '--depth 1 third-party/FFmpeg/nv-codec-headers',
                         'PLANK_NATIVE10_SANITIZERS=1', 'build-linux-native10-probes.sh',
                         'package_built=0 hardware_acceptance=not-performed'):
            self.assertIn(required, text)
        for forbidden in ('--recursive', 'cargo ', 'build-host-rpm.sh'):
            self.assertNotIn(forbidden, text)
        self.assertIn('linux-native10-tests', (ROOT / 'scripts/ci/dispatch.sh').read_text())


if __name__ == '__main__':
    unittest.main()
