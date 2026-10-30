"""Exercise target selection and dispatch/build routing without signing or services."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('host_context', ROOT / 'scripts/ci/context.py')
CONTEXT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTEXT)
SHA = 'a' * 40


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


class HostTargetTests(unittest.TestCase):
    def test_comparison_requires_manual_host_candidate_and_standard_floor_is_unrestricted(self):
        self.assertEqual(CONTEXT.macos_host_target(
            '27.0', 'macos-host', 'workflow_dispatch', 'test-host', 'branch'), '27.0')
        for product in ('all', 'linux-host', 'linux-client', 'macos-client', 'macos-fullscreen-probe'):
            with self.assertRaises(ValueError):
                CONTEXT.macos_host_target('27.0', product, 'workflow_dispatch', 'test-host', 'branch')
            self.assertEqual(CONTEXT.macos_host_target(
                '26.7', product, 'workflow_dispatch', 'main', 'branch'), '26.7')
        for event, ref, kind in [('push', 'test-host', 'branch'),
                                 ('pull_request', 'test-host', 'branch'),
                                 ('workflow_dispatch', 'main', 'branch'),
                                 ('workflow_dispatch', 'test-host', 'tag')]:
            with self.assertRaises(ValueError):
                CONTEXT.macos_host_target('27.0', 'macos-host', event, ref, kind)
            self.assertEqual(CONTEXT.macos_host_target('26.7', 'all', event, ref, kind), '26.7')
        for target in ('', '26', '26.6', '28.0', '26.7\nUNTRUSTED=value'):
            with self.assertRaises(ValueError):
                CONTEXT.macos_host_target(target, 'macos-host', 'workflow_dispatch', 'test-host', 'branch')

    def test_context_exports_target_and_rejects_bad_selection_before_scratch(self):
        for target, product, accepted in [('26.7', 'all', True), ('26.7', 'macos-host', True),
                                         ('26.7', 'macos-client', True), ('27.0', 'macos-host', True),
                                         ('27.0', 'all', False), ('26.6', 'macos-host', False)]:
            with self.subTest(target=target, product=product), tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve()
                source = base / 'checkout'
                subprocess.run(['git', 'init', '-q', str(source)], check=True)
                subprocess.run(['git', '-C', str(source), '-c', 'user.name=CI fixture',
                                '-c', 'user.email=ci@example.org', 'commit', '-q',
                                '--allow-empty', '-m', 'Fixture'], check=True)
                sha = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
                env_file = base / 'github-env'
                env = dict(os.environ, GITHUB_WORKSPACE=str(source), RUNNER_TEMP=str(base),
                           GITHUB_SHA=sha, EXPECTED_SOURCE_SHA=sha, BUILD_REF='test-host',
                           GITHUB_ENV=str(env_file), GITHUB_EVENT_NAME='workflow_dispatch',
                           GITHUB_REF_TYPE='branch', REQUESTED_PRODUCT=product,
                           REQUESTED_MACOS_HOST_MIN_OS=target,
                           PLANK_MACOS_HOST_MIN_OS='untrusted-inherited-value')
                result = subprocess.run(['python3', str(ROOT / 'scripts/ci/context.py')],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                if accepted:
                    values = dict(line.split('=', 1) for line in env_file.read_text().splitlines())
                    self.assertEqual(values['PLANK_MACOS_HOST_MIN_OS'], target)
                else:
                    self.assertFalse(env_file.exists())
                    self.assertFalse((base / 'plank-ci').exists())

    def dispatch(self, arguments, branch='test-host', remote=SHA, dirty=''):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            executable(base / 'git', '''#!/bin/bash
case "$1" in
  status) printf '%s' "$TEST_DIRTY" ;;
  symbolic-ref) printf '%s\\n' "$TEST_BRANCH" ;;
  rev-parse) printf '%s\\n' "$TEST_SHA" ;;
  ls-remote) printf '%s\\trefs/heads/%s\\n' "$TEST_REMOTE" "$TEST_BRANCH" ;;
  *) exit 99 ;;
esac
''')
            executable(base / 'gh', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['TEST_ARGS']).write_text(json.dumps(sys.argv[1:]))
''')
            args = base / 'args.json'
            env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ['PATH'],
                       TEST_DIRTY=dirty, TEST_BRANCH=branch, TEST_SHA=SHA,
                       TEST_REMOTE=remote, TEST_ARGS=str(args))
            result = subprocess.run(['bash', str(ROOT / 'scripts/ci/dispatch.sh'), *arguments],
                                    env=env, capture_output=True, text=True)
            return result, json.loads(args.read_text()) if args.exists() else None

    def test_dispatch_preserves_default_and_transmits_explicit_target_and_exact_revision(self):
        result, args = self.dispatch([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('product=all', args)
        self.assertIn('macos_host_min_os=26.7', args)
        for signed in ('false', 'true'):
            result, args = self.dispatch(['macos-host', signed], branch='main')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('macos_host_min_os=26.7', args)
            for target in ('26.7', '27.0'):
                for options in (['--macos-host-min-os=' + target, '--clean-bootstrap'],
                                ['--clean-bootstrap', '--macos-host-min-os=' + target]):
                    result, args = self.dispatch(['macos-host', signed, *options])
                    self.assertEqual(result.returncode, 0, result.stderr)
                    for field in ('macos_host_min_os=' + target, 'clean_bootstrap=true',
                                  'source_sha=' + SHA, 'signed=' + signed):
                        self.assertIn(field, args)
        for product in ('all', 'linux-host', 'linux-client', 'macos-client'):
            result, args = self.dispatch([product, 'false'], branch='main')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('macos_host_min_os=26.7', args)

    def test_invalid_or_unpushed_dispatch_never_calls_github(self):
        for arguments in (['macos-client', 'true', '--macos-host-min-os=27.0'],
                          ['all', 'false', '--macos-host-min-os=27.0'],
                          ['macos-host', 'true', '--macos-host-min-os=26.6'],
                          ['macos-host', 'true', '--macos-host-min-os=26.7', '--macos-host-min-os=27.0'],
                          ['macos-host', 'true', '--clean-bootstrap', '--clean-bootstrap']):
            result, args = self.dispatch(arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(args)
        for overrides in ({'branch': 'main'}, {'remote': 'b' * 40}, {'dirty': ' M example'}):
            result, args = self.dispatch(['macos-host', 'true', '--macos-host-min-os=27.0'], **overrides)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(args)

    def test_build_routes_same_target_to_transport_and_signed_or_unsigned_assembly(self):
        for target in ('27.0', '26.7'):
            for signed in ('false', 'true'):
                with self.subTest(target=target, signed=signed), tempfile.TemporaryDirectory() as directory:
                    base = Path(directory)
                    source = base / 'source'
                    record = base / 'calls'
                    executable(source / 'tests/network/test_datagram_sender.py', 'pass\n')
                    executable(source / 'scripts/package/package-version.sh',
                               (ROOT / 'scripts/package/package-version.sh').read_text())
                    (source / 'packaging').mkdir()
                    (source / 'packaging/VERSION').write_text('1.2.02\n')
                    package_source = (ROOT / 'scripts/package/build-macos-host-pkg.sh').read_text()
                    # Execute the production package-version setup only. All
                    # signing, compilation and package operations stay stubbed.
                    version_setup = package_source.split(
                        'source "$source_root/scripts/package/package-version.sh"', 1)[1].split(
                        'identities=$(security', 1)[0]
                    for script, label in [('scripts/build/build-macos-transport.sh', 'transport'),
                                          ('scripts/build/build-macos-host.sh', 'assembly'),
                                          ('scripts/package/build-macos-host-pkg.sh', 'package')]:
                        setup = ''
                        if label == 'package':
                            setup = ('set -eu\nsource_root=$1\n'
                                     'source "$source_root/scripts/package/package-version.sh"' + version_setup)
                        if label == 'transport':
                            record_command = 'printf "transport:%s\\n" "$PLANK_MACOS_HOST_MIN_OS"'
                        else:
                            record_command = ('printf "%s:%s:%s\\n" ' + label +
                                              ' "$PLANK_MACOS_HOST_MIN_OS" "$PLANK_MACOS_HOST_VERSION"')
                        executable(source / script, setup + record_command + ' >> "$TEST_RECORD"\n')
                    # Isolated stubs: no sudo, package scripts, compiler or Git state changes.
                    for command in ('sudo', 'git'):
                        executable(base / 'bin' / command, '#!/bin/bash\nexit 0\n')
                    env = dict(os.environ, PLANK_SOURCE_ROOT=str(source),
                               PLANK_WORK_ROOT=str(base / 'work'), PLANK_CARGO_ROOT=str(base / 'cargo'),
                               PLANK_RUSTUP_ROOT=str(base / 'rustup'), PLANK_CI_SIGNED=signed,
                               PLANK_BUILD_BRANCH='test-host',
                               PLANK_MACOS_HOST_MIN_OS=target, TEST_RECORD=str(record),
                               PATH=str(base / 'bin') + os.pathsep + os.environ['PATH'])
                    result = subprocess.run(['bash', str(ROOT / 'scripts/ci/build.sh'), 'macos-host'],
                                            env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(record.read_text().splitlines(),
                                     ['transport:' + target,
                                      ('package:' if signed == 'true' else 'assembly:') + target +
                                      ':1.2.02-test-host-macos' + target])


if __name__ == '__main__':
    unittest.main()
