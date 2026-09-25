#!/usr/bin/env python3
"""Build-privacy regression tests; use synthetic paths and non-product binaries."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


sanitize = module('sanitize', 'scripts/build/sanitize-ffmpeg-build-info.py').sanitize
check = module('check', 'scripts/test/check-package-build-paths.py').check


class BuildPaths(unittest.TestCase):
    def test_generated_configuration_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.h'
            other = '#define OTHER "/Users/build-operator/private/data"\n'
            path.write_text(other + '#define FFMPEG_CONFIGURATION "--prefix=/Users/build-operator/private/install --enable-vaapi"\n')
            sanitize(path, ['/Users/build-operator/private'])
            self.assertEqual(path.read_text(), other + '#define FFMPEG_CONFIGURATION "--prefix=/build/dependencies/install --enable-vaapi"\n')
            sanitize(path, ['/Users/build-operator/private'])  # Idempotent.

    def test_config_shape_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.h'
            for text in ('', '#define FFMPEG_CONFIGURATION "x"\n' * 2):
                path.write_text(text)
                with self.assertRaises(ValueError):
                    sanitize(path, ['/private/build'])

    def test_payload_paths_and_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'binary'
            for value in (b'\0/home/build-operator/source\0', b'\0/Users/build-operator/source\0'):
                path.write_bytes(value)
                self.assertEqual(check(Path(tmp)), 1)
            path.write_bytes(b'\0/build/plank/source\0/usr/lib/libc.so\0')
            (Path(tmp) / 'Applications').symlink_to('/Applications')
            self.assertEqual(check(Path(tmp)), 0)

    def test_c_file_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'source.c'
            source.write_text('#include <stdio.h>\nint main(void) { puts(__FILE__); }\n')
            script = '''set -eu
source "$1/scripts/build/build-paths.sh"
plank_build_path_flags "$2" "$2/output"
cc "${PLANK_FILE_FLAGS[@]}" "$2/source.c" -o "$2/test"
"$2/test"
'''
            result = subprocess.run(['bash', '-c', script, 'test', str(ROOT), tmp],
                                    text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.strip(), '/build/plank/source/source.c')

    def test_vendor_exception_is_exact_and_framework_scoped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / 'app/Contents/Frameworks/QtQuick.framework/Versions/A/QtQuick'
            path.parent.mkdir(parents=True)
            vendor = b'/Users/qt/work/qt/qtdeclarative/src/quick/designer/qquickdesignersupport.cpp'
            path.write_bytes(vendor + b'\0')
            self.assertEqual(check(root), 0)
            path.write_bytes(vendor + b'/private\0')
            self.assertEqual(check(root), 1)
            path.write_bytes(vendor.replace(b'/Users/qt/', b'/Users/build-operator/') + b'\0')
            self.assertEqual(check(root), 1)
            path.unlink()
            (root / 'unrelated').write_bytes(vendor + b'\0')
            self.assertEqual(check(root), 1)

    def test_rust_flags_preserved(self):
        script = '''set -eu
source "$1/scripts/build/build-paths.sh"
RUSTFLAGS='-C strip=none'
plank_build_path_flags /source /output
[[ $RUSTFLAGS == '-C strip=none '* ]]
[[ $RUSTFLAGS == *'--remap-path-prefix=/source=/build/plank/source'* ]]
'''
        subprocess.run(['bash', '-c', script, 'test', str(ROOT)], check=True)

    def test_encoded_flags_rejected(self):
        script = '''source "$1/scripts/build/build-paths.sh"
CARGO_ENCODED_RUSTFLAGS=override
plank_build_path_flags /source /output
'''
        result = subprocess.run(['bash', '-c', script, 'test', str(ROOT)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_qmake_flags_do_not_leak_into_cargo(self):
        with tempfile.TemporaryDirectory() as tmp:
            makefile = Path(tmp) / 'Makefile'
            makefile.write_text('CFLAGS = -include c-only-header.h\nall:\n\t@test -z "$$CFLAGS"\n\t@test -n "$$HOST_CFLAGS"\n')
            script = '''set -eu
unset CFLAGS CXXFLAGS
source "$1/scripts/build/build-paths.sh"
plank_build_path_flags /source /output
plank_native_dependency_flags
make -s -f "$2"
'''
            subprocess.run(['bash', '-c', script, 'test', str(ROOT), str(makefile)], check=True)

    def test_all_package_entrypoints_enforce_gate(self):
        for name in ('host-rpm', 'client-deb', 'macos-host-pkg', 'macos-client-dmg'):
            self.assertIn('check-package-build-paths.py',
                          (ROOT / 'scripts/package' / ('build-' + name + '.sh')).read_text())

    def test_client_uninstaller_passes_payload_gate(self):
        # Directory Services uses a /Users record path, not a build-machine
        # home. Keep the shipped shell script unambiguous without exemptions.
        self.assertEqual(check(ROOT / 'packaging/client/macos/uninstall.sh'), 0)


if __name__ == '__main__':
    unittest.main()
