#!/usr/bin/env python3
"""Ubuntu-only compiler cache; clean builds/tests/packages remain mandatory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import tempfile


def output(command):
    return subprocess.check_output(command, text=True).strip()


def require_runner():
    if (os.environ.get('GITHUB_ACTIONS'), platform.system(), platform.machine()) != (
            'true', 'Linux', 'x86_64'):
        raise ValueError('Compiler cache requires the hosted Ubuntu 26.04 Client builder')
    release = dict(entry.split('=', 1) for entry in
                   shlex.split(Path('/etc/os-release').read_text(), comments=True) if '=' in entry)
    if (release.get('ID'), release.get('VERSION_ID')) != ('ubuntu', '26.04'):
        raise ValueError('Compiler cache requires Ubuntu 26.04')


def cache_plan(root, work, tools, revision, run_id, attempt):
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Invalid source revision')
    if not all(re.fullmatch(r'[1-9][0-9]*', value) for value in (run_id, attempt)):
        raise ValueError('Invalid workflow run identity')
    inputs = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in (
        'scripts/ci/compiler-cache.py', 'scripts/ci/cached-compiler.sh', 'rust-toolchain.toml')}
    identity = {'os': 'ubuntu-26.04', 'architecture': 'x86_64', 'inputs': inputs,
                'source_root': str(root), 'work_root': str(work), 'tools': tools}
    prefix = 'plank-linux-client-compiler-v1-' + hashlib.sha256(
        json.dumps(identity, sort_keys=True).encode()).hexdigest() + '-'
    # Archives are immutable. A successful build saves a new snapshot; restore
    # may use the latest trusted snapshot in this branch/default-branch scope.
    # sccache independently keys compiler, sources, headers and flags per object.
    return {'path': str(work / 'compiler-cache'), 'prefix': prefix,
            'key': prefix + revision + '-' + run_id + '-' + attempt}


def append_values(path, values):
    with path.open('a') as stream:
        for name, value in values.items():
            if '\n' in value or '\r' in value:
                raise ValueError('Invalid workflow output')
            stream.write(f'{name}={value}\n')


def enable(root, work, env_file, path_file):
    wrappers = work / 'compiler-wrappers'
    wrappers.mkdir()  # Refuse accidentally reusing a populated job workspace.
    for compiler in ('cc', 'c++', 'gcc', 'g++'):
        (wrappers / compiler).symlink_to(root / 'scripts/ci/cached-compiler.sh')
    append_values(env_file, {
        'SCCACHE_DIR': str(work / 'compiler-cache'),
        'SCCACHE_CACHE_SIZE': '2G',
        'SCCACHE_SERVER_UDS': str(work / 'sccache.sock'),
        'SCCACHE_IDLE_TIMEOUT': '0',
        'RUSTC_WRAPPER': '/usr/bin/sccache',
        'CARGO_INCREMENTAL': '0',
        # cc-rs recognizes RUSTC_WRAPPER and adds sccache itself. Give it
        # real compilers, not the PATH wrappers used by qmake/shell tests.
        'HOST_CC': '/usr/bin/gcc',
        'HOST_CXX': '/usr/bin/g++',
    })
    with path_file.open('a') as stream:
        stream.write(str(wrappers) + '\n')


def verify(work):
    with tempfile.TemporaryDirectory(prefix='compiler-cache-check-', dir=work) as temporary:
        source = Path(temporary) / 'probe.c'
        source.write_text('int plank_compiler_cache_probe(void) { return 42; }\n')
        commands = [['cc'], ['/usr/bin/sccache', os.environ['HOST_CC']],
                    ['/usr/bin/sccache', os.environ['HOST_CXX']]]
        for index, command in enumerate(commands):
            subprocess.run(command + ['-c', str(source), '-o',
                                      str(Path(temporary) / f'probe-{index}.o')], check=True)
    print('Compiler cache PATH and cc-rs wrapper wiring passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare', 'enable', 'verify', 'report'))
    args = parser.parse_args()
    require_runner()
    root = Path(os.environ['PLANK_SOURCE_ROOT']).resolve()
    work = Path(os.environ['PLANK_WORK_ROOT']).resolve()
    if any(c in str(root) + str(work) for c in ('\n', '\r')):
        raise ValueError('Invalid builder path')
    if args.operation == 'prepare':
        tools = [output(command) for command in (
            ['/usr/bin/sccache', '--version'], ['/usr/bin/gcc', '--version'],
            ['/usr/bin/g++', '--version'])]
        plan = cache_plan(root, work, tools, os.environ['GITHUB_SHA'],
                          os.environ['GITHUB_RUN_ID'], os.environ['GITHUB_RUN_ATTEMPT'])
        append_values(Path(os.environ['GITHUB_OUTPUT']), plan)
    elif args.operation == 'enable':
        enable(root, work, Path(os.environ['GITHUB_ENV']), Path(os.environ['GITHUB_PATH']))
    elif args.operation == 'verify':
        verify(work)
    else:
        reports = work / 'qt-session-reports'
        reports.mkdir(parents=True, exist_ok=True)
        try:
            report = output(['/usr/bin/sccache', '--show-stats'])
            stats = json.loads(output(['/usr/bin/sccache', '--show-stats', '--stats-format=json']))
            (reports / 'compiler-cache.txt').write_text(report + '\n')
            (reports / 'compiler-cache.json').write_text(json.dumps(stats, indent=2) + '\n')
            print(report)
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
                summary.write('### Ubuntu compiler cache\n\n```text\n' + report + '\n```\n')
        finally:
            subprocess.run(['/usr/bin/sccache', '--stop-server'], check=True)


if __name__ == '__main__':
    main()
