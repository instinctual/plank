# SPDX-License-Identifier: AGPL-3.0-or-later
import importlib.util
from pathlib import Path
import re
import unittest

spec = importlib.util.spec_from_file_location(
    "sender_timing", Path(__file__).resolve().parents[2] / "scripts/test/analyze-sender-timing.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SenderTimingTests(unittest.TestCase):
    def test_current_trace_without_application_pacer_fields(self):
        columns = ("frame,key,bytes,dequeue_ns,queue_ns,depth,wire_bps,queue_drops,"
                   "send_ns,fec_total_ns,fec_copy_ns,fec_encoder_ns,fec_repair_ns,"
                   "quinn_ns,quinn_max_ns,datagrams,datagram_bytes,failed")
        source = (Path(__file__).resolve().parents[2] /
                  "protocol/plank-transport/src/sender_trace.rs").read_text()
        exported = re.search(r'PLANK sender-timing columns=([^"\n]+)', source)
        self.assertIsNotNone(exported)
        self.assertEqual(exported.group(1), columns)
        text = ("PLANK sender-timing begin rows=1\n"
                f"PLANK sender-timing columns={columns}\n"
                "PLANK sender-timing 7,1,1000,0,10,1,1000000000,0,4000000,"
                "3000000,100000,200000,1000000,500000,5000,2,1300,0\n"
                "PLANK sender-timing end\n")
        summary = module.summarize(module.read_trace(text))
        self.assertEqual(summary["groups"]["all"]["frames"], 1)
        self.assertEqual(summary["groups"]["key"]["frames"], 1)
        self.assertEqual(summary["groups"]["delta"]["frames"], 0)
        self.assertEqual(summary["groups"]["all"]["totals_ms"], {
            "send_ns": 4.0, "fec_copy_ns": 0.1, "fec_encoder_ns": 0.2,
            "fec_repair_ns": 1.0, "quinn_ns": 0.5})
        self.assertEqual(summary["wire_bps_values"], [1000000000])
        self.assertEqual(summary["failed_submissions"], 0)

    def test_only_last_complete_trace(self):
        text = ("PLANK sender-timing begin rows=1\n"
                "PLANK sender-timing columns=frame,send_ns\n"
                "PLANK sender-timing 7,100\nPLANK sender-timing end\n"
                "PLANK sender-timing begin rows=2\n")
        self.assertEqual(module.read_trace(text)["rows"], [{"frame": 7, "send_ns": 100}])

    def test_reject_malformed(self):
        for text in ("", "PLANK sender-timing begin rows=1\nPLANK sender-timing end",
                     "PLANK sender-timing begin rows=1\nPLANK sender-timing columns=frame\n"
                     "PLANK sender-timing 1,2\nPLANK sender-timing end"):
            with self.assertRaises(ValueError):
                module.read_trace(text)


if __name__ == "__main__":
    unittest.main()
