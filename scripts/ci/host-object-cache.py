#!/usr/bin/env python3
"""Hosted Rocky compiler outputs only; never restore build trees or packages."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import tarfile
import tempfile
import urllib.request

SCCACHE_VERSION = '0.19.0'
SCCACHE_ARCHIVE = f'sccache-v{SCCACHE_VERSION}-x86_64-unknown-linux-musl'
SCCACHE_SHA256 = 'aa73c7270c997894038c0d8f0d297865f57569e1687883322bc431713d4bb9dd'
CC = '/opt/rh/gcc-toolset-14/root/usr/bin/gcc'
CXX = '/opt/rh/gcc-toolset-14/root/usr/bin/g++'
NVCC = '/usr/local/cuda/bin/nvcc'

spec = importlib.util.spec_from_file_location('compiler_cache_common', Path(__file__).with_name('compiler-cache.py'))
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)


def require_runner():
    if (os.environ.get('GITHUB_ACTIONS'), platform.system(), platform.machine()) != ('true', 'Linux', 'x86_64'):
        raise ValueError('Host compiler cache requires a hosted Rocky Linux builder')
    release = dict(entry.split('=', 1) for entry in shlex.split(Path('/etc/os-release').read_text(), comments=True)
                   if '=' in entry)
    if (release.get('ID'), release.get('VERSION_ID')) != ('rocky', '9.7'):
        raise ValueError('Host compiler cache requires Rocky Linux 9.7')


def cache_binary(work):
    return work / 'compiler-tools/sccache'


def install(work):
    binary = cache_binary(work)
    binary.parent.mkdir(parents=True, exist_ok=True)
    url = f'https://github.com/mozilla/sccache/releases/download/v{SCCACHE_VERSION}/{SCCACHE_ARCHIVE}.tar.gz'
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read(100 * 1024 * 1024 + 1)
    if len(archive) > 100 * 1024 * 1024 or hashlib.sha256(archive).hexdigest() != SCCACHE_SHA256:
        raise ValueError('Pinned sccache archive checksum mismatch')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as source:
        member = source.getmember(SCCACHE_ARCHIVE + '/sccache')
        if not member.isfile() or member.size > 100 * 1024 * 1024:
            raise ValueError('Invalid sccache executable in verified archive')
        binary.write_bytes(source.extractfile(member).read())
    binary.chmod(0o755)
    if common.output([str(binary), '--version']) != 'sccache ' + SCCACHE_VERSION:
        raise ValueError('Unexpected sccache executable version')


def cache_plan(root, work, tools, revision, run_id, attempt):
    if not re.fullmatch(r'[0-9a-f]{40}', revision) or not all(
            re.fullmatch(r'[1-9][0-9]*', value) for value in (run_id, attempt)):
        raise ValueError('Invalid workflow source/run identity')
    inputs = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in (
        'scripts/ci/host-object-cache.py', 'scripts/ci/compiler-cache.py',
        'scripts/build/host-cuda.sh', 'rust-toolchain.toml')}
    identity = {'os': 'rocky-9.7', 'architecture': 'x86_64', 'inputs': inputs,
                'source_root': str(root), 'work_root': str(work), 'tools': tools}
    prefix = 'plank-linux-host-compiler-v1-' + hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest() + '-'
    return {'path': str(work / 'host-compiler-cache'), 'prefix': prefix,
            'key': prefix + revision + '-' + run_id + '-' + attempt}


def enable(work, env_file):
    binary = str(cache_binary(work))
    if not Path(binary).is_file():
        raise ValueError('Install the pinned compiler cache first')
    common.append_values(env_file, {
        'SCCACHE_DIR': str(work / 'host-compiler-cache'),
        'SCCACHE_CACHE_SIZE': '2G',
        'SCCACHE_SERVER_UDS': str(work / 'host-sccache.sock'),
        'SCCACHE_IDLE_TIMEOUT': '0',
        'RUSTC_WRAPPER': binary,
        'CARGO_INCREMENTAL': '0',
        'CMAKE_C_COMPILER_LAUNCHER': binary,
        'CMAKE_CXX_COMPILER_LAUNCHER': binary,
        'CMAKE_CUDA_COMPILER_LAUNCHER': binary,
    })
    # No PATH/compiler replacement: preserve GCC14/NVCC and cc-rs' existing
    # native C compiler selection. CMake and Cargo call the launcher explicitly.


def verify(work):
    binary = str(cache_binary(work))
    before = json.loads(common.output([binary, '--show-stats', '--stats-format=json']))['stats']['cache_hits']
    with tempfile.TemporaryDirectory(prefix='host-cache-check-', dir=work) as temporary:
        directory = Path(temporary)
        header = directory / 'value.h'
        source = directory / 'probe.cpp'
        obj = directory / 'probe.o'
        executable = directory / 'probe'
        source.write_text('#include "value.h"\nint main() { return VALUE; }\n')
        for value in (41, 41, 42):
            header.write_text(f'#define VALUE {value}\n')
            subprocess.run([binary, CXX, '-c', str(source), '-o', str(obj)], check=True)
            subprocess.run([CXX, str(obj), '-o', str(executable)], check=True)
            if subprocess.run([str(executable)]).returncode != value:
                raise ValueError('Compiler cache returned a stale header value')
        cuda = directory / 'probe.cu'
        cuda.write_text('__global__ void plank_cache_probe(int* out) { *out = 42; }\n')
        cuda_obj = directory / 'cuda.o'
        previous = None
        for _ in range(2):
            subprocess.run([binary, NVCC, '-ccbin', CXX, '-c', str(cuda), '-o', str(cuda_obj)], check=True)
            current = cuda_obj.read_bytes()
            if previous is not None and previous != current:
                raise ValueError('CUDA compiler cache changed the repeated object')
            previous = current
        rust = directory / 'probe.rs'
        rust.write_text('pub fn plank_cache_probe() -> u32 { 42 }\n')
        rust_env = dict(os.environ, CARGO_HOME=os.environ['PLANK_CARGO_ROOT'], RUSTUP_HOME=os.environ['PLANK_RUSTUP_ROOT'])
        rustc = str(Path(os.environ['PLANK_CARGO_ROOT']) / 'bin/rustc')
        for _ in range(2):
            subprocess.run([binary, rustc, '--crate-name', 'plank_cache_probe', '--crate-type=rlib',
                            str(rust), '-o', str(directory / 'probe.rlib')], env=rust_env, check=True)
        (directory / 'probe.c').write_text('int plank_cache_c_probe(void) { return 42; }\n')
        (directory / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.20)
project(HostCacheProbe LANGUAGES C CXX CUDA)
add_library(probe OBJECT probe.c probe.cpp probe.cu)
foreach(language C CXX CUDA)
  get_target_property(launcher probe ${language}_COMPILER_LAUNCHER)
  if(NOT launcher STREQUAL "$ENV{CMAKE_${language}_COMPILER_LAUNCHER}")
    message(FATAL_ERROR "Missing ${language} compiler cache launcher")
  endif()
endforeach()
''')
        build = directory / 'cmake-build'
        subprocess.run(['cmake', '-S', str(directory), '-B', str(build),
                        '-DCMAKE_C_COMPILER=' + CC, '-DCMAKE_CXX_COMPILER=' + CXX,
                        '-DCMAKE_CUDA_COMPILER=' + NVCC, '-DCMAKE_CUDA_HOST_COMPILER=' + CXX], check=True)
        subprocess.run(['cmake', '--build', str(build), '--parallel', '2'], check=True)
    after = json.loads(common.output([binary, '--show-stats', '--stats-format=json']))['stats']['cache_hits']
    for language in ('C/C++', 'Rust'):
        if after['counts'].get(language, 0) <= before['counts'].get(language, 0):
            raise ValueError(language + ' cache smoke test did not produce a cache hit')
    cuda_hits = lambda data: sum(value for name, value in data['adv_counts'].items() if 'nvcc' in name.lower())
    if cuda_hits(after) <= cuda_hits(before):
        raise ValueError('CUDA cache smoke test did not produce an NVCC cache hit')
    print('Host C++ header invalidation, CUDA and Rust compiler cache smoke checks passed')


def report(work, artifact_root):
    binary = str(cache_binary(work))
    reports = artifact_root / 'qualification/host-compiler-cache'
    reports.mkdir(parents=True, exist_ok=True)
    try:
        text = common.output([binary, '--show-stats'])
        stats = json.loads(common.output([binary, '--show-stats', '--stats-format=json']))
        (reports / 'stats.txt').write_text(text + '\n')
        (reports / 'stats.json').write_text(json.dumps(stats, indent=2) + '\n')
        print(text)
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('### Linux Host compiler reuse\n\n```text\n' + text + '\n```\n')
    finally:
        subprocess.run([binary, '--stop-server'], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('install', 'prepare', 'enable', 'verify', 'report'))
    args = parser.parse_args()
    require_runner()
    root = Path(os.environ['PLANK_SOURCE_ROOT']).resolve()
    work = Path(os.environ['PLANK_WORK_ROOT']).resolve()
    if any(c in str(root) + str(work) for c in ('\n', '\r')):
        raise ValueError('Invalid builder path')
    work.mkdir(parents=True, exist_ok=True)
    if args.operation == 'install':
        install(work)
    elif args.operation == 'prepare':
        tools = [common.output(command) for command in (
            [str(cache_binary(work)), '--version'], [CC, '--version'], [CXX, '--version'],
            [NVCC, '--version'], ['/usr/bin/cc', '--version'])]
        plan = cache_plan(root, work, tools, os.environ['GITHUB_SHA'], os.environ['GITHUB_RUN_ID'], os.environ['GITHUB_RUN_ATTEMPT'])
        common.append_values(Path(os.environ['GITHUB_OUTPUT']), plan)
    elif args.operation == 'enable':
        enable(work, Path(os.environ['GITHUB_ENV']))
    elif args.operation == 'verify':
        verify(work)
    else:
        report(work, Path(os.environ['PLANK_ARTIFACT_ROOT']))


if __name__ == '__main__':
    main()
