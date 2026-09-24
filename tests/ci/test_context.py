import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ci_context', ROOT / 'scripts/ci/context.py')
context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(context)


class ContextTests(unittest.TestCase):
    def test_main_stays_unqualified(self):
        self.assertEqual(context.branch_name('main'), 'main')

    def test_normal_branch_is_preserved(self):
        self.assertEqual(context.branch_name('github-builds'), 'github-builds')

    def test_normalization_cannot_impersonate_main(self):
        self.assertNotEqual(context.branch_name('MAIN'), 'main')
        self.assertNotEqual(context.branch_name('main/'), 'main')

    def test_normalization_keeps_distinct_refs_distinct(self):
        self.assertNotEqual(context.branch_name('fix/a'), context.branch_name('fix-a'))
        self.assertRegex(context.branch_name('fix/a'), r'^fix-a-[0-9a-f]{8}$')

    def test_empty_names_rejected(self):
        for name in ['', '/', '___']:
            with self.assertRaises(ValueError):
                context.branch_name(name)

    def test_worktree_and_explicit_path_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            # macOS exposes /var through /private/var; compare canonical paths
            # just as the production context writer does.
            base = Path(directory).resolve()
            source = base / 'checkout'
            source.mkdir()
            subprocess.run(['git', 'init', '-q', str(source)], check=True)
            subprocess.run(['git', '-C', str(source), '-c', 'user.name=CI fixture',
                            '-c', 'user.email=ci@example.org', 'commit', '-q',
                            '--allow-empty', '-m', 'Fixture'], check=True)
            sha = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
            env_file = base / 'github-env'
            env = dict(os.environ, GITHUB_WORKSPACE=str(source), RUNNER_TEMP=str(base),
                       GITHUB_SHA=sha, EXPECTED_SOURCE_SHA=sha,
                       BUILD_REF='feature/check', GITHUB_ENV=str(env_file))
            subprocess.run(['python3', str(ROOT / 'scripts/ci/context.py')], env=env, check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            values = dict(line.split('=', 1) for line in env_file.read_text().splitlines())
            worktree = base / 'plank-ci/source'
            self.assertEqual(values['PLANK_SOURCE_ROOT'], str(worktree))
            self.assertEqual(values['PLANK_BUILD_BRANCH'], context.branch_name('feature/check'))
            self.assertEqual(subprocess.check_output(['git', '-C', str(worktree), 'rev-parse', 'HEAD'], text=True).strip(), sha)
            # Reusing a scratch root must fail instead of trusting stale outputs.
            self.assertNotEqual(subprocess.run(['python3', str(ROOT / 'scripts/ci/context.py')], env=env,
                                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode, 0)

    def test_untrusted_workflow_has_no_signing_or_write_authority(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text().split('  macos-signed:\n')[0]
        for forbidden in ['pull_request_target', 'secrets.', 'contents: write', 'self-hosted']:
            self.assertNotIn(forbidden, workflow)
        self.assertIn('contents: read', workflow)
        actions = re.findall(r'uses: ([^\s]+)', workflow)
        self.assertTrue(actions)
        for action in actions:
            if action == './.github/actions/dependency-cache':
                # Local code is pinned by the checked-out root commit. Its
                # external actions must obey the same immutable-SHA policy.
                composite = (ROOT / '.github/actions/dependency-cache/action.yml').read_text()
                self.assertNotIn('secrets.', composite)
                for nested in re.findall(r'uses: ([^\s]+)', composite):
                    self.assertRegex(nested, r'@([0-9a-f]{40})$')
                continue
            self.assertRegex(action, r'@([0-9a-f]{40})$')
        self.assertEqual(workflow.count('actions/checkout@'), workflow.count('persist-credentials: false'))

    def test_signing_requires_explicit_dispatch_and_protected_environment(self):
        caller = (ROOT / '.github/workflows/build.yml').read_text().split('  macos-signed:\n')[1]
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.signed", caller)
        self.assertIn('needs: policy', caller)
        workflow = caller
        self.assertFalse((ROOT / '.github/workflows/sign-macos.yml').exists())
        self.assertIn("github.event_name == 'workflow_dispatch'", workflow)
        self.assertIn('environment: macos-signing', workflow)
        self.assertIn('runs-on: xcode-27', workflow)
        for forbidden in ('pull_request_target', 'secrets: inherit', 'contents: write', 'self-hosted'):
            self.assertNotIn(forbidden, workflow)
        before, signing = workflow.split('      - name: Build, sign, notarize and verify\n')
        self.assertNotIn('secrets.', before)
        secret_step, after = signing.split('      - name: Remove temporary signing material\n')
        self.assertEqual(secret_step.count('secrets.'), 7)
        self.assertNotIn('secrets.', after)
        self.assertIn('if: always()', after)
        self.assertIn('path: ${{ env.PLANK_ARTIFACT_ROOT }}/', after)
        self.assertNotIn('RUNNER_TEMP', after)

    def test_all_root_workflows_use_current_node_actions(self):
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            workflow = path.read_text()
            for action in re.findall(r'uses: (actions/checkout@[^\s]+)', workflow):
                self.assertEqual(action, 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1')


if __name__ == '__main__':
    unittest.main()
