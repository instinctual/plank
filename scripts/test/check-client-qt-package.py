#!/usr/bin/env python3
"""Reject experimental Client packages that can replace production state/files."""
import argparse
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = 'plank-client-qt'
DESKTOP = 'la.instinctual.Plank.Client.Qt'
EXACT = {
    'usr/bin/plank-client-qt', 'etc/plank/client-qt.conf',
    f'usr/share/applications/{DESKTOP}.desktop',
    f'usr/share/metainfo/{DESKTOP}.appdata.xml',
    'usr/share/icons/hicolor/512x512/apps/plank-client-qt.png',
    'usr/lib/udev/rules.d/70-plank-client-qt-wacom.rules',
}
PREFIXES = ('usr/lib/plank-client-qt/', 'usr/share/doc/plank-client-qt/')


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


def validate(package, production=None):
    if field(package, 'Package') != PACKAGE:
        raise ValueError('not a separate plank-client-qt package')
    if field(package, 'Architecture') != 'amd64' or '-' not in field(package, 'Version'):
        raise ValueError('experimental package must be a branch-labelled Ubuntu candidate')
    for key in ('Conflicts', 'Replaces', 'Breaks', 'Provides'):
        if field(package, key):
            raise ValueError('experimental package must not declare ' + key)
    if any(part.strip().split()[0] == 'plank-client' for part in field(package, 'Depends').split(',') if part.strip()):
        raise ValueError('experimental package must not depend on the production Client')
    names, metadata = read_tar(package, '--fsys-tarfile',
                               {f'usr/share/applications/{DESKTOP}.desktop'}, True)
    if not EXACT.issubset(names):
        raise ValueError('experimental package is missing required private files')
    for name in names:
        if name not in EXACT and not name.startswith(PREFIXES):
            raise ValueError('file outside experimental namespace: ' + name)
    desktop = metadata[f'usr/share/applications/{DESKTOP}.desktop'].splitlines()
    for expected in ('Name=PLANK Client Qt', 'Exec=plank-client-qt', 'Icon=plank-client-qt',
                     'StartupWMClass=' + DESKTOP):
        if expected not in desktop:
            raise ValueError('incorrect experimental desktop identity')
    if any(line.startswith(('MimeType=', 'DBusActivatable=')) for line in desktop):
        raise ValueError('experimental Client must not claim production activation/URL handlers')
    control_names, control = read_tar(package, '--ctrl-tarfile', {'conffiles', 'postinst', 'postrm'})
    if control.get('conffiles', '').strip() != '/etc/plank/client-qt.conf':
        raise ValueError('incorrect experimental conffile ownership')
    if control_names - {'control', 'conffiles', 'md5sums', 'postinst', 'postrm'}:
        raise ValueError('unexpected package lifecycle hook')
    for script in ('postinst', 'postrm'):
        if control.get(script) != (ROOT / 'packaging/client/linux/deb' / script).read_text():
            raise ValueError('unreviewed experimental package lifecycle script')
    if production:
        production_names, _ = read_tar(production, '--fsys-tarfile', set())
        overlap = names & production_names
        if overlap:
            raise ValueError('package overlaps production files: ' + ', '.join(sorted(overlap)))
    return names


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('--production-package', type=Path)
    args = parser.parse_args()
    try:
        validate(args.package, args.production_package)
    except (OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
    print('client_qt_coinstallation_namespace_gate=pass installation_test=not-performed')
