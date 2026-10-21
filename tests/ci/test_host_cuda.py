"""Reject a stale compiler or mixed CUDA packages before an expensive build."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / 'scripts/build/host-cuda.sh'


class HostCudaTests(unittest.TestCase):
    def verify(self, version='13.2.86', release='13.2', bad_package='', missing=False):
        with tempfile.TemporaryDirectory() as directory:
            compiler = Path(directory) / 'nvcc'
            compiler.write_text('#!/bin/sh\nprintf "%s\\n" "$CUDA_TEST_BANNER"\n')
            compiler.chmod(0o700)
            script = r'''
set -euo pipefail
source "$1"
rpm() {
  local package
  for package in "${PLANK_HOST_CUDA_PACKAGES[@]}"; do
    if [[ ${package%-*-*} == "${@: -1}" ]]; then
      if [[ ${@: -1} == "$CUDA_TEST_BAD_PACKAGE" ]]; then
        [[ $CUDA_TEST_MISSING != true ]] || return 1
        printf '%s-13.2.78-1' "${package%-*-*}"
        return 0
      fi
      printf '%s' "$package"
      return 0
    fi
  done
  return 1
}
plank_verify_host_cuda "$2"
'''
            return subprocess.run(
                ['bash', '-c', script, 'cuda-test', str(POLICY), str(compiler)],
                env=dict(os.environ, CUDA_TEST_BANNER=(
                    f'Cuda compilation tools, release {release}, V{version}'),
                    CUDA_TEST_BAD_PACKAGE=bad_package,
                    CUDA_TEST_MISSING=str(missing).lower()),
                capture_output=True, text=True)

    def test_update_two_passes(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('host_cuda_toolchain_gate=pass', result.stdout)

    def test_older_newer_and_malformed_compilers_fail(self):
        for release, version in [('13.0', '13.0.88'), ('13.2', '13.2.51'),
                                 ('13.2', '13.2.78'), ('13.2', '13.2.99'),
                                 ('13.3', '13.2.86'), ('13.2', 'unavailable')]:
            with self.subTest(version=version, release=release):
                result = self.verify(version=version, release=release)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('host_cuda_toolchain_gate=pass', result.stdout)

    def test_missing_or_different_installed_component_fails(self):
        for package in ('cuda-compiler-13-2', 'cuda-nvcc-13-2',
                        'cuda-crt-13-2', 'libnvvm-13-2', 'cuda-cudart-devel-13-2'):
            for missing in (False, True):
                with self.subTest(package=package, missing=missing):
                    result = self.verify(bad_package=package, missing=missing)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('CUDA build component does not match', result.stderr)

    def test_ci_and_package_preflight_share_policy(self):
        install = (ROOT / 'scripts/ci/install-linux-deps.sh').read_text()
        build = (ROOT / 'scripts/build/build-host-package-binaries.sh').read_text()
        for text in (install, build):
            self.assertIn('/build/host-cuda.sh"', text)
            self.assertIn('plank_verify_host_cuda', text)
        self.assertIn('"${PLANK_HOST_CUDA_PACKAGES[@]}"', install)
        self.assertNotIn('cuda-compiler-13-0', install)
        self.assertLess(build.index('plank_verify_host_cuda'), build.index('cargo test'))
        self.assertIn('-DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc', build)

    def test_exact_package_list_has_no_gpu_driver_installer(self):
        result = subprocess.run(['bash', '-c',
            'source "$1"; printf "%s\\n" "${PLANK_HOST_CUDA_PACKAGES[@]}"',
            'cuda-packages', str(POLICY)], check=True, capture_output=True, text=True)
        packages = result.stdout.splitlines()
        self.assertEqual(len(packages), 17)
        self.assertEqual(len(packages), len(set(packages)))
        self.assertIn('cuda-compiler-13-2-13.2.2-1', packages)
        for package in packages:
            self.assertRegex(package, r'^(cuda-|libnv).*13-2-13\.2\.(2|86)-1$')
            self.assertNotIn('cuda-drivers', package)


if __name__ == '__main__':
    unittest.main()
