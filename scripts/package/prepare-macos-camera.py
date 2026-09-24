#!/usr/bin/env python3
"""Prepare camera bundle metadata and validate the containing Host's profile."""
import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess

APP_ID = 'la.instinctual.PLANK.Host'
EXTENSION_ID = APP_ID + '.Camera'


def valid_profile(value, team, identity, now):
    entitlements = value.get('Entitlements', {})
    expiry = value.get('ExpirationDate')
    return (entitlements.get('com.apple.application-identifier') == team + '.' + APP_ID and
            entitlements.get('com.apple.developer.team-identifier') == team and
            entitlements.get('com.apple.developer.system-extension.install') is True and
            isinstance(expiry, datetime) and expiry.replace(tzinfo=timezone.utc) > now and
            any(isinstance(cert, bytes) and hashlib.sha1(cert).hexdigest().lower() == identity.lower()
                for cert in value.get('DeveloperCertificates', [])))


def write(path, value):
    path.write_bytes(plistlib.dumps(value))
    path.chmod(0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--profile', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Z0-9]{10}', args.team) or not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('Invalid camera bundle team/version')
    if args.identity != '-':
        if not re.fullmatch(r'[0-9a-fA-F]{40}', args.identity) or not args.profile:
            parser.error('A Developer ID Host profile with system-extension installation permission is required')
        result = subprocess.run(['security', 'cms', '-D', '-i', str(args.profile)], capture_output=True)
        if result.returncode:
            parser.error('Cannot decode the Host provisioning profile')
        try:
            accepted = valid_profile(plistlib.loads(result.stdout), args.team, args.identity, datetime.now(timezone.utc))
        except (TypeError, ValueError, AttributeError):
            accepted = False
        if not accepted:
            parser.error('Profile does not authorize this Host, signing identity, team or current date')
        embedded = args.app / 'Contents/embedded.provisionprofile'
        embedded.write_bytes(args.profile.read_bytes()); embedded.chmod(0o644)
    group = args.team + '.' + APP_ID
    extension = args.app / ('Contents/Library/SystemExtensions/' + EXTENSION_ID + '.systemextension')
    (extension / 'Contents/MacOS').mkdir(parents=True)
    write(extension / 'Contents/Info.plist', {
        'CFBundleIdentifier': EXTENSION_ID, 'CFBundleName': 'PLANK Camera',
        'CFBundleExecutable': 'plank-camera', 'CFBundlePackageType': 'SYSX',
        'CFBundleVersion': args.version, 'CFBundleShortVersionString': args.version,
        'LSMinimumSystemVersion': '27.0',
        'NSSystemExtensionUsageDescription': 'Provide the camera forwarded by your connected PLANK Client.',
        'CMIOExtension': {'CMIOExtensionMachServiceName': group + '.Camera'},
    })
    write(args.output / 'camera-extension-entitlements.plist', {
        'com.apple.security.app-sandbox': True,
        'com.apple.security.application-groups': [group],
        'com.apple.security.temporary-exception.mach-lookup.global-name': [APP_ID + '.camera-extension'],
    })
    write(args.output / 'camera-host-entitlements.plist', {
        'com.apple.developer.system-extension.install': True,
        'com.apple.application-identifier': group,
        'com.apple.developer.team-identifier': args.team,
        'com.apple.security.application-groups': [group],
    })


if __name__ == '__main__':
    main()
