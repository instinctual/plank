#!/usr/bin/env python3
"""Repository-only artifact tests; dummy payloads never claim package validation."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('collector', ROOT / 'scripts/package/collect-package.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CollectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'packaging').mkdir()
        (self.root / 'packaging/VERSION').write_text('1.2.3\n')
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.DEVNULL)
        git('init', '-b', 'main')
        git('add', 'packaging/VERSION')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture')

    def arguments(self, branch='main', content=b'fixture'):
        suffix = '' if branch == 'main' else '-' + branch
        package = self.root / ('plank-client_1.2.3' + suffix + '_arm64.pkg')
        package.write_bytes(content)
        return SimpleNamespace(source_root=self.root, source_commit='HEAD', package=package,
            product='client', platform='macos', architecture='arm64', target_os='macos-27',
            branch=branch, validation='not-recorded', expected_sha256=None, output_root=None, move=False)

    def host_version(self, branch, target=None):
        env = dict(os.environ, PLANK_BUILD_BRANCH=branch)
        env.pop('PLANK_MACOS_HOST_MIN_OS', None)
        if target is not None:
            env['PLANK_MACOS_HOST_MIN_OS'] = target
        return subprocess.run(['bash', '-euc',
            'source "$1"; plank_load_macos_host_package_version "$2"; '
            'plank_load_macos_host_package_version "$2"; '
            'printf "%s\\n" "$PLANK_PACKAGE_VERSION" "$PLANK_BUILD_BRANCH_RESOLVED" '
            '"$PLANK_BASE_VERSION" "$PLANK_RPM_VERSION" "$PLANK_RPM_RELEASE"',
            'host-version-test', str(ROOT / 'scripts/package/package-version.sh'), str(self.root)],
            env=env, capture_output=True, text=True)

    def host_arguments(self, target, branch='test-host'):
        result = self.host_version(branch, target)
        self.assertEqual(result.returncode, 0, result.stderr)
        version = result.stdout.splitlines()[0]
        args = self.arguments(branch)
        args.product = 'host'
        args.target_os = 'macos-' + target
        args.package = self.root / ('plank-host_' + version + '_arm64.pkg')
        args.package.write_bytes(('dummy Host for ' + target).encode())
        return args

    def test_host_candidates_coexist_in_either_collection_order(self):
        for order in (('26.7', '27.0'), ('27.0', '26.7')):
            with self.subTest(order=order):
                output = self.root / ('catalog-' + '-'.join(order))
                for target in order:
                    args = self.host_arguments(target)
                    args.output_root = output
                    # Exercise the public CLI, using the production shell's version.
                    command = ['python3', str(ROOT / 'scripts/package/collect-package.py'),
                               '--source-root', str(self.root), '--package', str(args.package),
                               '--product', 'host', '--platform', 'macos', '--architecture', 'arm64',
                               '--target-os', args.target_os, '--branch', args.branch,
                               '--output-root', str(output), '--expected-sha256', MODULE.digest(args.package)]
                    first = subprocess.check_output(command, text=True)
                    self.assertEqual(subprocess.check_output(command, text=True), first)
                self.assertEqual({p.name for p in (output / 'candidates').iterdir()},
                                 {'1.2.3-test-host', '1.2.3-test-host-macos27.0'})
                for target in order:
                    version = '1.2.3-test-host' + ('-macos27.0' if target == '27.0' else '')
                    directory = output / 'candidates' / version
                    filename = 'plank-host_' + version + '_arm64.pkg'
                    package = directory / 'macos' / filename
                    self.assertEqual(package.read_bytes(), ('dummy Host for ' + target).encode())
                    manifest = json.loads((directory / 'manifest.json').read_text())
                    self.assertEqual((manifest['version'], manifest['branch'], manifest['channel']),
                                     (version, 'test-host', 'candidates'))
                    self.assertEqual(len(manifest['packages']), 1)
                    record = manifest['packages'][0]
                    self.assertEqual(record['target_os'], 'macos-' + target)
                    self.assertEqual(record['path'], 'macos/' + filename)
                    self.assertEqual(record['sha256'], MODULE.digest(package))
                    self.assertEqual(record['source_commit'], MODULE.git(self.root, 'rev-parse', 'HEAD'))
                    self.assertEqual(record['validation'],
                                     {'package': 'not-recorded', 'functional': 'not-recorded'})
                    self.assertEqual((directory / 'SHA256SUMS').read_text(),
                                     record['sha256'] + '  macos/' + filename + '\n')
                    self.assertEqual(package.with_name(filename + '.sha256').read_text(),
                                     record['sha256'] + '  ' + filename + '\n')

    def test_host_candidate_conflicts_preserve_both_catalog_entries(self):
        arguments = [self.host_arguments(target) for target in ('26.7', '27.0')]
        for args in arguments:
            MODULE.collect(args)
        catalog = self.root / 'artifacts/packages'
        def snapshot():
            return {p.relative_to(catalog): p.read_bytes() for p in catalog.rglob('*') if p.is_file()}
        before = snapshot()
        for args in arguments:
            original = args.package.read_bytes()
            args.package.write_bytes(b'changed payload')
            with self.assertRaisesRegex(ValueError, 'conflicting artifact/provenance'):
                MODULE.collect(args)
            self.assertEqual(snapshot(), before)
            args.package.write_bytes(original)
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty',
                        '-qm', 'Different source provenance'], check=True)
        for args in arguments:
            with self.assertRaisesRegex(ValueError, 'conflicting artifact/provenance'):
                MODULE.collect(args)
            self.assertEqual(snapshot(), before)

    def test_host_filename_must_match_selected_floor(self):
        args = self.host_arguments('26.7')
        args.target_os = 'macos-27.0'
        with self.assertRaisesRegex(ValueError, 'filename disagrees'):
            MODULE.collect(args)
        args.package = args.package.rename(self.root / 'plank-host_1.2.3-test-host-macos27.0_arm64.pkg')
        args.target_os = 'macos-26.7'
        with self.assertRaisesRegex(ValueError, 'filename disagrees'):
            MODULE.collect(args)
        self.assertFalse((self.root / 'artifacts').exists())

    def test_host_mainline_and_default_target_identity(self):
        for target in (None, '26.7'):
            result = self.host_version('main', target)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['1.2.3', 'main', '1.2.3', '1.2.3', '1'])
        self.assertEqual(self.host_version('test-host').stdout.splitlines(),
                         ['1.2.3-test-host', 'test-host', '1.2.3', '1.2.3', '0.test_host.1'])
        # Original 27-only release manifests remain valid during transfer.
        for target_os in ('macos-26.7', 'macos-27', 'macos-27.0'):
            args = self.host_arguments('26.7', 'main')
            args.target_os = target_os
            args.output_root = self.root / target_os
            MODULE.collect(args)
            self.assertTrue((args.output_root / 'releases/1.2.3/macos/plank-host_1.2.3_arm64.pkg').is_file())

    def test_host_rejects_mainline_comparison_and_unknown_floor(self):
        self.assertNotEqual(self.host_version('main', '27.0').returncode, 0)
        for branch, target in (('main', '26.6'), ('test-host', '26.6'), ('test-host', '28.0')):
            with self.subTest(branch=branch, target=target):
                result = self.host_version(branch, target)
                self.assertNotEqual(result.returncode, 0)
                args = self.host_arguments('26.7', branch)
                args.target_os = 'macos-' + target
                with self.assertRaisesRegex(ValueError, 'unsupported macOS Host'):
                    MODULE.collect(args)
        self.assertFalse((self.root / 'artifacts').exists())

    def test_mainline_host_floor_cannot_relabel_existing_package(self):
        args = self.host_arguments('26.7', 'main')
        MODULE.collect(args)
        manifest = self.root / 'artifacts/packages/releases/1.2.3/manifest.json'
        original = manifest.read_bytes()
        args.target_os = 'macos-27.0'
        with self.assertRaisesRegex(ValueError, 'conflicting artifact/provenance'):
            MODULE.collect(args)
        self.assertEqual(manifest.read_bytes(), original)

    def test_historical_host_candidate_keeps_original_identity(self):
        args = self.arguments('test-host', b'immutable historical package')
        args.product = 'host'
        args.package = args.package.rename(self.root / 'plank-host_1.2.3-test-host_arm64.pkg')
        MODULE.collect(args)
        # Preserve historical target_os=macos-27; no renaming during transfer.
        directory = self.root / 'artifacts/packages/candidates/1.2.3-test-host'
        before = (directory / 'manifest.json').read_bytes()
        MODULE.collect(self.host_arguments('27.0'))
        MODULE.collect(args)
        self.assertEqual((directory / 'manifest.json').read_bytes(), before)
        self.assertEqual((directory / 'macos' / args.package.name).read_bytes(), b'immutable historical package')

    def test_host_target_does_not_change_client_or_linux_identity(self):
        for target in ('26.7', '27.0'):
            values = subprocess.check_output(['bash', '-euc',
                'source "$1"; PLANK_BUILD_BRANCH=test-host; PLANK_MACOS_HOST_MIN_OS="$2"; '
                'plank_load_package_version "$3"; printf "%s\\n" "$PLANK_PACKAGE_VERSION"',
                'version-test', str(ROOT / 'scripts/package/package-version.sh'), target, str(self.root)], text=True)
            self.assertEqual(values.strip(), '1.2.3-test-host')
            args = self.arguments('test-host')
            args.target_os = 'macos-' + target
            args.output_root = self.root / args.target_os
            MODULE.collect(args)
            self.assertTrue((args.output_root / 'candidates/1.2.3-test-host/macos' / args.package.name).is_file())
        args = self.arguments('test-host')
        args.product, args.platform, args.architecture, args.target_os = 'host', 'linux', 'x86_64', 'rocky-9.7'
        args.package = args.package.rename(self.root / 'plank-host-1.2.3-0.test_host.1.el9.x86_64.rpm')
        MODULE.collect(args)
        self.assertTrue((self.root / 'artifacts/packages/candidates/1.2.3-test-host/linux' / args.package.name).is_file())

    def test_release_and_manifest(self):
        args = self.arguments()
        MODULE.collect(args)
        directory = self.root / 'artifacts/packages/releases/1.2.3'
        record = json.loads((directory / 'manifest.json').read_text())['packages'][0]
        self.assertEqual(record['validation']['functional'], 'not-recorded')
        self.assertEqual(record['sha256'], MODULE.digest(args.package))
        self.assertIn('macos/' + args.package.name, (directory / 'SHA256SUMS').read_text())
        MODULE.collect(args)  # Identical re-collection is safe.

    def test_candidate_and_move(self):
        args = self.arguments('feature-one')
        args.move = True
        MODULE.collect(args)
        self.assertFalse(args.package.exists())
        self.assertTrue((self.root / 'artifacts/packages/candidates/1.2.3-feature-one/macos' / args.package.name).is_file())

    def test_conflicting_package(self):
        args = self.arguments()
        MODULE.collect(args)
        args.package.write_bytes(b'different')
        with self.assertRaises(ValueError):
            MODULE.collect(args)

    def test_wrong_checksum(self):
        args = self.arguments()
        args.expected_sha256 = '0' * 64
        with self.assertRaises(ValueError):
            MODULE.collect(args)

    def test_ubuntu_client_uses_normal_product(self):
        args = self.arguments()
        args.package = args.package.rename(args.package.with_name('plank-client_1.2.3_amd64.deb'))
        args.platform = 'linux'
        args.architecture = 'amd64'
        args.target_os = 'ubuntu-26.04'
        MODULE.collect(args)
        self.assertTrue((self.root / 'artifacts/packages/releases/1.2.3/linux' / args.package.name).is_file())
        args.product = 'client-qt'
        with self.assertRaisesRegex(ValueError, 'product'):
            MODULE.collect(args)

    def test_wrong_branch_filename(self):
        args = self.arguments()
        args.branch = 'other'
        with self.assertRaises(ValueError):
            MODULE.collect(args)

    def test_provenance_conflict(self):
        args = self.arguments()
        MODULE.collect(args)
        args.target_os = 'another-os'
        with self.assertRaises(ValueError):
            MODULE.collect(args)

    def test_zero_padded_product_version(self):
        (self.root / 'packaging/VERSION').write_text('1.2.00\n')
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@example.invalid', 'commit', '-am', 'padded version'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for branch in ('main', 'feature-one'):
            version = '1.2.00' + ('' if branch == 'main' else '-' + branch)
            values = subprocess.check_output(['bash', '-c',
                'source "$1"; PLANK_BUILD_BRANCH="$2"; plank_load_package_version "$3"; '
                'printf "%s\\n" "$PLANK_PACKAGE_VERSION" "$PLANK_RPM_VERSION"',
                'version-test', str(ROOT / 'scripts/package/package-version.sh'), branch, str(self.root)], text=True)
            self.assertEqual(values.splitlines(), [version, '1.2.00'])
            args = self.arguments(branch)
            args.package = args.package.rename(args.package.with_name('plank-client_' + version + '_arm64.pkg'))
            MODULE.collect(args)
            channel = 'releases' if branch == 'main' else 'candidates'
            directory = self.root / 'artifacts/packages' / channel / version
            manifest = json.loads((directory / 'manifest.json').read_text())
            self.assertEqual(manifest['version'], version)
            self.assertEqual(manifest['packages'][0]['path'], 'macos/' + args.package.name)


if __name__ == '__main__':
    unittest.main()
