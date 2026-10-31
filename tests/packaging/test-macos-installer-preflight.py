#!/usr/bin/env python3
"""Evaluate the actual Installer requirements script without changing FileVault."""
import argparse
import ctypes
import ctypes.util
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
DISTRIBUTION = ROOT / "packaging/host/macos/distribution.xml.in"


class JavaScript:
    """Use Apple's JavaScriptCore API; Linux can use the GTK build of that API."""
    def __init__(self):
        if platform.system() == "Darwin":
            library = "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"
        else:
            library = next((ctypes.util.find_library(name) for name in
                            ("javascriptcoregtk-4.1", "javascriptcoregtk-4.0")
                            if ctypes.util.find_library(name)), None)
            if not library:
                raise unittest.SkipTest("JavaScriptCore is required; mandatory on the Mac builder")
        self.lib = ctypes.CDLL(library)
        pointer = ctypes.c_void_p
        signatures = {
            "JSGlobalContextCreate": (pointer, [pointer]),
            "JSGlobalContextRelease": (None, [pointer]),
            "JSStringCreateWithUTF8CString": (pointer, [ctypes.c_char_p]),
            "JSStringRelease": (None, [pointer]),
            "JSEvaluateScript": (pointer, [pointer, pointer, pointer, pointer,
                                           ctypes.c_int, ctypes.POINTER(pointer)]),
            "JSValueToStringCopy": (pointer, [pointer, pointer, ctypes.POINTER(pointer)]),
            "JSStringGetMaximumUTF8CStringSize": (ctypes.c_size_t, [pointer]),
            "JSStringGetUTF8CString": (ctypes.c_size_t, [pointer, pointer, ctypes.c_size_t]),
        }
        for name, (result, arguments) in signatures.items():
            function = getattr(self.lib, name)
            function.restype = result
            function.argtypes = arguments

    def evaluate(self, source):
        context = self.lib.JSGlobalContextCreate(None)
        script = self.lib.JSStringCreateWithUTF8CString(source.encode())
        exception = ctypes.c_void_p()
        string = None
        try:
            result = self.lib.JSEvaluateScript(context, script, None, None, 1,
                                               ctypes.byref(exception))
            string = self.lib.JSValueToStringCopy(context, exception.value or result, None)
            size = self.lib.JSStringGetMaximumUTF8CStringSize(string)
            buffer = ctypes.create_string_buffer(size)
            self.lib.JSStringGetUTF8CString(string, buffer, size)
            text = buffer.value.decode()
            if exception.value:
                raise AssertionError("Installer JavaScript threw: " + text)
            return json.loads(text)
        finally:
            if string:
                self.lib.JSStringRelease(string)
            self.lib.JSStringRelease(script)
            self.lib.JSGlobalContextRelease(context)


class FileVaultPreflight(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.engine = JavaScript()
        cls.distribution = ET.parse(DISTRIBUTION).getroot()
        cls.script = cls.distribution.find("script").text
        cls.expression = cls.distribution.find("installation-check").attrib["script"]

    def check(self, result):
        source = """
            var calls = [];
            var my = {result: {}};
            var system = {run: function(program, argument) {
                calls.push([program, argument]);
                %s
            }};
            %s
            var allowed = (%s);
            JSON.stringify({allowed: allowed, result: my.result, calls: calls});
        """ % (result, self.script, self.expression)
        outcome = self.engine.evaluate(source)
        self.assertEqual(outcome["calls"], [["/usr/bin/fdesetup", "isactive"]])
        return outcome

    def test_requirements_check_is_enabled(self):
        options = self.distribution.find("options").attrib
        self.assertEqual(options["require-scripts"], "true")
        self.assertEqual(options["allow-external-scripts"], "true")
        self.assertEqual(options["hostArchitectures"], "arm64")
        self.assertEqual(self.distribution.find("domains").attrib["enable_anywhere"], "false")

    def test_filevault_off_proceeds_without_warning(self):
        outcome = self.check("return 1;")
        self.assertTrue(outcome["allowed"])
        self.assertEqual(outcome["result"], {})

    def test_filevault_on_or_busy_explains_how_to_continue(self):
        for status in (0, 2):
            with self.subTest(status=status):
                outcome = self.check("return %d;" % status)
                self.assertFalse(outcome["allowed"])
                self.assertEqual(outcome["result"]["type"], "Fatal")
                self.assertIn("FileVault", outcome["result"]["title"])
                self.assertIn("System Settings > Privacy & Security > FileVault",
                              outcome["result"]["message"])
                self.assertIn("reopen this installer", outcome["result"]["message"])

    def test_failed_or_declined_check_never_allows_installation(self):
        for result in ("return undefined;", "return null;", "return true;",
                       "return '1';", "return 127;", "return -1;",
                       "throw new Error('check unavailable');"):
            with self.subTest(result=result):
                outcome = self.check(result)
                self.assertFalse(outcome["allowed"])
                self.assertEqual(outcome["result"]["type"], "Fatal")
                self.assertEqual(outcome["result"]["title"], "Unable to check FileVault")
                self.assertIn("allow Installer to check", outcome["result"]["message"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--package", type=Path)
    options, remaining = parser.parse_known_args()
    with tempfile.TemporaryDirectory(prefix="plank-installer-preflight-") as scratch:
        if options.package:
            expanded = Path(scratch) / "expanded"
            subprocess.run(["/usr/sbin/pkgutil", "--expand", str(options.package),
                            str(expanded)], check=True)
            DISTRIBUTION = expanded / "Distribution"
        result = unittest.main(argv=[sys.argv[0], *remaining], exit=False).result
        sys.exit(0 if result.wasSuccessful() else 1)
