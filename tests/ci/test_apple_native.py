"""Native hosted CI, provenance and credential boundary regressions; no Apple access."""
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
import unittest
from unittest.mock import Mock, patch

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

    def test_export_policy_is_protected_and_not_a_fork_default(self):
        text = (ROOT / "scripts/ci/apple-native-testflight.py").read_text()
        self.assertNotIn('"ITSAppUsesNonExemptEncryption": False', text)
        self.assertIn('os.environ.get("PLANK_VISION_EXPORT_POLICY", "")', text)
        self.assertIn('"testFlightInternalTestingOnly": True', text)
        self.assertIn('"isInternalGroup") is True', text)
        workflow = (ROOT / ".github/workflows/apple-native.yml").read_text()
        public, signing = workflow.split("  testflight:\n", 1)
        self.assertNotIn("PLANK_VISION_EXPORT_POLICY", public)
        self.assertIn("PLANK_VISION_EXPORT_POLICY: ${{ vars.PLANK_VISION_EXPORT_POLICY }}", signing)

    def compliance_build(self, value=None, **attrs):
        return {"id": "build-fixture", "attributes": {
            "processingState": "VALID", "expired": False,
            "usesNonExemptEncryption": value, **attrs}}

    def test_unconfirmed_or_unknown_compliance_policy_never_writes(self):
        store = Mock()
        for policy in ("", "unconfirmed", "false", "standard-no-france\n"):
            with self.assertRaises(delivery.DeliveryError):
                delivery.ensure_export_compliance(store, self.compliance_build(), policy)
        store.request.assert_not_called()
        for value in (False, True):
            item = self.compliance_build(value)
            self.assertIs(delivery.ensure_export_compliance(store, item, ""), item)
        store.request.assert_not_called()

    def test_confirmed_compliance_updates_only_selected_build_then_reads_back(self):
        store = Mock()
        verified = self.compliance_build(False)
        store.request.side_effect = [{}, {"data": verified}]
        self.assertEqual(delivery.ensure_export_compliance(store, self.compliance_build(),
                                                          "standard-no-france"), verified)
        first, second = store.request.call_args_list
        self.assertEqual(first.args, ("/builds/build-fixture", {"data": {
            "type": "builds", "id": "build-fixture", "attributes": {"usesNonExemptEncryption": False}}}))
        self.assertEqual(first.kwargs, {"method": "PATCH"})
        self.assertEqual(second.args, ("/builds/build-fixture",))
        self.assertFalse(second.kwargs)

    def test_confirmed_compliance_is_idempotent(self):
        store = Mock()
        item = self.compliance_build(False)
        store.request.return_value = {"data": item}
        for _ in range(2):
            self.assertEqual(delivery.ensure_export_compliance(store, item, "standard-no-france"), item)
        for call in store.request.call_args_list:
            self.assertEqual(call.args, ("/builds/build-fixture",))
            self.assertFalse(call.kwargs)

    def test_conflicting_expired_or_unprocessed_compliance_never_writes(self):
        store = Mock()
        for item in (self.compliance_build(True), self.compliance_build("false"), self.compliance_build(0),
                     self.compliance_build(expired=True), self.compliance_build(processingState="PROCESSING")):
            with self.assertRaises(delivery.DeliveryError):
                delivery.ensure_export_compliance(store, item, "standard-no-france")
        store.request.assert_not_called()

    def test_compliance_readback_rejects_unsaved_or_wrong_build(self):
        for saved in (self.compliance_build(), self.compliance_build(True), self.compliance_build(0),
                      self.compliance_build(False, expired=True),
                      self.compliance_build(False, processingState="FAILED"),
                      {**self.compliance_build(False), "id": "another-build"}):
            store = Mock()
            store.request.side_effect = [{}, {"data": saved}]
            with self.assertRaises(delivery.DeliveryError):
                delivery.ensure_export_compliance(store, self.compliance_build(), "standard-no-france")

    def test_store_uses_explicit_patch_and_refuses_credential_redirects(self):
        store = delivery.Store(Path("unused-fixture"), "test-key", "test-issuer")
        with patch.object(store, "token", return_value="fixture-token"), \
                patch.object(store.http, "open", return_value=io.BytesIO(b"{}")) as opened:
            store.request("/builds/build-fixture", {"data": {}}, method="PATCH")
            request = opened.call_args.args[0]
            self.assertEqual(request.get_method(), "PATCH")
            self.assertEqual(json.loads(request.data), {"data": {}})
            self.assertEqual(opened.call_args.kwargs, {"timeout": 30})
        with self.assertRaises(delivery.DeliveryError):
            delivery.NoRedirect().redirect_request(None, None, 302, None, None, "https://example.com/")
        with patch.object(store, "token") as token:
            for method, body in (("GET", {}), ("PATCH", None), ("DELETE", None)):
                with self.assertRaises(delivery.DeliveryError):
                    store.request("/builds/build-fixture", body, method=method)
            token.assert_not_called()

    def test_store_connection_errors_do_not_expose_account_metadata(self):
        store = delivery.Store(Path("unused-fixture"), "test-key", "test-issuer")
        with patch.object(store, "token", return_value="fixture-token"), \
                patch.object(store.http, "open", side_effect=delivery.urllib.error.URLError("EXAMPLE PRIVATE ACCOUNT")):
            with self.assertRaises(delivery.DeliveryError) as error:
                store.request("/builds/build-fixture")
            self.assertNotIn("EXAMPLE", str(error.exception))

    def test_apple_failures_do_not_publish_account_metadata(self):
        raw = 'error: exportArchive No signing certificate "EXAMPLE PRIVATE ACCOUNT" found. Code=42'
        summary = delivery.failure_summary(raw)
        self.assertIn('missing-signing-certificate', summary)
        self.assertIn('42', summary)
        self.assertNotIn('EXAMPLE', summary)
        self.assertEqual(delivery.failure_summary('EXAMPLE PRIVATE ACCOUNT'),
                         'Apple codes unavailable; categories unclassified')

    def test_assignment_is_not_claimed_as_installability(self):
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
