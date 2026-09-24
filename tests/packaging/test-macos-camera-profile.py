#!/usr/bin/env python3
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('profile', ROOT / 'scripts/package/prepare-macos-camera.py')
profile = importlib.util.module_from_spec(spec); spec.loader.exec_module(profile)


class CameraProfile(unittest.TestCase):
    def test_exact_host_identity_team_entitlement_certificate_and_expiry(self):
        now = datetime.now(timezone.utc)
        cert = b'synthetic signing certificate'
        identity = hashlib.sha1(cert).hexdigest()
        valid = {'Entitlements': {
            'com.apple.application-identifier': 'ABCDEFGHIJ.la.instinctual.PLANK.Host',
            'com.apple.developer.team-identifier': 'ABCDEFGHIJ',
            'com.apple.developer.system-extension.install': True,
        }, 'DeveloperCertificates': [cert], 'ExpirationDate': now + timedelta(days=1)}
        self.assertTrue(profile.valid_profile(valid, 'ABCDEFGHIJ', identity.upper(), now))
        for field, value in [
            ('com.apple.application-identifier', 'ABCDEFGHIJ.la.instinctual.PLANK.NativeCameraProbe'),
            ('com.apple.application-identifier', 'ABCDEFGHIJ.*'),
            ('com.apple.developer.team-identifier', 'KLMNOPQRST'),
            ('com.apple.developer.system-extension.install', False),
            ('com.apple.developer.system-extension.install', 1),
        ]:
            bad = copy.deepcopy(valid); bad['Entitlements'][field] = value
            self.assertFalse(profile.valid_profile(bad, 'ABCDEFGHIJ', identity, now))
        for field, value in [('DeveloperCertificates', [b'another certificate']),
                             ('DeveloperCertificates', []), ('ExpirationDate', now),
                             ('ExpirationDate', now - timedelta(seconds=1)),
                             ('ExpirationDate', 'tomorrow')]:
            bad = copy.deepcopy(valid); bad[field] = value
            self.assertFalse(profile.valid_profile(bad, 'ABCDEFGHIJ', identity, now))


if __name__ == '__main__':
    unittest.main()
