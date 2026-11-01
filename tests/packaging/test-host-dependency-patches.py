#!/usr/bin/env python3
"""Prove Host preflight requires FFmpeg patches and pristine upstream Loader source."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class HostDependencyPatches(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='plank-host-patch-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = self.root / 'scripts/build/verify-host-dependency-patches.sh'
        self.script.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'scripts/build/verify-host-dependency-patches.sh', self.script)
        self.build = self.root / 'prepared'
        self.patches = self.root / 'apps/host/linux/third-party/build-deps/patches/FFmpeg'
        for dependency in ('FFmpeg', 'Vulkan-Loader'):
            source = self.build / 'FFmpeg' / dependency
            source.mkdir(parents=True)
            subprocess.run(['git', 'init', '--quiet', str(source)], check=True)
            (source / 'value.c').write_text('before\n')
            (source / 'other.c').write_text('original\n')
            (source / 'tests').mkdir()
            (source / 'tests/upstream.c').write_text('upstream test\n')
            # Upstream Loader fixtures include non-ASCII filenames. Git quotes
            # these without -z, which can hide their tests/ prefix from a parser.
            (source / 'tests/unicode-\N{SNOWMAN}.c').write_text('unicode test\n')
            subprocess.run(['git', '-C', str(source), 'add', '.'], check=True)
            if dependency == 'Vulkan-Loader':
                continue
            patch_dir = self.patches / dependency
            patch_dir.mkdir(parents=True)
            (patch_dir / '01-required.patch').write_text(
                'diff --git a/value.c b/value.c\n--- a/value.c\n+++ b/value.c\n'
                '@@ -1 +1 @@\n-before\n+after\n')
            (source / 'value.c').write_text('after\n')
        self.loader = self.build / 'FFmpeg/Vulkan-Loader'

    def verify(self):
        return subprocess.run(['bash', str(self.script), str(self.build)],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_all_required_groups_pass_repeatedly(self):
        for _ in range(2):
            result = self.verify()
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('host_dependency_loader_upstream_source_gate=pass', result.stdout)
            self.assertIn('host_dependency_patch_count=1', result.stdout)

    def test_modified_loader_is_rejected(self):
        (self.loader / 'value.c').write_text('modified allocation path\n')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('differs from pinned upstream production source', result.stdout)

    def test_extra_tracked_loader_change_is_rejected(self):
        (self.loader / 'other.c').write_text('unexpected\n')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_missing_loader_directory_is_rejected(self):
        shutil.rmtree(self.loader)
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Loader source is unavailable', result.stdout)

    def test_unpatched_ffmpeg_is_rejected(self):
        (self.build / 'FFmpeg/FFmpeg/value.c').write_text('before\n')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing or conflicts with patch:', result.stdout)

    def test_intentionally_omitted_loader_tests_are_allowed(self):
        shutil.rmtree(self.loader / 'tests')
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_modified_loader_tests_are_not_hidden(self):
        (self.loader / 'tests/upstream.c').write_text('unexpected change\n')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_missing_loader_production_source_is_rejected(self):
        (self.loader / 'other.c').unlink()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_production_source_moved_into_tests_is_rejected(self):
        (self.loader / 'other.c').rename(self.loader / 'tests/moved.c')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_omitted_test_allowance_is_loader_only(self):
        shutil.rmtree(self.build / 'FFmpeg/FFmpeg/tests')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_patch_reject_residue_is_rejected(self):
        (self.loader / 'value.c.rej').write_text('rejected patch\n')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('patch backup or reject files', result.stdout)

    def test_empty_ffmpeg_patch_directory_is_rejected(self):
        (self.patches / 'FFmpeg/01-required.patch').unlink()
        (self.build / 'FFmpeg/FFmpeg/value.c').write_text('before\n')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('patch group is empty', result.stdout)


if __name__ == '__main__':
    unittest.main()
