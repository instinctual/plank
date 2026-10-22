"""Compiler reuse keeps clean source, per-object validation and trust boundaries."""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('compiler_cache', ROOT / 'scripts/ci/compiler-cache.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class CompilerCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'source'
        self.work = Path(self.tmp.name) / 'work'
        self.work.mkdir()
        for name in ('scripts/ci/compiler-cache.py', 'scripts/ci/cached-compiler.sh', 'rust-toolchain.toml'):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('fixture')

    def plan(self, revision='a' * 40, run='123', attempt='1', tools=None):
        return cache.cache_plan(self.root, self.work, tools or ['compiler1'], revision, run, attempt)

    def test_reuses_prefix_across_commits_but_each_run_saves_a_new_snapshot(self):
        initial = self.plan()
        for changed in (self.plan(revision='b' * 40), self.plan(run='124'), self.plan(attempt='2')):
            self.assertEqual(initial['prefix'], changed['prefix'])
            self.assertNotEqual(initial['key'], changed['key'])
        self.assertEqual(initial['path'], str(self.work / 'compiler-cache'))
        self.assertNotEqual(initial['prefix'], self.plan(tools=['compiler2'])['prefix'])

    def test_cache_policy_and_rust_toolchain_changes_invalidate_prefix(self):
        for name in ('scripts/ci/compiler-cache.py', 'scripts/ci/cached-compiler.sh', 'rust-toolchain.toml'):
            before = self.plan()['prefix']
            (self.root / name).write_text('new policy')
            self.assertNotEqual(before, self.plan()['prefix'])
        for bad in ('HEAD', 'A' * 40, 'a\nb'):
            with self.assertRaises(ValueError):
                self.plan(revision=bad)
        with self.assertRaises(ValueError):
            self.plan(run='not-a-run')

    def test_wrapper_is_private_to_job_and_cannot_recurse_into_itself(self):
        env_file, path_file = self.work / 'env', self.work / 'path'
        cache.enable(self.root, self.work, env_file, path_file)
        wrappers = self.work / 'compiler-wrappers'
        for name in ('cc', 'c++', 'gcc', 'g++'):
            self.assertEqual((wrappers / name).resolve(), self.root / 'scripts/ci/cached-compiler.sh')
        env = dict(line.split('=', 1) for line in env_file.read_text().splitlines())
        self.assertEqual(env['RUSTC_WRAPPER'], '/usr/bin/sccache')
        self.assertEqual(env['CARGO_INCREMENTAL'], '0')
        # cc-rs adds the RUSTC_WRAPPER itself, so it must bypass PATH wrappers.
        self.assertEqual(env['HOST_CC'], '/usr/bin/gcc')
        self.assertEqual(env['HOST_CXX'], '/usr/bin/g++')
        self.assertNotIn('CC', env)
        self.assertNotIn('CXX', env)
        self.assertEqual(env['SCCACHE_DIR'], str(self.work / 'compiler-cache'))
        self.assertEqual(env['SCCACHE_SERVER_UDS'], str(self.work / 'sccache.sock'))
        self.assertEqual(path_file.read_text(), str(wrappers) + '\n')
        with self.assertRaises(FileExistsError):
            cache.enable(self.root, self.work, env_file, path_file)
        wrapper = ROOT / 'scripts/ci/cached-compiler.sh'
        self.assertTrue(os.access(wrapper, os.X_OK))
        self.assertIn('exec /usr/bin/sccache "/usr/bin/$compiler" "$@"', wrapper.read_text())
        subprocess.run(['bash', '-n', str(wrapper)], check=True)
        self.assertEqual(subprocess.run(['bash', str(wrapper)], capture_output=True).returncode, 2)

    def test_smoke_check_exercises_path_and_cc_rs_command_forms(self):
        with patch.dict(cache.os.environ, {'HOST_CC': '/usr/bin/gcc', 'HOST_CXX': '/usr/bin/g++'}), \
             patch.object(cache.subprocess, 'run') as run:
            cache.verify(self.work)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual([command[:command.index('-c')] for command in commands], [
            ['cc'], ['/usr/bin/sccache', '/usr/bin/gcc'], ['/usr/bin/sccache', '/usr/bin/g++']])
        self.assertTrue(all(call.kwargs['check'] for call in run.call_args_list))
        self.assertEqual(list(self.work.iterdir()), [])

    def test_workflow_restores_only_compiler_data_and_never_saves_untrusted_or_failed_builds(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        block = workflow.split('  linux-client:\n')[1].split('\n  macos:\n')[0]
        self.assertIn('sccache', (ROOT / 'scripts/ci/install-linux-deps.sh').read_text())
        for label in ('Select Ubuntu compiler cache', 'Restore Ubuntu compiler outputs',
                      'Enable Ubuntu compiler cache', 'Verify Ubuntu compiler cache wiring',
                      'Save verified Ubuntu compiler outputs'):
            step = block.split('- name: ' + label)[1].split('\n      - ')[0]
            self.assertIn('!inputs.clean_bootstrap', step)
        save = block.split('- name: Save verified Ubuntu compiler outputs')[1].split('\n      - ')[0]
        self.assertIn("github.event_name != 'pull_request'", save)
        self.assertNotIn('always()', save)
        self.assertNotIn('failure()', save)
        self.assertIn('path: ${{ steps.compiler-cache.outputs.path }}', save)
        self.assertLess(block.index('Enable Ubuntu compiler cache'), block.index('bash scripts/ci/build.sh'))
        self.assertLess(block.index('Enable Ubuntu compiler cache'), block.index('Verify Ubuntu compiler cache wiring'))
        self.assertLess(block.index('Verify Ubuntu compiler cache wiring'), block.index('bash scripts/ci/build.sh'))
        self.assertLess(block.index('bash scripts/ci/build.sh'), block.index('Report Ubuntu compiler reuse'))
        self.assertLess(block.index('Report Ubuntu compiler reuse'), block.index('Save verified Ubuntu compiler outputs'))
        for section in workflow.split('  linux-client:\n'):
            if 'Restore Ubuntu compiler outputs' not in section:
                self.assertNotIn('compiler-cache.py', section)
        self.assertNotIn('compiler-cache.py', workflow.split('\n  macos:\n')[1])
        for action in re.findall(r'uses: (actions/cache/[^\s]+)', block):
            self.assertRegex(action, r'@55cc8345863c7cc4c66a329aec7e433d2d1c52a9$')

    def test_runner_and_output_validation_fail_closed(self):
        for env in ({}, {'GITHUB_ACTIONS': 'false'}):
            with patch.dict(cache.os.environ, env, clear=True):
                with self.assertRaises(ValueError):
                    cache.require_runner()
        with patch.dict(cache.os.environ, {'GITHUB_ACTIONS': 'true'}), \
             patch.object(cache.platform, 'system', return_value='Linux'), \
             patch.object(cache.platform, 'machine', return_value='x86_64'):
            with patch.object(cache.Path, 'read_text', return_value='ID=ubuntu\nVERSION_ID="26.04"\n'):
                cache.require_runner()
            with patch.object(cache.Path, 'read_text', return_value='ID=rocky\nVERSION_ID=9.7\n'):
                with self.assertRaises(ValueError):
                    cache.require_runner()
        with self.assertRaises(ValueError):
            cache.append_values(self.work / 'env', {'injected': 'value\nNEXT=bad'})


if __name__ == '__main__':
    unittest.main()
