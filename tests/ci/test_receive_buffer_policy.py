"""Exercise the shipped kernel-ceiling guards without touching the real OS."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
POLICY = 'etc/sysctl.d/10-plank-receive-buffer.conf'


class ReceiveBufferPolicyTests(unittest.TestCase):
    def test_only_the_allowed_maximum_changes(self):
        text = (ROOT / 'packaging/common/linux/10-plank-receive-buffer.conf').read_text()
        assignments = [line.strip() for line in text.splitlines()
                       if line.strip() and not line.lstrip().startswith('#')]
        self.assertEqual(assignments, ['net.core.rmem_max = 4194304'])
        spec = (ROOT / 'packaging/host/linux/rpm/plank-host.spec').read_text()
        self.assertIn('%config(noreplace) /' + POLICY, spec)
        for builder in ('build-host-rpm.sh', 'build-client-deb.sh'):
            self.assertIn('packaging/common/linux/10-plank-receive-buffer.conf',
                          (ROOT / 'scripts/package' / builder).read_text())

    def run_hook(self, product, ceiling, isolated=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for name in ('proc/sys/net/core', 'usr/lib/systemd', 'var/log/plank'):
                (base / name).mkdir(parents=True)
            (base / 'proc/sys/net/core/rmem_max').write_text(str(ceiling) + '\n')
            invocation = base / 'invocation'
            command = base / 'usr/lib/systemd/systemd-sysctl'
            command.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > ' + shlex.quote(str(invocation)) + '\n')
            command.chmod(0o755)
            if product == 'client':
                script = (ROOT / 'packaging/client/linux/deb/postinst').read_text()
            else:
                spec = (ROOT / 'packaging/host/linux/rpm/plank-host.spec').read_text()
                script = spec.split('if [ -r /proc/sys/net/core/rmem_max ]', 1)[1].split('\nfi', 1)[0]
                script = '#!/bin/sh\nif [ -r /proc/sys/net/core/rmem_max ]' + script + '\nfi\n'
            # Remap every absolute system path; execute the actual package hook
            # conditional and arguments, not a reimplementation of its policy.
            for prefix in ('/etc/', '/proc/', '/usr/', '/var/'):
                script = script.replace(prefix, str(base) + prefix)
            hook = base / 'hook'
            hook.write_text(script)
            env = {**os.environ, 'DPKG_ROOT': str(base / 'isolated') if isolated else ''}
            subprocess.run(['sh', str(hook), 'configure'], env=env, check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return invocation.read_text().splitlines() if invocation.exists() else []

    def test_installation_applies_only_the_receive_ceiling_when_needed(self):
        for product in ('host', 'client'):
            with self.subTest(product=product):
                self.assertEqual(self.run_hook(product, 212992), ['--prefix=/net/core/rmem_max'])
                self.assertEqual(self.run_hook(product, 4194304), [])
                self.assertEqual(self.run_hook(product, 16777216), [])

    def test_isolated_debian_installation_does_not_change_the_running_kernel(self):
        self.assertEqual(self.run_hook('client', 212992, isolated=True), [])


if __name__ == '__main__':
    unittest.main()
