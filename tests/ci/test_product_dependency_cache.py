"""Dependency isolation and fail-closed restore tests; no downloads or builds."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('product_cache', ROOT / 'scripts/ci/cache-dependencies.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class ProductDependencyCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'source'
        self.deps = Path(self.tmp.name) / 'deps'
        self.tools = {'platform': {'architecture': 'fixture', 'os': 'fixture'},
                      'compiled': {'sdk': 'fixture', 'packages': ['lib=1']}}
        inputs = (
            'scripts/ci/cache-dependencies.py', 'rust-toolchain.toml',
            'protocol/plank-transport/Cargo.toml', 'protocol/plank-transport/Cargo.lock',
            'third_party/quinn-proto-0.11.17/Cargo.toml',
            'third_party/quinn-proto-0.11.17/Cargo.lock',
            'scripts/build/build-paths.sh', 'scripts/build/build-client-ffmpeg.sh',
            'scripts/build/bootstrap-macos-client-deps.sh', 'scripts/build/macos-client-target.sh',
            'scripts/build/relocate-openssl-pc.py', 'scripts/build/sanitize-ffmpeg-build-info.py',
            'scripts/build/verify-host-dependency-patches.sh', cache.IDENTITY_PATCH,
            'scripts/build/build-client-sdl.sh', 'scripts/build/client-sdl.sh',
            'tests/input/test-sdl-cursor-retirement.py', 'scripts/test/check-client-sdl.py', cache.SDL_PATCH,
        )
        for name in (*inputs, *(str(p.relative_to(ROOT)) for p in
                                (ROOT / cache.RECIPES).glob('*.sh'))):
            self.write(self.root / name, 'fixture')
        self.host_deps = self.root / cache.HOST_DEPS
        self.write(self.host_deps / 'CMakeLists.txt', 'fixture')
        subprocess.run(['git', 'init', '-q', str(self.host_deps)], check=True)
        subprocess.run(['git', '-C', str(self.host_deps), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.host_deps), '-c', 'user.name=CI fixture',
                        '-c', 'user.email=ci@example.org', 'commit', '-qm', 'Fixture'], check=True)

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def key(self, product, component, tools=None):
        return cache.fingerprint(self.root, self.deps, product, component, tools or self.tools)

    def keys(self):
        return {(product, component): self.key(product, component)
                for product, components in cache.COMPONENTS.items() for component in components}

    def assert_changes_only(self, path, expected):
        before = self.keys()
        self.write(self.root / path, 'changed')
        after = self.keys()
        self.assertEqual({pair for pair in before if before[pair] != after[pair]}, expected)
        self.write(self.root / path, 'fixture')

    def test_application_version_and_orchestration_changes_do_not_invalidate(self):
        keys = self.keys()
        for name in ('packaging/VERSION', 'apps/host/macos/example.m',
                     'apps/client/app/example.cpp', 'scripts/ci/bootstrap.sh',
                     'scripts/ci/build.sh', '.github/workflows/build.yml'):
            self.write(self.root / name, 'application or orchestration change')
            self.assertEqual(keys, self.keys())

    def test_transport_lock_and_manifest_only_invalidate_cargo(self):
        expected = {(product, 'cargo') for product in cache.PRODUCTS}
        for name in ('Cargo.lock', 'Cargo.toml'):
            self.assert_changes_only('protocol/plank-transport/' + name, expected)

    def test_vendor_test_inputs_only_invalidate_host_cargo(self):
        for name in ('Cargo.lock', 'Cargo.toml'):
            self.assert_changes_only('third_party/quinn-proto-0.11.17/' + name,
                                     {('linux-host', 'cargo')})

    def test_rust_toolchain_invalidates_rust_and_cargo_not_libraries(self):
        expected = {(product, component) for product in cache.PRODUCTS
                    for component in ('rust', 'cargo')}
        for name in ('rust-toolchain.toml', cache.RECIPES + 'rust.sh'):
            self.assert_changes_only(name, expected)

    def test_library_recipes_invalidate_only_their_dependency(self):
        for recipe, pair in (
            ('boost.sh', ('linux-host', 'boost')),
            ('host-ffmpeg.sh', ('linux-host', 'ffmpeg')),
            ('client-ffmpeg.sh', ('linux-client', 'ffmpeg')),
            ('client-sdl.sh', ('linux-client', 'native')),
            ('macos-libraries.sh', ('macos-client', 'native')),
            ('qt.sh', ('macos-client', 'qt')),
        ):
            self.assert_changes_only(cache.RECIPES + recipe, {pair})

    def test_ffmpeg_patch_does_not_invalidate_qt_rust_or_boost(self):
        expected = {('linux-client', 'ffmpeg'), ('macos-client', 'native')}
        self.assert_changes_only(cache.IDENTITY_PATCH, expected)
        self.assert_changes_only(cache.CLIENT_PATCHES + '/new.patch', expected)

    def test_native_library_helpers_do_not_invalidate_qt(self):
        expected = {('macos-client', 'native')}
        self.assert_changes_only('scripts/build/bootstrap-macos-client-deps.sh', expected)
        self.assert_changes_only('scripts/build/relocate-openssl-pc.py', expected)
        self.assert_changes_only('scripts/build/build-paths.sh',
                                 expected | {('linux-client', 'ffmpeg'), ('linux-client', 'native')})

    def test_sdl_repair_only_invalidates_ubuntu_sdl(self):
        self.assert_changes_only(cache.SDL_PATCH, {('linux-client', 'native')})
        self.assert_changes_only('scripts/build/client-sdl.sh', {('linux-client', 'native')})
        (self.root / cache.SDL_PATCH).unlink()
        with self.assertRaises(FileNotFoundError):
            self.key('linux-client', 'native')
        self.key('macos-client', 'native')

    def test_host_codec_tree_changes_only_invalidate_host_ffmpeg(self):
        self.assert_changes_only(cache.HOST_DEPS + '/CMakeLists.txt', {('linux-host', 'ffmpeg')})
        with patch.object(cache, 'output', side_effect=lambda cmd: '0' * 40 if 'rev-parse' in cmd
                          else '160000 ' + '1' * 40 + ' 0\tFFmpeg/source'):
            before = self.key('linux-host', 'ffmpeg')
        with patch.object(cache, 'output', side_effect=lambda cmd: '0' * 40 if 'rev-parse' in cmd
                          else '160000 ' + '2' * 40 + ' 0\tFFmpeg/source'):
            self.assertNotEqual(before, self.key('linux-host', 'ffmpeg'))

    def test_compiler_sdk_or_package_updates_only_invalidate_compiled_libraries(self):
        before = self.keys()
        self.tools['compiled'] = {'sdk': 'new', 'packages': ['lib=2']}
        after = self.keys()
        self.assertEqual({pair for pair in before if before[pair] != after[pair]},
                         {('linux-host', 'ffmpeg'), ('linux-client', 'ffmpeg'),
                          ('macos-client', 'native'), ('linux-client', 'native')})

    def test_product_platform_and_absolute_paths_are_exact(self):
        keys = self.keys()
        self.assertEqual(len(set(keys.values())), len(keys))
        for (product, component), key in keys.items():
            self.assertTrue(cache.key_valid(key, product, component))
            self.assertNotEqual(key, cache.fingerprint(
                self.root, self.deps / 'other', product, component, self.tools))
            self.assertNotEqual(key, self.key(product, component,
                dict(self.tools, platform={'architecture': 'other'})))
            self.assertFalse(cache.key_valid(key, product, 'other'))

    def test_mac_client_target_is_preserved(self):
        for component in ('native', 'qt'):
            with patch.dict(cache.os.environ, {}, clear=True):
                key = self.key('macos-client', component)
            for value in ('', '15.0'):
                with patch.dict(cache.os.environ, {'PLANK_MAC_CLIENT_MIN_MACOS': value}):
                    self.assertEqual(key, self.key('macos-client', component))
            for value in ('14.0', '27.0', 'unknown'):
                with patch.dict(cache.os.environ, {'PLANK_MAC_CLIENT_MIN_MACOS': value}):
                    with self.assertRaises(ValueError):
                        self.key('macos-client', component)

    def test_missing_patch_fails_closed_only_for_its_consumers(self):
        (self.root / cache.IDENTITY_PATCH).unlink()
        for product, component in (('linux-client', 'ffmpeg'), ('macos-client', 'native')):
            with self.assertRaises(FileNotFoundError):
                self.key(product, component)
        self.key('macos-client', 'qt')
        self.key('linux-client', 'cargo')

    def test_cache_paths_do_not_overlap_or_include_credentials_and_app_objects(self):
        for product, components in cache.COMPONENTS.items():
            paths = [path for component in components
                     for path in cache.cache_paths(self.root, self.deps, product, component)]
            for i, path in enumerate(paths):
                for other in paths[i + 1:]:
                    self.assertNotEqual(path, other)
                    self.assertNotIn(path, other.parents)
                    self.assertNotIn(other, path.parents)
                self.assertNotIn('target', path.parts)
                self.assertNotIn('packages', path.parts)
            for name in ('cargo/credentials.toml', 'cargo/config.toml', 'cargo/.credentials',
                         'signing/keychain', 'macos-client/build-ffmpeg'):
                sensitive = self.deps / name
                self.assertFalse(any(path == sensitive or path in sensitive.parents for path in paths))
            self.assertNotIn(cache.hits_path(self.deps, product), paths)
        self.assertEqual(cache.cache_paths(self.root, self.deps, 'linux-client', 'rust')[:-1],
                         [self.deps / 'rustup', self.deps / 'cargo/bin'])
        self.assertIn(self.deps / 'client-ffmpeg/ffmpeg-9.0.1.tar.xz',
                      cache.cache_paths(self.root, self.deps, 'linux-client', 'ffmpeg'))

    def test_receipts_reject_wrong_component_key_schema_or_missing_file(self):
        for (product, component), key in self.keys().items():
            receipt = cache.cache_paths(self.root, self.deps, product, component)[-1]
            for data in ({'schema': 1, 'key': key}, {'schema': 2, 'key': key + 'bad'}):
                self.write(receipt, json.dumps(data))
                with self.assertRaises(ValueError):
                    cache.verify_receipt(self.root, self.deps, product, component, key)
            self.write(receipt, json.dumps({'schema': 2, 'key': key}))
            cache.verify_receipt(self.root, self.deps, product, component, key)
            receipt.unlink()
            with self.assertRaises(FileNotFoundError):
                cache.verify_receipt(self.root, self.deps, product, component, key)

    def test_mixed_hits_and_misses_require_only_restored_dependencies(self):
        product = 'linux-client'
        keys = {c: self.key(product, c) for c in cache.COMPONENTS[product]}
        # Only Rust restored; the other dependencies will be bootstrapped.
        for name in ('cargo/bin/rustup', 'rustup/settings.toml'):
            self.write(self.deps / name, 'fixture')
        receipt = cache.cache_paths(self.root, self.deps, product, 'rust')[-1]
        self.write(receipt, json.dumps({'schema': 2, 'key': keys['rust']}))
        self.assertEqual(cache.verify_restored(self.root, self.deps, product, keys,
                         {'rust': keys['rust'], 'ffmpeg': ''}), {'rust': keys['rust']})
        with self.assertRaises(ValueError):
            cache.verify_restored(self.root, self.deps, product, keys, {'rust': keys['cargo']})
        with self.assertRaises(ValueError):
            cache.verify_restored(self.root, self.deps, product, keys, {'qt': keys['rust']})
        (self.deps / 'cargo/bin/rustup').unlink()
        with self.assertRaises(ValueError):
            cache.verify_restored(self.root, self.deps, product, keys, {'rust': keys['rust']})

    def test_prepared_source_patch_checks_remain_mandatory(self):
        for product, component, names in (
            ('linux-host', 'ffmpeg', ['host-ffmpeg/lib/libavcodec.a', 'host-ffmpeg/lib/libavutil.a']),
            ('linux-client', 'ffmpeg', ['client-ffmpeg/ffmpeg-9.0.1.tar.xz'] +
             ['client-ffmpeg/install/lib/' + name + '.so' for name in
              ('libavcodec', 'libavutil', 'libswscale', 'libswresample')]),
            ('macos-client', 'native', ['macos-client/install/lib/' + name + '.dylib' for name in
             ('libavcodec', 'libavutil', 'libswscale', 'libswresample', 'libssl', 'libcrypto',
              'libSDL3', 'libSDL3_ttf', 'libopus', 'libfreetype')]),
        ):
            with self.assertRaises(ValueError):
                cache.check_prepared(self.root, self.deps, product, component)
            for name in names:
                self.write(self.deps / name, 'fixture')
            with patch.object(cache.subprocess, 'run') as run:
                cache.check_prepared(self.root, self.deps, product, component)
                self.assertTrue(run.call_args.kwargs['check'])
                if product == 'linux-host':
                    self.assertIn('verify-host-dependency-patches.sh', run.call_args.args[0][1])
                else:
                    self.assertIn('--reverse', run.call_args.args[0])
                    self.assertIn('--dry-run', run.call_args.args[0])
            with patch.object(cache.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'patch')):
                with self.assertRaises(subprocess.CalledProcessError):
                    cache.check_prepared(self.root, self.deps, product, component)

    def test_unsupported_product_component_pair_is_rejected(self):
        with self.assertRaises(ValueError):
            self.key('macos-host', 'ffmpeg')
        with self.assertRaises(ValueError):
            cache.cache_paths(self.root, self.deps, 'linux-host', 'qt')

    def test_cli_cold_seal_partial_restore_and_independent_miss(self):
        product = 'linux-client'
        output_path = Path(self.tmp.name) / 'github-output'
        env = {'PLANK_SOURCE_ROOT': str(self.root), 'PLANK_DEP_ROOT': str(self.deps),
               'GITHUB_OUTPUT': str(output_path)}

        def invoke(operation, extra=None):
            with patch.dict(cache.os.environ, dict(env, **(extra or {})), clear=True), \
                 patch('sys.argv', ['cache-dependencies.py', operation, '--product', product]), \
                 patch.object(cache, 'prepare_sources'), \
                 patch.object(cache, 'toolchain_inputs', return_value=self.tools), \
                 patch.object(cache.subprocess, 'run'), patch('sys.stdout', new_callable=io.StringIO):
                cache.main()

        invoke('prepare')
        self.assertIn('rust-hit=false', output_path.read_text())
        self.assertIn('ffmpeg-hit=false', output_path.read_text())
        for name in ('cargo/bin/rustup', 'rustup/settings.toml',
                     'client-sdl/prepared.sha256', 'client-sdl/install/lib/libSDL3.so.0',
                     'client-ffmpeg/ffmpeg-9.0.1.tar.xz',
                     *(f'client-ffmpeg/install/lib/{name}.so' for name in
                       ('libavcodec', 'libavutil', 'libswscale', 'libswresample'))):
            self.write(self.deps / name, 'fixture')
        invoke('seal')
        invoke('verify', {'CACHE_MATCHED_RUST': self.key(product, 'rust'),
                          'CACHE_MATCHED_FFMPEG': self.key(product, 'ffmpeg')})
        hits = json.loads(cache.hits_path(self.deps, product).read_text())
        self.assertEqual(set(hits), {'rust', 'ffmpeg'})
        self.write(output_path, '')
        self.write(self.root / 'protocol/plank-transport/Cargo.lock', 'new lock')
        invoke('prepare')
        result = output_path.read_text()
        self.assertIn('rust-hit=true', result)
        self.assertIn('ffmpeg-hit=true', result)
        self.assertIn('cargo-hit=false', result)


if __name__ == '__main__':
    unittest.main()
