#!/usr/bin/env python3
"""Non-installing checks of development role identities; no services or OS input."""
import importlib.util
import os
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("installer", ROOT / "scripts/maintenance/install-macos-host-development.py")
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class RoleIdentityTests(unittest.TestCase):
    def test_graphical_drain_precedes_coordinator(self):
        from types import SimpleNamespace
        with patch.object(INSTALLER.os, "stat", return_value=SimpleNamespace(st_uid=502)), \
             patch.object(INSTALLER, "gui_domains", return_value=["gui/502"]), \
             patch.object(INSTALLER, "run", return_value=SimpleNamespace(stdout=
                 "20 0 /Applications/PLANK Host.app/Contents/MacOS/plank-host --sign-in service\n"
                 "99 0 /Applications/Other.app/Contents/MacOS/plank-host --sign-in other\n")), \
             patch.object(INSTALLER, "process_exists", return_value=False) as exists, \
             patch.object(INSTALLER, "stop_job") as stop:
            INSTALLER.stop_roles()
            self.assertEqual([call.args[0] for call in stop.call_args_list], [
                "gui/502/" + INSTALLER.DESKTOP_LABEL, "system/" + INSTALLER.MACHINE_LABEL])
            exists.assert_called_once_with(20)

    def test_existing_gui_domains_are_unique_and_errors_fail_closed(self):
        from types import SimpleNamespace
        with patch.object(INSTALLER.pwd, "getpwall", return_value=[SimpleNamespace(pw_uid=uid) for uid in (0,501,501,502)]), \
             patch.object(INSTALLER, "run", side_effect=[SimpleNamespace(returncode=0),
                 SimpleNamespace(returncode=113, stderr="Could not find domain for user gui: 502")]):
            self.assertEqual(INSTALLER.gui_domains(), ["gui/501"])
        with patch.object(INSTALLER.pwd, "getpwall", return_value=[SimpleNamespace(pw_uid=501)]), \
             patch.object(INSTALLER, "run", return_value=SimpleNamespace(returncode=125,
                 stderr="Could not print domain: 125: Domain does not support specified action")):
            self.assertEqual(INSTALLER.gui_domains(), [])
        with patch.object(INSTALLER.pwd, "getpwall", return_value=[SimpleNamespace(pw_uid=501)]), \
             patch.object(INSTALLER, "run", return_value=SimpleNamespace(returncode=1, stderr="Permission denied")):
            with self.assertRaises(RuntimeError):
                INSTALLER.gui_domains()

    def test_uninstaller_rejects_foreign_or_symlink_jobs(self):
        from unittest.mock import MagicMock
        spec = importlib.util.spec_from_file_location("uninstaller", ROOT / "scripts/maintenance/uninstall-macos-host-development.py")
        uninstaller = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(uninstaller)
        path = MagicMock()
        path.exists.return_value = True
        path.is_symlink.return_value = False
        path.is_file.return_value = True
        path.stat.return_value.st_uid = 0
        path.read_bytes.return_value = plistlib.dumps({"Label":"test", "ProgramArguments":[
            "/Applications/PLANK Host.app/Contents/MacOS/plank-host", "--desktop"]})
        self.assertTrue(uninstaller.owned_job(path, "test"))
        with self.assertRaises(ValueError):
            uninstaller.owned_job(path, "other")
        path.is_symlink.return_value = True
        with self.assertRaises(ValueError):
            uninstaller.owned_job(path, "test")
        path.is_symlink.return_value = False
        path.stat.return_value.st_uid = 501
        with self.assertRaises(ValueError):
            uninstaller.owned_job(path, "test")

    def test_key_only_identity_preserved(self):
        with tempfile.TemporaryDirectory(prefix="plank-keys-") as temporary:
            directory = Path(temporary) / "identity"
            INSTALLER.prepare_sign_in_identity(directory)
            self.assertEqual({p.name for p in directory.iterdir()}, {"cert.pem", "key.pem", "cert.der", "key.der"})
            before = (directory / "key.der").read_bytes()
            INSTALLER.prepare_sign_in_identity(directory)
            self.assertEqual(before, (directory / "key.der").read_bytes())

    def test_system_agent_and_uninstall_scope(self):
        script = (ROOT / "scripts/maintenance/install-macos-host-development.py").read_text()
        self.assertIn('[executable, "--desktop", machine_label]', script)
        self.assertIn('Path("/Library/LaunchAgents") / (graphical_label + ".plist")', script)
        self.assertNotIn('parser.add_argument("--desktop-user"', script)
        self.assertIn('os.setuid(account.pw_uid)', script)
        uninstall = (ROOT / "scripts/maintenance/uninstall-macos-host-development.py").read_text()
        self.assertLess(uninstall.index('INSTALLER.stop_roles()'), uninstall.index('path.unlink()'))
        self.assertNotIn('rmtree', uninstall)
        self.assertNotIn('tccutil', uninstall)
        self.assertIn('sys.dont_write_bytecode = True', uninstall)

    def test_stop_waits_for_job_and_process(self):
        with patch.object(INSTALLER, "job_state", side_effect=[(True, 42), (False, None), (False, None)]), \
             patch.object(INSTALLER, "process_exists", side_effect=[True, False]), \
             patch.object(INSTALLER, "run") as run, patch.object(INSTALLER.time, "sleep") as sleep:
            INSTALLER.stop_job("gui/503/test")
            run.assert_called_once_with("launchctl", "bootout", "gui/503/test", check=False)
            sleep.assert_called_once_with(0.1)

    def test_stop_absent_and_timeout(self):
        with patch.object(INSTALLER, "job_state", return_value=(False, None)), \
             patch.object(INSTALLER, "run") as run:
            INSTALLER.stop_job("gui/503/test")
            run.assert_not_called()
        with patch.object(INSTALLER, "job_state", return_value=(True, 42)), \
             patch.object(INSTALLER, "process_exists", return_value=True), \
             patch.object(INSTALLER, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "replacement/startup cancelled"):
                INSTALLER.stop_job("gui/503/test", timeout=0)
            self.assertEqual(run.call_count, 1)

    def test_inspection_errors_are_not_absence(self):
        from types import SimpleNamespace
        with patch.object(INSTALLER, "run", return_value=SimpleNamespace(returncode=1, stderr="Operation not permitted")):
            with self.assertRaisesRegex(RuntimeError, "Cannot inspect"):
                INSTALLER.job_state("gui/503/test")
        with patch.object(INSTALLER, "run", return_value=SimpleNamespace(returncode=113,
                          stderr='Bad request.\nCould not find service "test" in domain for user gui: 503')):
            self.assertEqual(INSTALLER.job_state("gui/503/test"), (False, None))

    def test_permission_fixture_waits_for_actual_exit(self):
        spec = importlib.util.spec_from_file_location("permission_check", ROOT / "tests/auth/macos-permission-check.py")
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        self.assertIsNone(checker.exit_code("state = xpcproxy\n\tlast exit code = (never exited)\n"))
        self.assertIsNone(checker.exit_code("state = running\n"))
        for code in (0, 3, 30, -9):
            self.assertEqual(checker.exit_code(f"\tlast exit code = {code}\n"), code)

    def test_upgrade_keeps_requirement_and_team_before_any_mutation(self):
        with tempfile.TemporaryDirectory(prefix="plank-signature-") as temporary:
            source, installed = Path(temporary) / "source", Path(temporary) / "installed"
            source.mkdir()
            installed.mkdir()
            identity = ("ABCDEFGHIJ", 'identifier "la.instinctual.PLANK.Host" and anchor apple generic')
            with patch.object(INSTALLER, "signing_identity", return_value=identity) as check:
                INSTALLER.verify_upgrade_identity(source, installed)
                self.assertEqual([call.args[0] for call in check.call_args_list], [source, installed])
            for changed in (("KLMNOPQRST", identity[1]), (identity[0], "different requirement")):
                with patch.object(INSTALLER, "signing_identity", side_effect=[changed, identity]):
                    with self.assertRaisesRegex(ValueError, "preserving installed app"):
                        INSTALLER.verify_upgrade_identity(source, installed)
            script = (ROOT / "scripts/maintenance/install-macos-host-development.py").read_text()
            self.assertLess(script.index("verify_upgrade_identity(source, installed)", script.index("def main")),
                            script.index('machine_state.mkdir(', script.index("def main")))

    def test_first_install_still_checks_candidate(self):
        with tempfile.TemporaryDirectory(prefix="plank-signature-") as temporary:
            source, absent = Path(temporary) / "source", Path(temporary) / "absent"
            source.mkdir()
            with patch.object(INSTALLER, "signing_identity", return_value=("ABCDEFGHIJ", "requirement")) as check:
                INSTALLER.verify_upgrade_identity(source, absent)
                check.assert_called_once_with(source)

    def test_signature_rejects_symlinks_adhoc_and_missing_requirement(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory(prefix="plank-signature-") as temporary:
            app, link = Path(temporary) / "app", Path(temporary) / "link"
            app.mkdir()
            link.symlink_to(app, target_is_directory=True)
            with self.assertRaises(ValueError):
                INSTALLER.signing_identity(link)
            with patch.object(INSTALLER, "run", return_value=SimpleNamespace(stderr="Signature=adhoc")):
                with self.assertRaises(ValueError):
                    INSTALLER.signing_identity(app)
            signature = "Authority=Apple Development: Test\nTeamIdentifier=ABCDEFGHIJ\n"
            with patch.object(INSTALLER, "run", side_effect=[SimpleNamespace(stderr=""),
                              SimpleNamespace(stderr=signature), SimpleNamespace(stdout="", stderr="")]):
                with self.assertRaisesRegex(ValueError, "designated"):
                    INSTALLER.signing_identity(app)

    def test_requirement_output_streams(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory(prefix="plank-signature-") as temporary:
            app = Path(temporary)
            signature = "Authority=Apple Development: Test\nTeamIdentifier=ABCDEFGHIJ\n"
            requirement = 'identifier "la.instinctual.PLANK.Host" and anchor apple generic'
            line = "designated => " + requirement + "\n"
            for stdout, stderr in ((line, "Executable=/test\n"), ("", line)):
                with patch.object(INSTALLER, "run", side_effect=[SimpleNamespace(stderr=""),
                                  SimpleNamespace(stderr=signature), SimpleNamespace(stdout=stdout, stderr=stderr)]):
                    self.assertEqual(INSTALLER.signing_identity(app), ("ABCDEFGHIJ", requirement))
            with patch.object(INSTALLER, "run", side_effect=[SimpleNamespace(stderr=""),
                              SimpleNamespace(stderr=signature), SimpleNamespace(stdout=line, stderr=line)]):
                with self.assertRaisesRegex(ValueError, "unambiguous"):
                    INSTALLER.signing_identity(app)

    def test_host_icon_is_generated_from_approved_host_artwork(self):
        info = plistlib.loads((ROOT / "packaging/host/macos/host-info.plist").read_bytes())
        self.assertEqual(info["CFBundleIconFile"], "plank.icns")
        build = (ROOT / "scripts/build/build-macos-host.sh").read_text()
        self.assertIn('branding/assets/plank-host-macos.png', build)
        self.assertIn('Contents/Resources/plank.icns', build)
        self.assertLess(build.index('iconutil -c icns'), build.index('--entitlements "$output/camera-host-entitlements.plist"'))

    def test_preserves_private_identity_and_does_not_share_keys(self):
        with tempfile.TemporaryDirectory(prefix="plank-role-identity-") as temporary:
            first, second = Path(temporary) / "first", Path(temporary) / "second"
            INSTALLER.prepare_sign_in_identity(first)
            before = {p.name: p.read_bytes() for p in first.iterdir()}
            INSTALLER.prepare_sign_in_identity(first)
            self.assertEqual(before, {p.name: p.read_bytes() for p in first.iterdir()})
            INSTALLER.prepare_sign_in_identity(second)
            self.assertNotEqual((first / "key.der").read_bytes(), (second / "key.der").read_bytes())
            self.assertEqual(set(before), {"cert.pem", "key.pem", "cert.der", "key.der"})
            self.assertEqual(first.stat().st_mode & 0o777, 0o700)
            for path in first.iterdir():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            INSTALLER.prepare_sign_in_identity(first)
            self.assertEqual(before, {p.name: p.read_bytes() for p in first.iterdir()})

    def test_rejects_partial_identity_without_overwriting_it(self):
        with tempfile.TemporaryDirectory(prefix="plank-role-identity-") as temporary:
            private = Path(temporary) / "partial"
            private.mkdir(mode=0o700)
            (private / "key.pem").write_text("preserve")
            with self.assertRaises(AssertionError):
                INSTALLER.prepare_sign_in_identity(private)
            self.assertEqual((private / "key.pem").read_text(), "preserve")

    def test_rejects_symlink_and_public_directory(self):
        with tempfile.TemporaryDirectory(prefix="plank-role-identity-") as temporary:
            private, link = Path(temporary) / "private", Path(temporary) / "link"
            private.mkdir(mode=0o700)
            link.symlink_to(private, target_is_directory=True)
            with self.assertRaises(AssertionError):
                INSTALLER.prepare_sign_in_identity(link)
            os.chmod(private, 0o755)
            with self.assertRaises(AssertionError):
                INSTALLER.prepare_sign_in_identity(private)
            self.assertFalse(any(private.iterdir()))


if __name__ == "__main__":
    unittest.main()
