import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('affected_products', ROOT / 'scripts/ci/affected-products.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AffectedProducts(unittest.TestCase):
    def test_documentation_only_skips_packages(self):
        self.assertEqual(module.affected(['HANDOFF.md', 'docs/development/plans/example.plan']), [])

    def test_gitlinks_and_shared_changes(self):
        self.assertEqual(module.affected(['apps/host/linux']), ['linux-host'])
        self.assertEqual(module.affected(['apps/client']), ['linux-client', 'macos-client'])
        for path in ['protocol/plank-transport/src/native.rs', 'third_party/kyber-kymux',
                     'packaging/VERSION', '.github/workflows/build.yml', 'unknown-path']:
            self.assertEqual(module.affected([path]), list(module.PRODUCTS))

    def test_platform_paths_union(self):
        self.assertEqual(module.affected(['apps/host/macos/media/native-video.m',
                                         'packaging/client/linux/control']), ['linux-client', 'macos-host'])

    def test_manual_and_missing_history_build_everything(self):
        self.assertEqual(module.select({}, 'workflow_dispatch', 'head'), list(module.PRODUCTS))
        self.assertEqual(module.select({'before': '0' * 40}, 'push', 'head'), list(module.PRODUCTS))
        with patch.object(module.subprocess, 'check_output', side_effect=module.subprocess.CalledProcessError(1, 'git')):
            self.assertEqual(module.select({'before': 'missing'}, 'push', 'head'), list(module.PRODUCTS))

    def test_deleted_paths_are_still_inputs(self):
        with patch.object(module.subprocess, 'check_output', return_value=b'apps/host/linux\0HANDOFF.md\0'):
            self.assertEqual(module.select({'before': 'base'}, 'push', 'head'), ['linux-host'])
