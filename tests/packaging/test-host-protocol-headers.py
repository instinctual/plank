#!/usr/bin/env python3
"""Positive/negative regression tests for the Host's header-only dependency."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "host_headers", ROOT / "scripts/test/check-host-protocol-headers.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
SOURCE = ROOT / "apps/host/linux/third-party/moonlight-common-c"


class HostProtocolHeaders(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "protocol"
        (self.root / "src").mkdir(parents=True)
        for name in CHECK.HEADERS:
            shutil.copyfile(SOURCE / "src" / name, self.root / "src" / name)
        for name in ("CMakeLists.txt", "LICENSE.txt"):
            shutil.copyfile(SOURCE / name, self.root / name)

    def test_current_dependency(self):
        CHECK.validate(SOURCE)

    def test_headers_compile_as_c_and_cpp(self):
        for compiler, language, standard in (("cc", "c", "c11"), ("c++", "c++", "c++17")):
            with self.subTest(language=language):
                subprocess.run([compiler, "-x", language, "-std=" + standard,
                                "-Werror", "-fsyntax-only", "-I", str(self.root / "src"), "-"],
                               input='#include "Limelight.h"\n#include "plank.h"\n',
                               text=True, check=True, capture_output=True)

    def test_reject_recursive_dependencies(self):
        for name in ("enet", "nanors", ".gitmodules"):
            with self.subTest(name=name):
                path = self.root / name
                path.touch()
                with self.assertRaises(ValueError):
                    CHECK.validate(self.root)
                path.unlink()

    def test_reject_compiled_source(self):
        (self.root / "transport.c").write_text("void legacy(void) {}\n")
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_reject_extra_header(self):
        (self.root / "src/Video.h").touch()
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_reject_enet_declaration(self):
        with (self.root / "src/Limelight.h").open("a") as stream:
            stream.write("\nint enet_host_service(void);\n")
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_reject_library_build_wiring(self):
        with (self.root / "CMakeLists.txt").open("a") as stream:
            stream.write("\nadd_subdirectory(transport)\n")
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)


if __name__ == "__main__":
    unittest.main()
