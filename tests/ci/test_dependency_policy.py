"""Small source guards for the root update policy; no package builds required."""
import configparser
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DependencyPolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = (ROOT / '.github/dependabot.yml').read_text()

    def test_supported_production_inputs_are_monitored(self):
        self.assertEqual(re.findall(r'package-ecosystem: (\S+)', self.policy),
                         ['github-actions', 'gitsubmodule', 'cargo'])
        for manifest in ('protocol/plank-transport',):
            self.assertIn('/' + manifest, self.policy)
            self.assertTrue((ROOT / manifest / 'Cargo.toml').is_file())
            self.assertTrue((ROOT / manifest / 'Cargo.lock').is_file())

    def test_proposals_are_weekly_and_bounded(self):
        self.assertEqual(self.policy.count('interval: weekly'), 3)
        self.assertEqual(self.policy.count('open-pull-requests-limit: 3'), 3)
        for forbidden in ('registries:', 'insecure-external-code-execution:',
                          'auto-merge', 'target-branch:'):
            self.assertNotIn(forbidden, self.policy)

    def test_repaired_quinn_requires_manual_qualification(self):
        for dependency in ('quinn', 'quinn-proto'):
            self.assertRegex(self.policy, rf'(?m)^      - dependency-name: {dependency}$')
        self.assertNotIn('directory: /third_party/quinn-proto', self.policy)

    def test_production_has_one_rustls_identity(self):
        lock = (ROOT / 'protocol/plank-transport/Cargo.lock').read_text()
        packages = [block for block in lock.split('[[package]]')
                    if re.search(r'(?m)^name = "rustls"$', block)]
        self.assertEqual(len(packages), 1)
        for field in ('version', 'source', 'checksum'):
            self.assertEqual(len(re.findall(rf'(?m)^{field} = "([^"]+)"$', packages[0])), 1)

    def test_root_gitlinks_track_the_maintained_branches(self):
        modules = configparser.ConfigParser()
        modules.read(ROOT / '.gitmodules')
        self.assertEqual({modules[s]['path'] for s in modules.sections()},
                         {'apps/host/linux', 'apps/client', 'third_party/kyber-kymux'})
        for section in modules.sections():
            self.assertEqual(modules[section]['branch'], 'main')


if __name__ == '__main__':
    unittest.main()
