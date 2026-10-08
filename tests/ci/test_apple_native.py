"""Native hosted CI, provenance and credential boundary regressions; no Apple access."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native = load("native_ci", ROOT / "scripts/ci/apple-native.py")
delivery = load("native_delivery", ROOT / "scripts/ci/apple-native-testflight.py")


class NativePolicyTests(unittest.TestCase):
    def test_only_hosted_mac_builders_and_protected_signing(self):
        workflow = (ROOT / ".github/workflows/apple-native.yml").read_text()
        self.assertNotIn("self-hosted", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertIn("platform: [macos, device, simulator]", workflow)
        self.assertIn("environment: vision-testflight", workflow)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.testflight", workflow)
        self.assertIn("needs: build", workflow)
        public, signing = workflow.split("  testflight:\n", 1)
        self.assertNotIn("secrets.", public)
        self.assertIn("if: always()", signing)
        self.assertNotIn("gh release", workflow)
        for action in re.findall(r"uses: ([^\s]+)", workflow):
            self.assertRegex(action, r"^actions/[^@]+@[0-9a-f]{40}$")

    def test_download_cache_never_contains_products_or_credentials(self):
        text = (ROOT / ".github/workflows/apple-native.yml").read_text()
        self.assertIn("github.event_name != 'pull_request'", text)
        self.assertNotIn("restore-keys:", text)
        self.assertNotIn("/cargo/target", text)
        self.assertNotIn("path: ${{ runner.temp }}/", text.split("  testflight:\n")[0])

    def test_branch_label_and_build_identity(self):
        self.assertEqual(native.branch_name("codex/Vision-UI"), "codex-vision-ui")
        self.assertEqual(native.build_number("12.2"), "12.2")
        for bad in ("0.1", "10000.1", "12.100", "12;x", "\n12.2", "12.2\n"):
            with self.assertRaises(RuntimeError):
                native.build_number(bad)

    def test_signer_rejects_pr_local_and_wrong_repo(self):
        with tempfile.TemporaryDirectory() as temp:
            env = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                   "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REPOSITORY": "instinctual/plank",
                   "GITHUB_REF": "refs/heads/native-builds", "RUNNER_TEMP": temp}
            with patch.object(delivery.sys, "platform", "darwin"), patch.dict(os.environ, env, clear=True):
                self.assertEqual(delivery.runner_directory().parent, Path(temp))
                for key, bad in (("GITHUB_EVENT_NAME", "pull_request"), ("RUNNER_ENVIRONMENT", "self-hosted"),
                                 ("GITHUB_REPOSITORY", "fork/plank"), ("GITHUB_REF", "refs/heads/main")):
                    with patch.dict(os.environ, {key: bad}), self.assertRaises(delivery.DeliveryError):
                        delivery.runner_directory()

    def test_cleanup_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "keep").mkdir()
            (root / "credentials").symlink_to(root / "keep", target_is_directory=True)
            with self.assertRaises(delivery.DeliveryError):
                delivery.cleanup(root / "credentials")
            self.assertTrue((root / "keep").is_dir())

    def test_es256_der_conversion_and_rejection(self):
        value = b"\x80" + b"\x11" * 31
        encoded = b"\x30\x46\x02\x21\x00" + value + b"\x02\x21\x00" + value
        self.assertEqual(delivery.raw_signature(encoded), value * 2)
        for bad in (b"", encoded[:-1], encoded + b"x", b"\x30\x06\x02\x01\xff\x02\x01\x01"):
            with self.assertRaises(delivery.DeliveryError):
                delivery.raw_signature(bad)

    def test_wrong_archive_rejected_before_apple_calls(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "PlankVision.xcarchive.tar.gz"
            archive.write_bytes(b"fixture")
            with self.assertRaises(delivery.DeliveryError):
                delivery.verify_receipt({"signed": True}, archive, "a" * 40, "example.app", "0.1.0", "1.1")

    def test_archive_requires_matching_generated_crash_symbols(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "Vision.xcarchive"
            archive.mkdir()
            generated = root / "PLANK.app.dSYM"
            generated.mkdir()
            uuid = "UUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE (arm64) fixture"
            with patch.object(native, "output", return_value=uuid):
                native.collect_symbols(archive, generated)
            self.assertTrue((archive / "dSYMs/PLANK.app.dSYM").is_dir())
            with patch.object(native, "output", side_effect=[uuid, uuid.replace("AAAAAAAA", "FFFFFFFF")]):
                with self.assertRaisesRegex(RuntimeError, "UUID mismatch"):
                    native.collect_symbols(archive, generated)
            with patch.object(native, "output", return_value=""):
                with self.assertRaisesRegex(RuntimeError, "UUID mismatch"):
                    native.collect_symbols(archive, generated)

    def test_no_automatic_export_compliance_claim(self):
        text = (ROOT / "scripts/ci/apple-native-testflight.py").read_text()
        self.assertNotIn('"usesNonExemptEncryption": False', text)
        self.assertNotIn('"ITSAppUsesNonExemptEncryption": False', text)
        self.assertIn('"testFlightInternalTestingOnly": True', text)
        self.assertIn('"isInternalGroup") is True', text)

    def test_apple_failures_do_not_publish_account_metadata(self):
        raw = 'error: exportArchive No signing certificate "EXAMPLE PRIVATE ACCOUNT" found. Code=42'
        summary = delivery.failure_summary(raw)
        self.assertIn('missing-signing-certificate', summary)
        self.assertIn('42', summary)
        self.assertNotIn('EXAMPLE', summary)
        self.assertEqual(delivery.failure_summary('EXAMPLE PRIVATE ACCOUNT'),
                         'Apple codes unavailable; categories unclassified')

    def test_assignment_is_not_claimed_as_installability(self):
        from unittest.mock import Mock
        store = Mock()
        store.request.return_value = {'data': {'attributes': {'internalBuildState': 'IN_BETA_TESTING'}}}
        self.assertEqual(delivery.poll_internal_testing(store, 'fixture', float('inf')), 'IN_BETA_TESTING')
        for state in ('MISSING_EXPORT_COMPLIANCE', 'PROCESSING_EXCEPTION', 'EXPIRED', None):
            store.request.return_value = {'data': {'attributes': {'internalBuildState': state}}}
            with self.assertRaises(delivery.DeliveryError):
                delivery.poll_internal_testing(store, 'fixture', float('inf'))
        with self.assertRaises(delivery.DeliveryError):
            delivery.poll_internal_testing(store, 'fixture', 0)

    def test_signing_binds_drawing_receipts_to_distributing_account(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "Vision.xcarchive"
            app = archive / "Products/Applications/PLANK.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"PLANKRegistrationAccessGroup": "unexpanded"}))
            with patch.object(delivery, "command") as command:
                delivery.stage_signing_entitlements(archive, root, "org.example.vision", "TEAM123456", "PREF123456")
                self.assertIn("--generate-entitlement-der", command.call_args.args[1])
            entitlements = plistlib.loads((root / "distribution-entitlements.plist").read_bytes())
            self.assertEqual(entitlements["application-identifier"], "PREF123456.org.example.vision")
            self.assertEqual(entitlements["com.apple.developer.team-identifier"], "TEAM123456")
            group = plistlib.loads((app / "Info.plist").read_bytes())["PLANKRegistrationAccessGroup"]
            self.assertIn(group, entitlements["keychain-access-groups"])
            self.assertFalse(entitlements["get-task-allow"])


if __name__ == "__main__":
    unittest.main()
