#!/usr/bin/env python3
"""Portable fixtures for the exact Linux installer helper; no live /etc writes."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("upgrade", ROOT / "packaging/client/linux/update-policy.py")
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)
TEMPLATE = ROOT / "packaging/client/config/plank-client.conf"


class PolicyUpgrade(unittest.TestCase):
    def test_complete_template_is_unchanged(self):
        original = TEMPLATE.read_bytes()
        self.assertEqual(upgrade.add_missing_keys(original, original), original)

    def test_preserves_values_comments_and_unknown_sections(self):
        original = (b"# administrator policy\n[network]\nport=30001\n"
                    b"internet_check_enabled=false\ninternet_check_hosts=192.0.2.1\n"
                    b"\n[authentication]\nremember_username=true\n[private]\ncustom=value\n")
        result = upgrade.add_missing_keys(original, TEMPLATE.read_bytes())
        self.assertEqual(result.count(b"internet_check_enabled="), 1)
        self.assertIn(b"internet_check_hosts=192.0.2.1\n", result)
        self.assertIn(b"port=30001\n", result)
        self.assertTrue(result.endswith(original[original.index(b"[authentication]"):]))
        self.assertIn(b"internet_check_interval_seconds = 15\n", result)
        self.assertIn(b"# Maximum wait", result)
        self.assertEqual(upgrade.add_missing_keys(result, TEMPLATE.read_bytes()), result)

    def test_empty_and_missing_section_and_crlf(self):
        for original in (b"", b"[authentication]\nremember_username=true", b"[network]",
                         b"[network]\r\nport=30001\r\n[private]\r\nkey=value\r\n"):
            with self.subTest(original=original):
                result = upgrade.add_missing_keys(original, TEMPLATE.read_bytes())
                for key in upgrade.KEYS:
                    self.assertEqual(result.count(key.encode() + b" ="), 1)
                self.assertEqual(upgrade.add_missing_keys(result, TEMPLATE.read_bytes()), result)
                if b"\r\n" in original:
                    self.assertTrue(result.endswith(b"port=30001\r\n[private]\r\nkey=value\r\n"))

    def test_repeated_sections_and_unrelated_keys(self):
        original = b"[network]\nport=30001\n[private]\ninternet_check_enabled=maybe\n[network]\ninternet_check_enabled=false\n"
        result = upgrade.add_missing_keys(original, TEMPLATE.read_bytes())
        self.assertNotIn(b"internet_check_enabled = true", result)
        self.assertIn(b"[private]\ninternet_check_enabled=maybe\n", result)

    def test_rejects_bad_template_and_encoding(self):
        for original, template in ((b"", b"[network]\n"), (b"\xff", TEMPLATE.read_bytes()),
                                   (b"#" + b"a" * 32768, TEMPLATE.read_bytes())):
            with self.assertRaises(ValueError):
                upgrade.add_missing_keys(original, template)

    def test_atomic_update_and_safe_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            policy = directory / "client.conf"
            policy.write_bytes(b"[network]\nport=30001\n")
            policy.chmod(0o644)
            upgrade.update(str(directory), str(TEMPLATE))
            updated = policy.read_bytes()
            self.assertIn(b"port=30001\n", updated)
            self.assertEqual(policy.stat().st_mode & 0o777, 0o644)
            self.assertEqual(policy.stat().st_uid, os.geteuid())
            inode = policy.stat().st_ino
            upgrade.update(str(directory), str(TEMPLATE))
            self.assertEqual(policy.stat().st_ino, inode)
            self.assertEqual(policy.read_bytes(), updated)
            self.assertEqual(list(directory.iterdir()), [policy])
            policy.chmod(0o666)
            with self.assertRaises(ValueError):
                upgrade.update(str(directory), str(TEMPLATE))
            policy.chmod(0o644)
            outside = directory / "outside"
            policy.rename(outside)
            policy.symlink_to(outside)
            with self.assertRaises(OSError):
                upgrade.update(str(directory), str(TEMPLATE))
            self.assertEqual(outside.read_bytes(), updated)
            policy.unlink()
            os.link(outside, policy)
            with self.assertRaises(ValueError):
                upgrade.update(str(directory), str(TEMPLATE))
            self.assertEqual(outside.read_bytes(), updated)


if __name__ == "__main__":
    unittest.main()
