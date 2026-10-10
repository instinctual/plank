"""Workflow wiring and cache lifecycle regression tests."""
import importlib.util
import io
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('cache_lifecycle', ROOT / 'scripts/ci/cache-dependencies.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class DependencyCacheTests(unittest.TestCase):
    def test_workflow_has_exact_restore_and_trusted_save_for_every_product(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        for job in ('linux-host', 'linux-client', 'macos', 'macos-signed'):
            block = re.split(r'\n  [a-z][a-z-]+:\n', workflow.split(f'  {job}:\n')[1])[0]
            self.assertEqual(block.count('uses: ./.github/actions/dependency-cache'), 2)
            self.assertEqual(block.count('operation: restore'), 1)
            self.assertEqual(block.count('operation: save'), 1)
            self.assertLess(block.index('Restore and verify dependencies'), block.index('Save dependencies'))
            restores = block.split('- name: Restore and verify dependencies')[1].split('- ')[0]
            saves = block.split('- name: Save dependencies')[1].split('- ')[0]
            self.assertIn('!inputs.clean_bootstrap', restores)
            self.assertIn('!inputs.clean_bootstrap', saves)
            self.assertNotIn('always()', saves)
            self.assertNotIn('failure()', saves)
            self.assertLess(block.index('Restore and verify dependencies'), block.index('bash scripts/ci/bootstrap.sh'))
            self.assertLess(block.index('bash scripts/ci/bootstrap.sh'), block.index('Save dependencies'))
            if job == 'macos-signed':
                self.assertIn("inputs.product != 'macos-fullscreen-probe'", restores)
                self.assertIn("inputs.product != 'macos-fullscreen-probe'", saves)
                self.assertLess(block.index('Save dependencies'), block.index('Build, sign, notarize and verify'))
                self.assertLess(block.index('Build, sign, notarize and verify'), block.index('Remove temporary signing material'))
                before_signing = block.split('- name: Build, sign, notarize and verify')[0]
                self.assertNotIn('secrets.', before_signing)
                self.assertIn('if: always()', block.split('- name: Remove temporary signing material')[1])
            else:
                self.assertIn("github.event_name != 'pull_request'", saves)
                self.assertLess(block.index('Save dependencies'), block.index('bash scripts/ci/build.sh'))

    def test_composite_uses_independent_exact_keys_and_skips_existing_entries(self):
        action = (ROOT / '.github/actions/dependency-cache/action.yml').read_text()
        self.assertEqual(action.count('actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9'), 6)
        self.assertEqual(action.count('actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9'), 6)
        self.assertNotIn('restore-keys:', action)
        self.assertNotIn('always()', action)
        self.assertIn('$GITHUB_EVENT_NAME == pull_request', action)
        self.assertIn('case "$CACHE_OPERATION" in restore|save)', action)
        for component in cache.ALL_COMPONENTS:
            self.assertEqual(action.count('key: ${{ steps.keys.outputs.' + component + '-key }}'), 2)
            self.assertEqual(action.count('path: ${{ steps.keys.outputs.' + component + '-paths }}'), 2)
            self.assertIn("steps.keys.outputs." + component + "-hit != 'true'", action)
            self.assertIn('CACHE_MATCHED_' + component.upper() +
                          ': ${{ steps.' + component + '.outputs.cache-matched-key }}', action)
        self.assertLess(action.index('Restore qt'), action.index('Verify exact restored dependencies'))
        self.assertLess(action.index('Seal successful dependencies'), action.index('Save rust'))

    def test_output_plan_tracks_mixed_hits_per_key_not_whole_product(self):
        root, deps = Path('/source'), Path('/dependencies')
        keys = {'rust': 'rust-key', 'cargo': 'cargo-key', 'ffmpeg': 'ffmpeg-key'}
        out = io.StringIO()
        cache.emit_plan(root, deps, 'linux-client', keys,
                        {'rust': 'rust-key', 'cargo': 'older-cargo-key'}, out)
        text = out.getvalue()
        self.assertIn('rust-hit=true', text)
        self.assertIn('cargo-hit=false', text)
        self.assertIn('ffmpeg-hit=false', text)
        self.assertNotIn('qt-key=', text)
        for component in keys:
            self.assertIn(component + '-paths<<PLANK_CACHE_PATHS', text)
            self.assertIn(component + '-key=' + keys[component], text)

    def test_seal_and_restore_round_trip_and_empty_hit_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, deps = Path(tmp) / 'source', Path(tmp) / 'deps'
            product = 'macos-host'
            keys = {c: f'plank-{product}-{c}-v2-' + '1' * 64 for c in cache.COMPONENTS[product]}
            for name in ('cargo/bin/rustup', 'rustup/settings.toml'):
                path = deps / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture')
            cache.seal(root, deps, product, keys)
            self.assertEqual(cache.verify_restored(root, deps, product, keys, keys), keys)
            self.assertEqual(cache.verify_restored(root, deps, product, keys, {}), {})
            # Job hit bookkeeping cannot arrive inside the dependency archives.
            self.assertFalse(cache.hits_path(deps, product).exists())
            for component, key in keys.items():
                receipt = cache.cache_paths(root, deps, product, component)[-1]
                self.assertEqual(json.loads(receipt.read_text()), {'schema': 2, 'key': key})

    def test_empty_or_incomplete_prepared_library_cannot_be_sealed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, deps = Path(tmp) / 'source', Path(tmp) / 'deps'
            with self.assertRaises(ValueError):
                cache.seal(root, deps, 'linux-client', {'ffmpeg': 'unused-key'})
            self.assertFalse((deps / 'cache-receipts/linux-client-ffmpeg.json').exists())

    def test_bootstrap_executes_every_independent_recipe(self):
        source = (ROOT / 'scripts/ci/bootstrap.sh').read_text()
        for name in ('rust', 'cargo', 'boost', 'host-ffmpeg', 'client-ffmpeg', 'client-sdl', 'macos-libraries', 'qt'):
            self.assertIn(f'bash "$dependency_scripts/{name}.sh"', source)
        # Pin/build flags belong in the recipe hashed for the affected cache,
        # not an orchestration script shared by unrelated dependencies.
        for forbidden in ('curl ', 'cmake -', 'cargo fetch', 'aqt install-qt'):
            self.assertNotIn(forbidden, source)
        cargo = (ROOT / 'scripts/ci/dependencies/cargo.sh').read_text()
        self.assertEqual(cargo.count('cargo fetch --locked'), 2)
        self.assertIn('third_party/quinn-proto-0.11.17/Cargo.toml', cargo)

    def test_platform_verification_is_not_bypassed(self):
        with patch.object(cache.platform, 'system', return_value='Darwin'), \
             patch.object(cache.platform, 'machine', return_value='x86_64'):
            for product in cache.PRODUCTS:
                with self.assertRaises(ValueError):
                    cache.toolchain_inputs(product)


if __name__ == '__main__':
    unittest.main()
