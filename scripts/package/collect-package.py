#!/usr/bin/env python3
"""Collect an already validated package; never infer validation or rename it."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def atomic_text(path, contents):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(contents)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def collect(args):
    root = args.source_root.resolve()
    commit = git(root, 'rev-parse', '--verify', args.source_commit + '^{commit}')
    version = git(root, 'show', commit + ':packaging/VERSION')
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('source commit does not have a valid package version')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', args.branch):
        raise ValueError('invalid branch qualifier')
    effective = version if args.branch == 'main' else version + '-' + args.branch
    if args.product == 'host' and args.platform == 'macos':
        # Match plank_load_macos_host_package_version. Historical macos-27
        # artifacts retain their original identity when transferred/re-collected.
        if args.target_os not in ('macos-27', 'macos-27.0', 'macos-26.7'):
            raise ValueError('unsupported macOS Host package target')
        if args.branch == 'main' and args.target_os == 'macos-26.7':
            raise ValueError('macOS Host 26.7 requires a candidate branch')
        if args.branch != 'main' and args.target_os != 'macos-27':
            effective += '-' + args.target_os.replace('macos-', 'macos', 1)
    source = args.package.resolve(strict=True)
    if not source.is_file():
        raise ValueError('package must be a regular file')
    extension = source.suffix
    if args.product not in ('host', 'client'):
        raise ValueError('unsupported product; Linux Qt uses the client identity')
    allowed = {'linux': ('.deb', '.rpm'), 'macos': ('.pkg', '.dmg')}
    if extension not in allowed[args.platform]:
        raise ValueError('package extension does not match platform')
    if extension == '.rpm':
        release = '1' if args.branch == 'main' else '0.' + args.branch.replace('-', '_') + '.1'
        expected = 'plank-' + args.product + '-' + version + '-' + release
        pattern = re.escape(expected) + r'\.el\d+\.' + re.escape(args.architecture) + r'\.rpm'
    else:
        expected = 'plank-' + args.product + '_' + effective + '_' + args.architecture + extension
        pattern = re.escape(expected)
    if not re.fullmatch(pattern, source.name):
        raise ValueError('filename disagrees with product/version/branch/architecture')
    checksum = digest(source)
    if args.expected_sha256 and checksum != args.expected_sha256:
        raise ValueError('package checksum does not match expected value')
    channel = 'releases' if args.branch == 'main' else 'candidates'
    output = (args.output_root or root / 'artifacts/packages').resolve()
    directory = output / channel / effective
    destination = directory / args.platform / source.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Lock per version: separate platform builders/collectors cannot lose entries.
    with (directory / '.collection.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest_path = directory / 'manifest.json'
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {
            'schema_version': 1, 'version': effective, 'branch': args.branch,
            'channel': channel, 'packages': []}
        if (manifest.get('schema_version'), manifest.get('version'), manifest.get('branch')) != (1, effective, args.branch):
            raise ValueError('existing manifest does not match collection')
        relative = destination.relative_to(directory).as_posix()
        submodules = {}
        for line in git(root, 'ls-tree', '-r', commit).splitlines():
            metadata, path = line.split('\t', 1)
            mode, kind, oid = metadata.split()
            if kind == 'commit':
                submodules[path] = oid
        record = {'path': relative, 'product': args.product, 'platform': args.platform,
                  'architecture': args.architecture, 'target_os': args.target_os,
                  'size': source.stat().st_size, 'sha256': checksum,
                  'source_commit': commit, 'submodules': submodules,
                  'validation': {'package': args.validation, 'functional': 'not-recorded'}}
        previous = next((p for p in manifest['packages'] if p['path'] == relative), None)
        if previous and previous != record:
            raise ValueError('conflicting artifact/provenance; increment the version, do not overwrite')
        if destination.exists() and digest(destination) != checksum:
            raise ValueError('destination contains a different package; refusing overwrite')
        if not destination.exists():
            fd, temporary = tempfile.mkstemp(prefix='.package-', dir=destination.parent)
            os.close(fd)
            try:
                shutil.copyfile(source, temporary)
                if digest(Path(temporary)) != checksum:
                    raise ValueError('copy checksum mismatch')
                os.chmod(temporary, 0o644)
                os.replace(temporary, destination)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        if not previous:
            manifest['packages'].append(record)
        manifest['packages'].sort(key=lambda p: p['path'])
        atomic_text(destination.with_name(destination.name + '.sha256'), checksum + '  ' + destination.name + '\n')
        atomic_text(manifest_path, json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        atomic_text(directory / 'SHA256SUMS', ''.join(p['sha256'] + '  ' + p['path'] + '\n' for p in manifest['packages']))
        if args.move and source != destination:
            # Only remove the explicitly supplied source after verified collection.
            if digest(source) != checksum:
                raise ValueError('source changed while collecting; refusing to remove it')
            source.unlink()
    print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--source-commit', default='HEAD')
    parser.add_argument('--package', required=True, type=Path)
    parser.add_argument('--product', required=True, choices=['host', 'client'])
    parser.add_argument('--platform', required=True, choices=['linux', 'macos'])
    parser.add_argument('--architecture', required=True, choices=['x86_64', 'amd64', 'arm64', 'all'])
    parser.add_argument('--target-os', required=True, help='qualified OS baseline, e.g. ubuntu-26.04')
    parser.add_argument('--branch', required=True)
    parser.add_argument('--validation', choices=['not-recorded', 'passed'], default='not-recorded',
                        help='package checks only; never implies functional acceptance')
    parser.add_argument('--expected-sha256')
    parser.add_argument('--output-root', type=Path)
    parser.add_argument('--move', action='store_true', help='remove the supplied file only after verified collection')
    args = parser.parse_args()
    try:
        collect(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, 'Package collection failed: ' + str(exc) + '\n')


if __name__ == '__main__':
    main()
