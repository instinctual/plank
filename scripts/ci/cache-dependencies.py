#!/usr/bin/env python3
"""Exact, independent dependency caches; never application or signing state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess

# Keep jointly-built trees together. In particular the Mac native libraries
# share an install prefix; separate caches must never restore overlapping paths.
COMPONENTS = {
    'linux-host': ('rust', 'cargo', 'ffmpeg', 'boost'),
    'linux-client': ('rust', 'cargo', 'ffmpeg', 'native'),
    'macos-host': ('rust', 'cargo'),
    'macos-client': ('rust', 'cargo', 'native', 'qt'),
}
PRODUCTS = tuple(COMPONENTS)
ALL_COMPONENTS = ('rust', 'cargo', 'ffmpeg', 'boost', 'native', 'qt')
HOST_DEPS = 'apps/host/linux/third-party/build-deps'
CLIENT_PATCHES = 'apps/client/app/deploy/linux/ffmpeg-patches'
IDENTITY_PATCH = CLIENT_PATCHES + '/0001-hevc-enable-hwaccel-for-identity-gbr.patch'
SDL_PATCH = 'apps/client/app/deploy/linux/sdl-patches/0001-wayland-detach-the-tablet-cursor-surface.patch'
RECIPES = 'scripts/ci/dependencies/'


def output(command):
    return subprocess.check_output(command, text=True).strip()


def dependency_inputs(root, product, component):
    if component not in COMPONENTS[product]:
        raise ValueError('Dependency does not belong to this product')
    paths = {'scripts/ci/cache-dependencies.py'}
    pins = {}
    if component == 'rust':
        paths.update((RECIPES + 'rust.sh', 'rust-toolchain.toml'))
    elif component == 'cargo':
        paths.update((RECIPES + 'cargo.sh', 'protocol/plank-transport/Cargo.lock',
                      'protocol/plank-transport/Cargo.toml'))
        if product == 'linux-host':
            paths.update(('third_party/quinn-proto-0.11.17/Cargo.toml',
                          'third_party/quinn-proto-0.11.17/Cargo.lock'))
    elif component == 'boost':
        paths.add(RECIPES + 'boost.sh')
    elif component == 'qt':
        paths.update((RECIPES + 'qt.sh', 'scripts/build/macos-client-target.sh'))
    elif component == 'native' and product == 'linux-client':
        paths.update((RECIPES + 'client-sdl.sh', 'scripts/build/build-client-sdl.sh',
                      'scripts/build/client-sdl.sh', 'scripts/build/build-paths.sh',
                      'tests/input/test-sdl-cursor-retirement.py',
                      'scripts/test/check-client-sdl.py', SDL_PATCH))
        paths.update(str(p.relative_to(root)) for p in
                     (root / 'apps/client/app/deploy/linux/sdl-patches').glob('*.patch'))
    elif component == 'native':
        paths.update((RECIPES + 'macos-libraries.sh',
                      'scripts/build/bootstrap-macos-client-deps.sh',
                      'scripts/build/macos-client-target.sh',
                      'scripts/build/build-paths.sh',
                      'scripts/build/relocate-openssl-pc.py',
                      'scripts/build/sanitize-ffmpeg-build-info.py', IDENTITY_PATCH))
        paths.update(str(p.relative_to(root)) for p in (root / CLIENT_PATCHES).glob('*.patch'))
    elif product == 'linux-client':
        paths.update((RECIPES + 'client-ffmpeg.sh',
                      'scripts/build/build-client-ffmpeg.sh',
                      'scripts/build/build-paths.sh',
                      'scripts/build/sanitize-ffmpeg-build-info.py', IDENTITY_PATCH))
        paths.update(str(p.relative_to(root)) for p in (root / CLIENT_PATCHES).glob('*.patch'))
    else:
        paths.update((RECIPES + 'host-ffmpeg.sh',
                      'scripts/build/verify-host-dependency-patches.sh'))
        # FFmpeg/x264/x265 are one jointly-built source/install tree.
        pins['host-build-deps'] = output(['git', '-C', str(root / HOST_DEPS), 'rev-parse', 'HEAD'])
        for entry in output(['git', '-C', str(root / HOST_DEPS), 'ls-files', '--stage']).splitlines():
            metadata, name = entry.split('\t', 1)
            mode, revision, stage = metadata.split()
            if stage != '0':
                raise ValueError('Unmerged dependency input')
            if mode == '160000':
                pins[name] = revision
            else:
                paths.add(HOST_DEPS + '/' + name)
    return paths, pins


def fingerprint(root, deps, product, component, toolchain):
    paths, pins = dependency_inputs(root, product, component)
    hashes = {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sorted(paths)}
    # Rust downloads and Boost sources do not depend on the C/C++ compiler,
    # installed Qt, CUDA or SDK. Compiled libraries still match those exactly.
    tools = {'platform': toolchain['platform']}
    if component in ('ffmpeg', 'native'):
        tools['compiled'] = toolchain['compiled']
    if component == 'cargo':
        tools['rust'] = fingerprint(root, deps, product, 'rust', toolchain)
    data = {'schema': 2, 'product': product, 'component': component,
            'inputs': hashes, 'pins': pins, 'source_root': str(root),
            'dependency_root': str(deps), 'toolchain': tools}
    if product == 'macos-client' and component in ('native', 'qt'):
        target = os.environ.get('PLANK_MAC_CLIENT_MIN_MACOS') or '15.0'
        if target != '15.0':
            raise ValueError('PLANK Client deployment target must be 15.0')
        data['deployment_target'] = target
    return f'plank-{product}-{component}-v2-' + hashlib.sha256(
        json.dumps(data, sort_keys=True).encode()).hexdigest()


def cache_paths(root, deps, product, component):
    if component not in COMPONENTS[product]:
        raise ValueError('Dependency does not belong to this product')
    paths = []
    if component == 'rust':
        paths = [deps / 'rustup', deps / 'cargo/bin']
    elif component == 'cargo':
        # Never include credentials.toml, config or compiled Cargo targets.
        paths = [deps / name for name in ('cargo/registry/cache', 'cargo/registry/index',
                 'cargo/registry/src', 'cargo/git/db', 'cargo/git/checkouts')]
    elif component == 'boost':
        paths = [deps / 'boost-1.89.0']
    elif component == 'qt':
        paths = [deps / 'qt']
    elif component == 'native' and product == 'linux-client':
        paths = [deps / 'client-sdl' / name for name in
                 ('install', 'SDL3-3.4.2', 'SDL3-3.4.2.tar.gz', 'prepared.sha256', 'patch.sha256')]
    elif component == 'native':
        paths = [deps / 'macos-client' / name for name in ('install', 'src', 'downloads')]
    elif product == 'linux-host':
        paths = [deps / 'host-ffmpeg', root / HOST_DEPS / 'build']
    else:
        paths = [deps / 'client-ffmpeg' / name for name in
                 ('install', 'ffmpeg-9.0.1', 'ffmpeg-9.0.1.tar.xz')]
    paths.append(deps / 'cache-receipts' / f'{product}-{component}.json')
    return paths


def key_valid(key, product, component):
    return re.fullmatch(
        f'plank-{re.escape(product)}-{re.escape(component)}-v2-[0-9a-f]{{64}}',
        key or '') is not None


def verify_receipt(root, deps, product, component, key):
    if not key_valid(key, product, component):
        raise ValueError('Invalid dependency cache key')
    receipt = json.loads(cache_paths(root, deps, product, component)[-1].read_text())
    if receipt != {'schema': 2, 'key': key}:
        raise ValueError('Restored dependency cache does not match exact inputs')


def check_prepared(root, deps, product, component):
    if component not in COMPONENTS[product]:
        raise ValueError('Dependency does not belong to this product')
    required = {
        'rust': ['cargo/bin/rustup', 'rustup/settings.toml'],
        'cargo': [],  # Locked fetch always runs; registry/Git sources may be absent.
        'boost': ['boost-1.89.0/CMakeLists.txt'],
        'qt': ['qt/6.10.2/macos/bin/qmake'],
        'native': (['client-sdl/prepared.sha256', 'client-sdl/install/lib/libSDL3.so.0']
                   if product == 'linux-client' else
                   ['macos-client/install/lib/' + name + '.dylib' for name in
                   ('libavcodec', 'libavutil', 'libswscale', 'libswresample',
                    'libssl', 'libcrypto', 'libSDL3', 'libSDL3_ttf', 'libopus', 'libfreetype')]),
        'ffmpeg': (['host-ffmpeg/lib/libavcodec.a', 'host-ffmpeg/lib/libavutil.a']
                   if product == 'linux-host' else
                   ['client-ffmpeg/ffmpeg-9.0.1.tar.xz'] +
                   ['client-ffmpeg/install/lib/' + name + '.so' for name in
                    ('libavcodec', 'libavutil', 'libswscale', 'libswresample')]),
    }[component]
    if any(not (deps / name).is_file() for name in required):
        raise ValueError('Incomplete prepared dependency cache')
    if component == 'ffmpeg' and product == 'linux-host':
        subprocess.run(['bash', str(root / 'scripts/build/verify-host-dependency-patches.sh'),
                        str(root / HOST_DEPS / 'build')], check=True)
    elif component == 'native' and product == 'linux-client':
        subprocess.run(['bash', '-c',
                        'source "$1/scripts/build/client-sdl.sh"; plank_verify_client_sdl "$1" "$2"',
                        'verify-sdl', str(root), str(deps / 'client-sdl')], check=True)
    elif component == 'native' or (component == 'ffmpeg' and product == 'linux-client'):
        source = ('macos-client/src/ffmpeg-9.0.1' if component == 'native'
                  else 'client-ffmpeg/ffmpeg-9.0.1')
        with (root / IDENTITY_PATCH).open('rb') as patch:
            subprocess.run(['patch', '--batch', '--reverse', '--dry-run', '-p1',
                            '-d', str(deps / source)], stdin=patch, check=True)


def toolchain_inputs(product):
    system = 'Linux' if product.startswith('linux-') else 'Darwin'
    architecture = 'x86_64' if system == 'Linux' else 'arm64'
    if platform.system() != system or platform.machine() != architecture:
        raise ValueError('Cache requires the qualified product builder')
    identity = {'architecture': architecture, 'runner_image': os.environ.get('ImageVersion', ''),
                'os': Path('/etc/os-release').read_text() if system == 'Linux'
                else output(['sw_vers', '-productVersion']) + '/' + output(['sw_vers', '-buildVersion'])}
    if product == 'linux-client':
        # A runner image rollout is not a dependency ABI change. Keep the
        # qualified OS/architecture and actual build inputs, not image dates
        # or descriptive /etc/os-release fields maintained by base-files.
        release = dict(entry.split('=', 1) for entry in shlex.split(identity['os'], comments=True)
                       if '=' in entry)
        if (release.get('ID'), release.get('VERSION_ID')) != ('ubuntu', '26.04'):
            raise ValueError('Client cache requires Ubuntu 26.04')
        identity = {'architecture': architecture, 'os': 'ubuntu-26.04'}
    commands = [['cmake', '--version'], ['ninja', '--version'], ['python3', '--version']]
    packages = []
    if product == 'macos-host':
        return {'platform': identity}  # Only downloaded Rust inputs are cached.
    if product == 'macos-client':
        commands += [['xcodebuild', '-version'], ['xcrun', '--sdk', 'macosx', '--show-sdk-version'],
                     ['xcrun', '--sdk', 'macosx', '--show-sdk-build-version'], ['xcrun', 'clang', '--version']]
    else:
        commands += [['nasm', '-v'], ['make', '--version']]
        if product == 'linux-host':
            commands += [['/opt/rh/gcc-toolset-14/root/usr/bin/gcc', '--version'],
                         ['/usr/local/cuda/bin/nvcc', '--version']]
            packages = output(['rpm', '-qa']).splitlines()
        else:
            commands += [['gcc', '--version'], ['g++', '--version'], ['ld', '--version'],
                         ['pkg-config', '--version']]
            packages = ubuntu_build_packages(output(
                ['dpkg-query', '-W', '-f=${binary:Package}=${Version}\n']).splitlines())
    return {'platform': identity, 'compiled': {
        'packages': sorted(packages), 'tools': [output(command) for command in commands]}}


def ubuntu_build_packages(packages):
    """Retain headers, toolchain and ABI inputs, not the whole runner desktop.

    FFmpeg/SDL auto-detect optional libraries. Conservatively include native
    development packages so a newly available optional header also invalidates
    the cache. PHP SDKs are unrelated and neither project probes their headers.
    """
    result = []
    for entry in packages:
        name, separator, version = entry.partition('=')
        if not separator or not version:
            raise ValueError('Invalid installed-package identity')
        name = name.split(':', 1)[0]
        if re.fullmatch(r'php(?:[0-9]+(?:\.[0-9]+)*)?-dev', name):
            continue
        if (re.search(r'-dev(?:-|$)', name)
                or re.match(r'^(?:gcc|g\+\+|cpp|binutils)(?:-|$)', name)
                or name in ('libc6', 'libgcc-s1', 'libstdc++6', 'libwayland-bin',
                            'wayland-protocols')):
            result.append(entry)
    return sorted(result)


def prepare_sources(root, product):
    if product == 'linux-host':
        subprocess.run(['git', '-C', str(root), 'submodule', 'update', '--init', 'apps/host/linux'], check=True)
        # Restored build trees contain relative .git pointers to these sources.
        subprocess.run(['git', '-C', str(root / 'apps/host/linux'), 'submodule', 'update',
                        '--init', '--recursive', 'third-party/build-deps'], check=True)
    elif product.endswith('-client'):
        subprocess.run(['git', '-C', str(root), 'submodule', 'update', '--init', 'apps/client'], check=True)


def hits_path(deps, product):
    # Job-local state, deliberately outside every restored cache.
    return deps / f'{product}-cache-hits.json'


def emit_plan(root, deps, product, keys, hits, result):
    for component, key in keys.items():
        paths = '\n'.join(str(p) for p in cache_paths(root, deps, product, component))
        result.write(f'{component}-key={key}\n{component}-paths<<PLANK_CACHE_PATHS\n'
                     f'{paths}\nPLANK_CACHE_PATHS\n'
                     f'{component}-hit={str(hits.get(component) == key).lower()}\n')


def verify_restored(root, deps, product, keys, matches):
    hits = {}
    for component, matched in matches.items():
        if not matched:
            continue
        if component not in keys or matched != keys[component]:
            raise ValueError('Restored dependency key is not an exact match')
        verify_receipt(root, deps, product, component, matched)
        check_prepared(root, deps, product, component)
        hits[component] = matched
    return hits


def seal(root, deps, product, keys):
    for component, key in keys.items():
        check_prepared(root, deps, product, component)
        receipt = cache_paths(root, deps, product, component)[-1]
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps({'schema': 2, 'key': key}, sort_keys=True) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare', 'verify', 'seal'))
    parser.add_argument('--product', required=True, choices=PRODUCTS)
    args = parser.parse_args()
    root = Path(os.environ['PLANK_SOURCE_ROOT']).resolve()
    deps = Path(os.environ['PLANK_DEP_ROOT']).resolve()
    if any(c in str(root) + str(deps) for c in ('\n', '\r')):
        raise ValueError('Invalid builder path')
    if args.operation == 'prepare':
        prepare_sources(root, args.product)
    tools = toolchain_inputs(args.product)
    keys = {component: fingerprint(root, deps, args.product, component, tools)
            for component in COMPONENTS[args.product]}
    state = hits_path(deps, args.product)
    if args.operation == 'verify':
        matches = {component: os.environ.get('CACHE_MATCHED_' + component.upper(), '')
                   for component in ALL_COMPONENTS}
        hits = verify_restored(root, deps, args.product, keys, matches)
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps(hits, sort_keys=True) + '\n')
    elif args.operation == 'seal':
        seal(root, deps, args.product, keys)
    else:
        hits = json.loads(state.read_text()) if state.exists() else {}
        with open(os.environ['GITHUB_OUTPUT'], 'a') as result:
            emit_plan(root, deps, args.product, keys, hits, result)
        for component, key in keys.items():
            print(f'dependency_cache_key[{component}]={key}')
    print('dependency_cache_' + args.operation + '=pass')


if __name__ == '__main__':
    main()
