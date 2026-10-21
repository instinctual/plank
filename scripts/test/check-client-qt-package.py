#!/usr/bin/env python3
"""Require the Qt Client to retain the ordinary Ubuntu package identity."""
import argparse
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = 'plank-client'
DESKTOP = 'la.instinctual.Plank.Client'
EXACT = {
    'usr/bin/plank-client', 'etc/plank/client.conf',
    f'usr/share/applications/{DESKTOP}.desktop',
    f'usr/share/metainfo/{DESKTOP}.appdata.xml',
    'usr/share/icons/hicolor/512x512/apps/plank-client.png',
    'usr/lib/udev/rules.d/70-plank-client-wacom.rules',
}
PREFIXES = ('usr/lib/plank/', 'usr/share/doc/plank-client/')


def field(package, name):
    return subprocess.check_output(['dpkg-deb', '--field', str(package), name], text=True).strip()


def read_tar(package, kind, wanted, restrict_directories=False):
    contents, names = {}, set()
    with subprocess.Popen(['dpkg-deb', kind, str(package)], stdout=subprocess.PIPE) as process:
        with tarfile.open(fileobj=process.stdout, mode='r|*') as archive:
            for member in archive:
                name = member.name.removeprefix('./')
                path = PurePosixPath(name)
                if path.is_absolute() or '..' in path.parts:
                    raise ValueError('unsafe package path')
                if member.isdir():
                    if restrict_directories and name not in ('.', '') and not any(
                            p.startswith(name.rstrip('/') + '/') for p in EXACT | set(PREFIXES)):
                        if not name.startswith(PREFIXES):
                            raise ValueError('unexpected directory: ' + name)
                    continue
                if not (member.isfile() or member.issym()):
                    raise ValueError('unexpected package file type: ' + name)
                if name in names:
                    raise ValueError('duplicate package path: ' + name)
                names.add(name)
                if member.issym() and restrict_directories:
                    target = PurePosixPath(member.linkname)
                    if not name.startswith(PREFIXES[0]) or target.is_absolute() or len(target.parts) != 1:
                        raise ValueError('symlink leaves the private library directory')
                if name in wanted:
                    if not member.isfile() or member.size > 65536:
                        raise ValueError('invalid metadata file: ' + name)
                    contents[name] = archive.extractfile(member).read().decode('utf-8')
        if process.wait() != 0:
            raise ValueError('cannot read package archive')
    return names, contents


def validate(package):
    if field(package, 'Package') != PACKAGE:
        raise ValueError('not the ordinary plank-client package')
    if field(package, 'Architecture') != 'amd64' or not re.fullmatch(
            r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z0-9]+(?:-[a-z0-9]+)*)?', field(package, 'Version')):
        raise ValueError('invalid Ubuntu Client architecture/version')
    for key in ('Conflicts', 'Replaces', 'Breaks', 'Provides'):
        if field(package, key):
            raise ValueError('Client package must not declare ' + key)
    names, metadata = read_tar(package, '--fsys-tarfile',
                               {f'usr/share/applications/{DESKTOP}.desktop'}, True)
    if not EXACT.issubset(names):
        raise ValueError('Client package is missing required files')
    for name in names:
        if name not in EXACT and not name.startswith(PREFIXES):
            raise ValueError('file outside Client namespace: ' + name)
    desktop = metadata[f'usr/share/applications/{DESKTOP}.desktop'].splitlines()
    for expected in ('Name=PLANK Client', 'Exec=plank-client', 'Icon=plank-client',
                     'StartupWMClass=' + DESKTOP):
        if expected not in desktop:
            raise ValueError('incorrect Client desktop identity')
    if any(line.startswith(('MimeType=', 'DBusActivatable=')) for line in desktop):
        raise ValueError('Client must not introduce activation/URL handlers')
    control_names, control = read_tar(package, '--ctrl-tarfile', {'conffiles', 'postinst', 'postrm'})
    if control.get('conffiles', '').strip() != '/etc/plank/client.conf':
        raise ValueError('incorrect Client conffile ownership')
    if control_names - {'control', 'conffiles', 'md5sums', 'postinst', 'postrm'}:
        raise ValueError('unexpected package lifecycle hook')
    for script in ('postinst', 'postrm'):
        if control.get(script) != (ROOT / 'packaging/client/linux/deb' / script).read_text():
            raise ValueError('unreviewed Client package lifecycle script')
    return names


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    args = parser.parse_args()
    try:
        validate(args.package)
    except (OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
    print('client_qt_package_identity_gate=pass installation_test=not-performed')
