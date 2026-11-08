"""Host-only cache provenance, compiler selection and trusted-success save gates."""
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('host_object_cache', ROOT / 'scripts/ci/host-object-cache.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class HostObjectCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'source'
        self.work = Path(self.tmp.name) / 'work'
        self.work.mkdir()
        for name in ('scripts/ci/host-object-cache.py', 'scripts/ci/compiler-cache.py',
                     'scripts/build/host-cuda.sh', 'rust-toolchain.toml'):
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('policy')

    def plan(self, revision='a' * 40, run='123', attempt='1', tools=None):
        return cache.cache_plan(self.root, self.work, tools or ['gcc14', 'cuda13.2'], revision, run, attempt)

    def test_reuses_verified_object_namespace_across_source_changes(self):
        first = self.plan()
        for later in (self.plan(revision='b' * 40), self.plan(run='124'), self.plan(attempt='2')):
            self.assertEqual(first['prefix'], later['prefix'])
            self.assertNotEqual(first['key'], later['key'])
        self.assertEqual(first['path'], str(self.work / 'host-compiler-cache'))
        self.assertNotEqual(first['prefix'], self.plan(tools=['different compiler'])['prefix'])
        for name in ('scripts/ci/host-object-cache.py', 'scripts/ci/compiler-cache.py',
                     'scripts/build/host-cuda.sh', 'rust-toolchain.toml'):
            before = self.plan()['prefix']
            (self.root / name).write_text('new policy')
            self.assertNotEqual(before, self.plan()['prefix'])
        for bad in ('HEAD', 'a\nb', 'A' * 40):
            with self.assertRaises(ValueError): self.plan(revision=bad)
        with self.assertRaises(ValueError): self.plan(attempt='0')

    def test_only_explicit_cmake_and_rust_launchers_are_enabled(self):
        env_file = self.work / 'env'
        with self.assertRaises(ValueError): cache.enable(self.work, env_file)
        binary = cache.cache_binary(self.work)
        binary.parent.mkdir()
        binary.touch()
        cache.enable(self.work, env_file)
        env = dict(line.split('=', 1) for line in env_file.read_text().splitlines())
        for name in ('CMAKE_C_COMPILER_LAUNCHER', 'CMAKE_CXX_COMPILER_LAUNCHER',
                     'CMAKE_CUDA_COMPILER_LAUNCHER', 'RUSTC_WRAPPER'):
            self.assertEqual(env[name], str(binary))
        self.assertEqual(env['CARGO_INCREMENTAL'], '0')
        for name in ('CC', 'CXX', 'HOST_CC', 'HOST_CXX', 'PATH', 'CARGO_TARGET_DIR'):
            self.assertNotIn(name, env)  # Preserve the actual qualified compiler selection.
        self.assertEqual(env['SCCACHE_CACHE_SIZE'], '2G')

    def archive(self, symlink=False):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:gz') as archive:
            info = tarfile.TarInfo(cache.SCCACHE_ARCHIVE + '/sccache')
            if symlink:
                info.type = tarfile.SYMTYPE
                info.linkname = '/untrusted/target'
                archive.addfile(info)
            else:
                data = b'verified-tool-fixture'
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return output.getvalue()

    def test_tool_hash_and_regular_file_are_required_before_execution(self):
        for symlink in (False, True):
            archive = self.archive(symlink)
            work = self.work / str(symlink)
            with patch.object(cache.urllib.request, 'urlopen', return_value=io.BytesIO(archive)), \
                 patch.object(cache, 'SCCACHE_SHA256', hashlib.sha256(archive).hexdigest()), \
                 patch.object(cache.common, 'output', return_value='sccache ' + cache.SCCACHE_VERSION) as output:
                if symlink:
                    with self.assertRaises(ValueError): cache.install(work)
                    output.assert_not_called()
                else:
                    cache.install(work)
                    binary = cache.cache_binary(work)
                    self.assertEqual(binary.read_bytes(), b'verified-tool-fixture')
                    self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
            if symlink: self.assertFalse(cache.cache_binary(work).exists())
        with patch.object(cache.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong archive')):
            with self.assertRaises(ValueError): cache.install(self.work / 'bad-hash')
        self.assertFalse(cache.cache_binary(self.work / 'bad-hash').exists())

    def test_workflow_keeps_clean_builds_and_only_saves_successful_trusted_outputs(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        host = workflow.split('\n  linux-host:\n')[1].split('\n  linux-native10-tests:\n')[0]
        for label in ('Install pinned Host compiler cache', 'Select Host compiler cache',
                      'Restore Host compiler outputs', 'Enable Host compiler cache',
                      'Verify Host compiler cache wiring', 'Save verified Host compiler outputs'):
            block = host.split('- name: ' + label)[1].split('\n      - ')[0]
            self.assertIn('!inputs.clean_bootstrap', block)
        save = host.split('- name: Save verified Host compiler outputs')[1].split('\n      - ')[0]
        self.assertIn("github.event_name != 'pull_request'", save)
        self.assertNotIn('always()', save)
        self.assertNotIn('failure()', save)
        self.assertIn('steps.host-compiler-cache.outputs.path', save)
        self.assertLess(host.index('operation: save'), host.index('Install pinned Host compiler cache'))
        self.assertLess(host.index('Verify Host compiler cache wiring'), host.index('build.sh linux-host'))
        self.assertLess(host.index('build.sh linux-host'), host.index('Save verified Host compiler outputs'))
        self.assertNotIn('host-object-cache.py', workflow.split('\n  linux-client:\n')[1])

    def test_runner_validation_is_host_specific(self):
        with patch.dict(cache.os.environ, {}, clear=True):
            with self.assertRaises(ValueError): cache.require_runner()
        with patch.dict(cache.os.environ, {'GITHUB_ACTIONS': 'true'}), \
             patch.object(cache.platform, 'system', return_value='Linux'), \
             patch.object(cache.platform, 'machine', return_value='x86_64'):
            with patch.object(cache.Path, 'read_text', return_value='ID=rocky\nVERSION_ID=9.7\n'):
                cache.require_runner()
            with patch.object(cache.Path, 'read_text', return_value='ID=ubuntu\nVERSION_ID=26.04\n'):
                with self.assertRaises(ValueError): cache.require_runner()


if __name__ == '__main__':
    unittest.main()
