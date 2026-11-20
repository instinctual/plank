"""Pinned driver packaging checks without network access or system changes."""
import hashlib
import importlib.util
import lzma
import re
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("tangent_package", ROOT / "scripts/package/stage-tangent-usbip.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class ActiveSeatTests(unittest.TestCase):
    def test_only_the_four_element_ids_receive_usb_access_and_retrigger(self):
        linux = ROOT / "packaging/client/linux"
        rules = [l for l in (linux / "udev/70-plank-client-tangent.rules").read_text().splitlines()
                 if l and not l.startswith("#")]
        self.assertEqual(len(rules), 1)
        match = re.fullmatch(r'SUBSYSTEM=="usb", ENV\{DEVTYPE\}=="usb_device", ATTR\{idVendor\}=="04d8", '
                             r'ATTR\{idProduct\}=="([a-f0-9|]+)", TAG\+="uaccess"', rules[0])
        self.assertIsNotNone(match)
        products = {"fa1a", "fa1c", "fa1e", "fa1f"}
        self.assertEqual(set(match.group(1).split("|")), products)
        for hook in ("postinst", "postrm"):
            script = (linux / "deb" / hook).read_text()
            loop = re.search(r'for product in ([a-f0-9 ]+); do', script)
            self.assertIsNotNone(loop)
            self.assertEqual(set(loop.group(1).split()), products)
            self.assertIn('--attr-match=idVendor=04d8 --attr-match=idProduct="$product"', script)


class DriverPackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.payload = self.root / "payload"
        self.module = b"module fixture\x00~Module signature appended~\n"
        self.source = b"complete corresponding source fixture"
        self.pin = {"kernel_abi": "fixture-kernel", "module": {
            "member": "./exact-module.ko", "sha256": hashlib.sha256(self.module).hexdigest()}}
        for name, contents in (("binary", b"binary fixture"), ("source", self.source)):
            self.pin[name] = {"name": name + ".rpm", "sha256": hashlib.sha256(contents).hexdigest(),
                              "url": "https://invalid.example/never-fetched"}
            (self.cache / (name + ".rpm")).write_bytes(contents)

    def stage(self):
        with patch.object(PACKAGE, "member", side_effect=lambda archive, name:
                          self.module if name == "./exact-module.ko" else b"GPL license fixture"), \
                patch.object(PACKAGE.urllib.request, "urlopen", side_effect=AssertionError("network request")):
            return PACKAGE.stage(self.payload, self.cache, self.pin)

    def test_payload_preserves_signed_bytes_and_complete_source_offline(self):
        module = self.stage()
        self.assertEqual(module.suffixes, [".ko", ".xz"])
        self.assertEqual(lzma.decompress(module.read_bytes()), self.module)
        self.assertEqual((self.payload / "usr/share/doc/plank-host/usbip/corresponding-source.src.rpm").read_bytes(), self.source)
        PACKAGE.verify_payload(self.payload, self.pin)

    def test_final_payload_verification_detects_signature_damage(self):
        module = self.stage()
        module.write_bytes(lzma.compress(self.module[:-1]))
        with self.assertRaises(ValueError):
            PACKAGE.verify_payload(self.payload, self.pin)

    def test_changed_cached_input_is_not_replaced_or_downloaded(self):
        (self.cache / "binary.rpm").write_bytes(b"wrong input")
        with self.assertRaises(ValueError):
            self.stage()
        self.assertEqual((self.cache / "binary.rpm").read_bytes(), b"wrong input")
        self.assertFalse(self.payload.exists())

    def test_never_stages_into_running_system(self):
        with self.assertRaises(ValueError):
            PACKAGE.stage(Path("/"), self.cache, self.pin)


if __name__ == "__main__":
    unittest.main()
