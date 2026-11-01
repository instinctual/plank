#!/usr/bin/env python3
"""Bootstrap path/metadata contracts; mocks compilation, not a build qualification."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = Path('apps/client/app/deploy/linux/ffmpeg-patches/0001-hevc-enable-hwaccel-for-identity-gbr.patch')


class BootstrapInputs(unittest.TestCase):
    def run_bootstrap(self, with_patch):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            script = base / 'source/scripts/build/build-client-ffmpeg.sh'
            script.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'scripts/build/build-client-ffmpeg.sh', script)
            for helper in ('build-paths.sh', 'sanitize-ffmpeg-build-info.py'):
                shutil.copyfile(ROOT / 'scripts/build' / helper, script.parent / helper)
            if with_patch:
                destination = base / 'source' / PATCH
                destination.parent.mkdir(parents=True)
                shutil.copyfile(ROOT / PATCH, destination)
            work = base / 'deps'
            source = work / 'ffmpeg-9.0.2'
            source.mkdir(parents=True)
            (work / 'ffmpeg-9.0.2.tar.xz').touch()
            configure = source / 'configure'
            configure.write_text('#!/bin/sh\nexit 37\n')
            configure.chmod(0o755)
            commands = base / 'bin'
            commands.mkdir()
            # No dependency downloads or compiler calls in this contract test.
            # Only the fake archive bypasses its hash; the real patch is hashed.
            for name, content in {
                'curl': '#!/bin/sh\nexit 99\n',
                'nasm': '#!/bin/sh\nexit 99\n',
                'pkg-config': '#!/bin/sh\nexit 99\n',
                # The Linux command syntax is part of the fixture; macOS's
                # system realpath does not implement GNU -m.
                'realpath': '#!/usr/bin/env python3\nfrom pathlib import Path\nimport sys\n'
                    'assert sys.argv[1:3] == ["-m", "--"] and len(sys.argv) == 4\n'
                    'print(Path(sys.argv[3]).resolve())\n',
                'patch': '#!/bin/sh\ncat >/dev/null\nexit 0\n',
                'sha256sum': '#!/usr/bin/env python3\nimport hashlib,pathlib,sys\ns=sys.stdin.read()\n'
                    'if "ffmpeg-9.0.2.tar.xz" not in s:\n'
                    ' expected, name = s.strip().split(maxsplit=1)\n'
                    ' actual = hashlib.sha256(pathlib.Path(name.lstrip(" *")).read_bytes()).hexdigest()\n'
                    ' sys.exit(0 if actual == expected else 1)\n',
            }.items():
                program = commands / name
                program.write_text(content)
                program.chmod(0o755)
            environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['bash', str(script), str(base / 'empty-stage'), str(work)],
                                    env=environment, text=True, capture_output=True)
            self.assertFalse((base / 'empty-stage').exists())
            return result

    def test_empty_runtime_stage_uses_tracked_patch(self):
        result = self.run_bootstrap(True)
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertIn('client_ffmpeg_identity_gbr_patch_gate=pass', result.stdout)

    def test_missing_tracked_patch_stops_bootstrap(self):
        result = self.run_bootstrap(False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Required identity-GBR FFmpeg patch is unavailable', result.stderr)

    def test_root_audit_uses_declared_submodule_sections(self):
        script = (ROOT / 'scripts/maintenance/verify-upstream-pins.sh').read_text()
        sections = re.findall(r'check_submodule_url "\$repo_root" (\S+) (\S+)', script)
        self.assertEqual(len(sections), 2)
        for section, expected in sections:
            actual = subprocess.check_output(['git', 'config', '-f', str(ROOT / '.gitmodules'),
                                              f'submodule.{section}.url'], text=True).strip()
            self.assertEqual(actual, expected)


if __name__ == '__main__':
    unittest.main()
