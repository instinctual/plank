#!/usr/bin/env python3
"""Verify retained Host FFmpeg patches and reject stale/modified prepared trees."""
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
        self.source = self.build / 'FFmpeg/FFmpeg'
        self.source.mkdir(parents=True)
        self.cache = self.build / 'CMakeCache.txt'
        self.cache.write_text(''.join(f'BUILD_FFMPEG_{name}:BOOL=OFF\n'
                                     for name in ('SVT_AV1', 'AMF', 'LIBVA', 'VULKAN')))
        subprocess.run(['git', 'init', '--quiet', str(self.source)], check=True)
        (self.source / 'value.c').write_text('before\n')
        (self.source / 'other.c').write_text('original\n')
        self.git('add', '.')
        self.git('-c', 'user.name=PLANK Tests', '-c', 'user.email=tests@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Fixture baseline')
        self.patches = self.root / 'apps/host/linux/third-party/build-deps/patches/FFmpeg/FFmpeg/cbs'
        self.patches.mkdir(parents=True)
        (self.patches / '01-required.patch').write_text(
            'diff --git a/value.c b/value.c\n--- a/value.c\n+++ b/value.c\n'
            '@@ -1 +1 @@\n-before\n+after\n')
        (self.source / 'value.c').write_text('after\n')

    def git(self, *args):
        subprocess.run(['git', '-C', str(self.source), *args], check=True)

    def verify(self):
        return subprocess.run(['bash', str(self.script), str(self.build)],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_selected_patches_pass_repeatedly(self):
        for _ in range(2):
            result = self.verify()
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('host_dependency_patch_count=1', result.stdout)

    def test_unpatched_ffmpeg_is_rejected(self):
        (self.source / 'value.c').write_text('before\n')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing or conflicts with patch:', result.stdout)

    def test_unselected_backend_patch_is_not_required(self):
        # Vulkan encoder patches remain upstream but are not applied by the
        # disabled backend; they must neither be required nor silently allowed.
        retired = self.patches.parent / 'vulkan'
        retired.mkdir()
        (retired / '01-unused.patch').write_text('not applied to this product\n')
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_stale_backend_selection_is_rejected(self):
        for name in ('SVT_AV1', 'AMF', 'LIBVA', 'VULKAN'):
            with self.subTest(name=name):
                original = self.cache.read_text()
                self.cache.write_text(original.replace(f'{name}:BOOL=OFF', f'{name}:BOOL=ON'))
                self.assertNotEqual(self.verify().returncode, 0)
                self.cache.write_text(original)

    def test_missing_backend_selection_is_rejected(self):
        self.cache.unlink()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_unexpected_source_change_is_rejected(self):
        (self.source / 'other.c').write_text('unexpected\n')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_staged_source_change_is_rejected(self):
        (self.source / 'other.c').write_text('unexpected\n')
        self.git('add', 'other.c')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_missing_source_is_rejected(self):
        (self.source / 'other.c').unlink()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_patch_reject_residue_is_rejected(self):
        (self.source / 'value.c.rej').write_text('rejected patch\n')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_empty_patch_group_is_rejected(self):
        (self.patches / '01-required.patch').unlink()
        (self.source / 'value.c').write_text('before\n')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('patch group is empty', result.stdout)


if __name__ == '__main__':
    unittest.main()
