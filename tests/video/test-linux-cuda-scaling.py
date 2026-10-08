#!/usr/bin/env python3
"""NvFBC integration boundaries; numerical GPU tests live beside this file."""
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/host/linux/src/platform/linux/cuda.cpp').read_text()
device = source.split('class cuda_nvenc_t final:', 1)[1].split('struct cu_resources', 1)[0]


class CudaScalingWiring(unittest.TestCase):
    def test_reduction_only_and_single_conversion(self):
        init = device.split('bool init_encoder(', 1)[1].split('int convert(', 1)[0]
        self.assertIn('if (!native10_input)', init)
        self.assertIn('sws.viewport.width < input_width || sws.viewport.height < input_height', init)
        self.assertIn('sws.scale = 1.0f', init)
        self.assertIn('area_scaler_t::make(input_width, input_height, sws.viewport.width, sws.viewport.height)', init)

    def test_every_direct_format_consumes_the_filtered_texture(self):
        convert = device.split('int convert(', 1)[1].split('private:', 1)[0]
        self.assertIn('if (area_scaler)', convert)
        self.assertIn('source = area_scaler->texture()', convert)
        for method in ('convert_nv12', 'convert_p010', 'convert_yuv444_10bit', 'convert_yuv444'):
            call = convert.split('sws.' + method + '(', 1)[1].split(';', 1)[0]
            self.assertIn('source, stream.get()', call)
            self.assertNotIn('texture.texture.point', call)
        self.assertNotIn('cudaMemcpy', convert.split('auto &texture', 1)[1])
        self.assertIn('scale_xrgb10_to_yuv444_10bit(', convert)


if __name__ == '__main__':
    unittest.main()
