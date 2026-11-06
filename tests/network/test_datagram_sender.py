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

    def test_both_quic_endpoints_use_one_bounded_send_queue_policy(self):
        driver = ROOT / 'third_party/kyber-kymux/kynet/src/driver'
        client = (driver / 'quinn.rs').read_text()
        server = (driver / 'common.rs').read_text()
        self.assertIn('DATAGRAM_SEND_BUFFER_BYTES: usize = 4 * 1024 * 1024', client)
        self.assertIn('datagram_send_buffer_size(DATAGRAM_SEND_BUFFER_BYTES)', client)
        self.assertIn('datagram_send_buffer_size(super::quinn::DATAGRAM_SEND_BUFFER_BYTES)', server)

    def test_video_has_one_platform_independent_fec_sender(self):
        kyproto = ROOT / 'third_party/kyber-kymux/kyproto'
        driver = kyproto / 'src/protocol/driver/av/video_unreliable_fec.rs'
        source = driver.read_text().split('#[cfg(test)]\nmod tests', 1)[0]
        self.assertNotIn('target_os = "macos"', source)
        self.assertNotIn('get_encoded_packets', source)
        self.assertNotIn('source-first-fec', (kyproto / 'Cargo.toml').read_text())
        self.assertIn('super::source_first::source_packets(&data, &config)', source)
        self.assertLess(source.index('self.send_fec_packet(oti, source).await?'),
                        source.index('raptorq::Encoder::new(&data, config)'))


if __name__ == '__main__':
    unittest.main()
