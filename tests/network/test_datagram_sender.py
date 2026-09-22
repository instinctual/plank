"""Inspect the initialized transport dependency before building any product."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DatagramSenderTests(unittest.TestCase):
    def test_quinn_submission_has_no_application_pacer(self):
        kynet = ROOT / 'third_party/kyber-kymux/kynet/src'
        driver = kynet / 'driver/quinn.rs'
        self.assertTrue(driver.is_file(), 'Initialize the pinned Kymux submodule first')
        for path in kynet.rglob('*.rs'):
            source = path.read_text()
            for removed in ('DatagramPacer', 'datagram_pacer', 'outgoing_pacer',
                            'pacer_ns', 'sleep_requested_ns'):
                self.assertNotIn(removed, source, str(path))
        source = driver.read_text()
        self.assertIn('self.conn.send_datagram(data)', source)
        self.assertNotIn('sleep_until', source)


if __name__ == '__main__':
    unittest.main()
