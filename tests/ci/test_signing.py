import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('signing', ROOT / 'scripts/ci/sign-macos.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningTests(unittest.TestCase):
    def test_identity_is_exact_type_and_team(self):
        digest = 'A' * 40
        value = f'1) {digest} "Developer ID Application: Example (ABCDEFGHIJ)"'
        self.assertEqual(signing.signing_identity(value, 'Developer ID Application', 'ABCDEFGHIJ'), digest)
        for kind, team, output in (
                ('Developer ID Installer', 'ABCDEFGHIJ', value),
                ('Developer ID Application', 'KLMNOPQRST', value),
                ('Developer ID Application', 'ABCDEFGHIJ', value + '\n' + value)):
            with self.assertRaises(signing.SigningError):
                signing.signing_identity(output, kind, team)

    def test_rejects_local_and_untrusted_execution(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(signing.SigningError):
                signing.runner_directory()

    def test_tool_failure_cannot_echo_credentials(self):
        result = subprocess.CompletedProcess(['fixture'], 1, 'sensitive output', 'sensitive error')
        with patch.object(signing.subprocess, 'run', return_value=result):
            with self.assertRaises(signing.SigningError) as failure:
                signing.command('import fixture', ['fixture', 'sensitive argument'])
        self.assertNotIn('sensitive', str(failure.exception))

    def test_cleanup_restores_search_list_and_removes_material(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'plank-macos-signing'
            directory.mkdir(mode=0o700)
            (directory / 'search-list.json').write_text('["/example/login.keychain-db"]')
            (directory / 'signing.keychain-db').touch()
            (directory / 'application.p12').touch()
            with patch.object(signing, 'command') as command:
                signing.cleanup(directory)
            self.assertEqual(command.call_count, 2)
            self.assertIn('/example/login.keychain-db', command.call_args_list[0].args[1])
            self.assertFalse(directory.exists())

    def test_missing_secret_prevents_keychain_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'plank-macos-signing'
            with patch.dict(os.environ, {'PLANK_CI_PRODUCT': 'macos-host', 'PLANK_MACOS_TEAM_ID': 'ABCDEFGHIJ'}, clear=True), \
                    patch.object(signing, 'runner_directory', return_value=directory), \
                    patch.object(signing.sys, 'argv', ['sign-macos.py']), \
                    patch.object(signing, 'command') as command:
                with self.assertRaises(signing.SigningError):
                    signing.main()
                command.assert_not_called()
            self.assertFalse(directory.exists())

    def test_probe_uses_fixed_diagnostic_commands_without_secret_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'plank-macos-signing'
            env = {name: 'Zml4dHVyZQ==' for name in signing.SECRET_NAMES}
            env.update(PLANK_CI_PRODUCT='macos-fullscreen-probe', PLANK_MACOS_TEAM_ID='ABCDEFGHIJ',
                       PLANK_SOURCE_ROOT='/example/source', PLANK_WORK_ROOT=temporary+'/work')
            calls = []

            def run(args):
                self.assertFalse(set(signing.SECRET_NAMES) & set(os.environ))
                calls.append(args)
                return subprocess.CompletedProcess(args, 0)

            def command(stage, args):
                if stage == 'read keychain search list':
                    return '"/example/login.keychain-db"'
                if stage == 'validate signing identities':
                    return ('A'*40 + ' "Developer ID Application: Example (ABCDEFGHIJ)"\n' +
                            'B'*40 + ' "Developer ID Installer: Example (ABCDEFGHIJ)"')
                return ''

            with patch.dict(os.environ, env, clear=True), \
                    patch.object(signing, 'runner_directory', return_value=directory), \
                    patch.object(signing.sys, 'argv', ['sign-macos.py']), \
                    patch.object(signing, 'command', side_effect=command), \
                    patch.object(signing.subprocess, 'run', side_effect=run):
                signing.main()
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0][1], '/example/source/scripts/package/build-macos-fullscreen-probe.sh')
            self.assertEqual(calls[0][2], '--build')
            self.assertEqual(calls[1][2], '--package')
            self.assertFalse(directory.exists())

    def test_products_do_not_repeat_bootstrap_and_cleanup_after_build_failure(self):
        for role in ('macos-host', 'macos-client'):
            for build_status in (0, 1):
                with self.subTest(role=role, build_status=build_status), tempfile.TemporaryDirectory() as temporary:
                    directory = Path(temporary) / 'plank-macos-signing'
                    env = {name: 'Zml4dHVyZQ==' for name in signing.SECRET_NAMES}
                    env.update(PLANK_CI_PRODUCT=role, PLANK_MACOS_TEAM_ID='ABCDEFGHIJ',
                               PLANK_SOURCE_ROOT='/example/source')

                    def run(args):
                        self.assertFalse(set(signing.SECRET_NAMES) & set(os.environ))
                        self.assertEqual(args, ['bash', '/example/source/scripts/ci/build.sh', role])
                        if role == 'macos-host':
                            profile = Path(os.environ['PLANK_MACOS_APP_PROVISION_PROFILE'])
                            self.assertEqual(profile.read_bytes(), b'fixture')
                            self.assertEqual(profile.stat().st_mode & 0o777, 0o600)
                        return subprocess.CompletedProcess(args, build_status)

                    def command(stage, args):
                        if stage == 'read keychain search list':
                            return '"/example/login.keychain-db"'
                        if stage == 'validate signing identities':
                            return ('A'*40 + ' "Developer ID Application: Example (ABCDEFGHIJ)"\n' +
                                    'B'*40 + ' "Developer ID Installer: Example (ABCDEFGHIJ)"')
                        return ''

                    with patch.dict(os.environ, env, clear=True), \
                            patch.object(signing, 'runner_directory', return_value=directory), \
                            patch.object(signing.sys, 'argv', ['sign-macos.py']), \
                            patch.object(signing, 'command', side_effect=command), \
                            patch.object(signing.subprocess, 'run', side_effect=run) as subprocess_run:
                        if build_status:
                            with self.assertRaises(signing.SigningError):
                                signing.main()
                        else:
                            signing.main()
                        subprocess_run.assert_called_once()
                    self.assertFalse(directory.exists())


if __name__ == '__main__':
    unittest.main()
