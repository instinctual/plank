#!/usr/bin/env python3
"""The wrong-function patch must fail even if its byte hash is approved."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "identity_gate", ROOT / "scripts/test/check-client-ffmpeg-identity.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)

ALIASES = """
    case AV_PIX_FMT_GBRP:
    case AV_PIX_FMT_YUV444P:
        break;
    case AV_PIX_FMT_GBRP10:
    case AV_PIX_FMT_YUV444P10:
        break;
"""


def function(name, body):
    return f"static enum AVPixelFormat {name}(HEVCContext *s) {{ {body} }}"


class IdentityFormatGate(unittest.TestCase):
    def test_format_selection(self):
        GATE.check(function("get_format", "switch (fmt) {" + ALIASES + "}"))

    def test_alpha_only_regression(self):
        source = function("map_to_alpha_format", ALIASES) + function("get_format", "return 0;")
        with self.assertRaises(ValueError):
            GATE.check(source)

    def test_each_precision_required(self):
        for alias in ("case AV_PIX_FMT_GBRP:", "case AV_PIX_FMT_GBRP10:"):
            with self.subTest(alias=alias), self.assertRaises(ValueError):
                GATE.check(function("get_format", ALIASES.replace(alias, "")))

    def test_later_function_does_not_count(self):
        with self.assertRaises(ValueError):
            GATE.check(function("get_format", "return 0;") + function("another", ALIASES))


if __name__ == "__main__":
    unittest.main()
