#!/usr/bin/env python3
"""Check Linux encoder probe ordering and NVENC setup in the source being packaged."""
import pathlib
import re
import sys
import unittest


SOURCE = pathlib.Path(sys.argv.pop(1)) if len(sys.argv) > 1 else (
    pathlib.Path(__file__).resolve().parents[2]
    / "apps/host/linux/src/video.cpp"
)


class EncoderProbeOrder(unittest.TestCase):
    def test_eligibility_precedes_capture(self):
        source = SOURCE.read_text()
        probes = {
            "test_yuv444": ("flag_map[encoder_t::PASSED]", "YUV444_SUPPORT"),
            "test_yuv420_10bit": ("flag_map[encoder_t::PASSED]",),
            "test_yuv444_10bit": ("flag_map[encoder_t::PASSED]", "YUV444_SUPPORT"),
            "test_h264_yuv422": ("encoder.h264[encoder_t::PASSED]", "YUV422_SUPPORT"),
        }
        for name, guards in probes.items():
            with self.subTest(probe=name):
                start = source.index("auto " + name + " =")
                body = source[start:source.index("\n      };", start)]
                before, after = body.split("reset_display(", 1)
                for guard in guards:
                    self.assertIn(guard, before)
                    self.assertIn("return", before[before.index(guard):])
                self.assertIn("is_codec_supported(", after)
                self.assertIn("validate_config(disp, encoder, config)", after)
                self.assertIn("!disp", after)

    def test_product_profile_probes_remain(self):
        source = SOURCE.read_text()
        for call in (
            "test_yuv444(encoder.h264, 0)",
            "test_yuv444_10bit(encoder.h264, 0)",
            "test_h264_yuv422(false)", "test_h264_yuv422(true)",
            "test_yuv444(encoder.hevc, 1)",
            "test_yuv444_10bit(encoder.hevc, 1)",
        ):
            self.assertTrue(call in source, f"Missing active profile probe: {call}")
        self.assertIn("validate_h264_high10_444_identity(", source)


class NvencRecoveryKeyframes(unittest.TestCase):
    def test_single_frame_cbr_requests_two_to_one_keyframe_ratio(self):
        source = (SOURCE.parent / "nvenc/nvenc_base.cpp").read_text()
        setup = source.split("void nvenc_base::configure_rate_control(", 1)[1].split("\n  }", 1)[0]
        self.assertRegex(setup, r"rcParams\.rateControlMode\s*=\s*NV_ENC_PARAMS_RC_CBR\s*;")
        self.assertEqual(re.findall(r"rcParams\.lowDelayKeyFrameScale\s*=\s*(\w+)\s*;", setup), ["2"])


if __name__ == "__main__":
    unittest.main()
