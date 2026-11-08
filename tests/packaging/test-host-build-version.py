#!/usr/bin/env python3
"""Compile the real Host version policy and keep unrelated cache inputs stable."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'apps/host/linux/cmake/prep/build_version.cmake'


class HostBuildVersion(unittest.TestCase):
    def test_runtime_identity_changes_without_invalidating_unrelated_compiler_inputs(self):
        with tempfile.TemporaryDirectory(prefix='plank-version-') as temporary:
            root = Path(temporary)
            source = root / 'source'
            (source / 'src').mkdir(parents=True)
            build = root / 'build'
            (source / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.20)
project(VersionFixture VERSION 1.4.13 LANGUAGES CXX)
set(PROJECT_FQDN example.org)
include("''' + str(MODULE) + '''")
add_executable(version src/main.cpp src/nvhttp.cpp src/video.cpp)
target_compile_definitions(version PRIVATE ${SUNSHINE_DEFINITIONS})
''')
            (source / 'src/main.cpp').write_text('''#include <iostream>
const char* server_version(); int frame_value();
int main() { std::cout << PROJECT_VERSION << ' ' << PROJECT_VERSION_COMMIT
    << ' ' << server_version() << ' ' << frame_value() << '\\n'; }
''')
            (source / 'src/nvhttp.cpp').write_text('''#ifdef PROJECT_VERSION_COMMIT
#error HTTP does not consume the commit ID
#endif
const char* server_version() { return PROJECT_VERSION; }
''')
            (source / 'src/video.cpp').write_text('''#if defined(PROJECT_VERSION) || defined(PROJECT_VERSION_COMMIT) || defined(PROJECT_VERSION_MAJOR)
#error Package identity must not invalidate video object compilation
#endif
int frame_value() { return 42; }
''')
            previous = None
            for version, commit in (('1.4.13-native10-buffer-reuse', 'a' * 40), ('1.4.14-host-build-iteration', 'b' * 40)):
                env = dict(os.environ, BRANCH='plank-package', BUILD_VERSION=version, COMMIT=commit)
                subprocess.run(['cmake', '-S', str(source), '-B', str(build),
                                '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON'], env=env, check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                subprocess.run(['cmake', '--build', str(build), '--parallel', '2'], env=env,
                               check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertEqual(subprocess.check_output([str(build / 'version')], text=True).strip(),
                                 f'{version} {commit} {version} 42')
                objects = list(build.rglob('video.cpp.o'))
                self.assertEqual(len(objects), 1)
                commands = json.loads((build / 'compile_commands.json').read_text())
                video = next(c for c in commands if c['file'].endswith('/video.cpp'))
                current = (video['command'], objects[0].read_bytes())
                if previous is not None:
                    self.assertEqual(current, previous)
                previous = current
                self.assertNotIn('PROJECT_VERSION', video['command'])


if __name__ == '__main__':
    unittest.main()
