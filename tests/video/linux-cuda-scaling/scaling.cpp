// Exercise production resampling/conversion against an independent double
// precision area oracle. No capture, encoder, service, or display mutation.
#include "src/platform/linux/cuda.h"
#include <cuda_runtime_api.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace cuda {
void pass_error(const std::string_view &where, const char *name, const char *description) {
  std::fprintf(stderr, "%.*s%s: %s\n", int(where.size()), where.data(), name, description);
}
}

static void require(bool ok, const char *message) {
  if (!ok) throw std::runtime_error(message);
}

static void check(cudaError_t result) {
  if (result != cudaSuccess) throw std::runtime_error(cudaGetErrorString(result));
}

// Deliberately direct 2D integration, independent of the GPU's separable passes.
static double reference(const std::vector<unsigned char> &source, int iw, int ih,
                        int ow, int oh, int x, int y, int channel) {
  const double left = double(x) * iw / ow, right = double(x + 1) * iw / ow;
  const double top = double(y) * ih / oh, bottom = double(y + 1) * ih / oh;
  double total = 0;
  for (int sy = int(std::floor(top)); sy < std::min(ih, int(std::ceil(bottom))); ++sy) {
    const double wy = std::min(bottom, sy + 1.0) - std::max(top, double(sy));
    for (int sx = int(std::floor(left)); sx < std::min(iw, int(std::ceil(right))); ++sx) {
      const double wx = std::min(right, sx + 1.0) - std::max(left, double(sx));
      total += source[(size_t(sy) * iw + sx) * 4 + channel] * wx * wy;
    }
  }
  return total / ((right - left) * (bottom - top));
}

static void run(int iw, int ih, int ow, int oh, int pattern, bool benchmark) {
  std::vector<unsigned char> source(size_t(iw) * ih * 4);
  for (int y = 0; y < ih; ++y) {
    for (int x = 0; x < iw; ++x) {
      for (int c = 0; c < 4; ++c) {
        unsigned char value = 0;
        switch (pattern) {
          case 0: value = (x + y) % 2 ? 255 : 0; break; // checkerboard
          case 1: value = x % 2 ? 255 : 0; break; // thin vertical lines
          case 2: value = y % 2 ? 255 : 0; break; // thin horizontal lines
          case 3: value = (x * (13 + c * 7) + y * (31 + c * 3)) % 256; break;
          case 4: value = c == 0 ? 0 : c == 1 ? 128 : 255; break; // range/identity
          case 5: value = x % 256; break; // all 256 levels, including endpoints
        }
        source[(size_t(y) * iw + x) * 4 + c] = value;
      }
    }
  }
  auto texture = cuda::tex_t::make(ih, iw * 4);
  auto scaler = cuda::area_scaler_t::make(iw, ih, ow, oh);
  auto stream = cuda::make_stream();
  require(texture && scaler && stream, "allocation failed");
  check(cudaMemcpy2DToArray(texture->array, 0, 0, source.data(), iw * 4,
                            iw * 4, ih, cudaMemcpyHostToDevice));
  require(!scaler->resize(texture->texture.point, stream.get()), "resize failed");

  // A nonzero destination origin and padded pitch prove letterbox offsets and
  // row strides remain intact. Padding/borders must retain their sentinels.
  constexpr int ox = 3, oy = 2;
  const int rows = oh + oy + 1, pitch = (ow + ox + 5) * 2;
  const size_t planeBytes = size_t(pitch) * rows;
  void *destination = nullptr;
  check(cudaMalloc(&destination, planeBytes * 3));
  cuda::ptr_t owner(destination);
  auto *base = static_cast<unsigned char *>(destination);
  auto converter = cuda::sws_t::make(ow, oh, ow, oh, ow * 4);
  require(bool(converter), "converter allocation failed");
  const cuda::viewport_t viewport {ow, oh, ox, oy};
  for (unsigned depth : {8, 10}) {
    converter->apply_colorspace({video::colorspace_e::identity_gbr, true, depth});
    check(cudaMemsetAsync(base, 0xa5, planeBytes * 3, stream.get()));
    const auto selected = iw == ow && ih == oh ? texture->texture.point : scaler->texture();
    const auto convert = [&]() {
      return depth == 8 ? converter->convert_yuv444(base, base + planeBytes, base + planeBytes * 2,
                          pitch, selected, stream.get(), viewport) :
                          converter->convert_yuv444_10bit(base, base + planeBytes, base + planeBytes * 2,
                          pitch, selected, stream.get(), viewport);
    };
    require(!convert(), "conversion failed");
    check(cudaStreamSynchronize(stream.get()));
    std::vector<unsigned char> actual(planeBytes * 3);
    check(cudaMemcpy(actual.data(), base, actual.size(), cudaMemcpyDeviceToHost));
    constexpr std::array<int, 3> channels {1, 0, 2}; // Y=G, U=B, V=R
    const bool native = iw == ow && ih == oh;
    for (int plane = 0; plane < 3; ++plane) {
      for (int y = 0; y < rows; ++y) {
        const int bytes = depth == 8 ? 1 : 2;
        for (int x = 0; x < pitch; ++x) {
          if (y >= oy && y < oy + oh && x >= ox * bytes && x < (ox + ow) * bytes) continue;
          require(actual[plane * planeBytes + size_t(y) * pitch + x] == 0xa5, "border/stride overwritten");
        }
      }
      for (int y = 0; y < oh; ++y) for (int x = 0; x < ow; ++x) {
        // Cover every small-case pixel and a deterministic 5K sample including
        // edges. This keeps CPU reference time separate from GPU performance.
        if (ow * oh > 100000 && x != 0 && x != ow - 1 && y != 0 && y != oh - 1 &&
            (x + y * 7) % 97 != 0) continue;
        const auto row = actual.data() + plane * planeBytes + size_t(y + oy) * pitch;
        const int value = depth == 8 ? row[x + ox] :
            reinterpret_cast<const unsigned short *>(row)[x + ox] >> 6;
        const double expected = reference(source, iw, ih, ow, oh, x, y, channels[plane]) *
                                (depth == 8 ? 1.0 : 1023.0 / 255.0);
        // 8-bit legacy conversion truncates, 10-bit rounds to nearest even.
        const int quantized = depth == 8 ? int(expected + 1e-8) : int(std::nearbyint(expected));
        if (std::abs(value - quantized) > (native ? 0 : 1)) {
          std::fprintf(stderr, "%dx%d -> %dx%d pattern %d depth %u plane %d pixel %d,%d: %d expected %d\n",
                       iw, ih, ow, oh, pattern, depth, plane, x, y, value, quantized);
          throw std::runtime_error("area/identity mismatch");
        }
        if (depth == 10) require((reinterpret_cast<const unsigned short *>(row)[x + ox] & 63) == 0,
                                 "10-bit alignment mismatch");
      }
    }
    if (benchmark && depth == 10) {
      cudaEvent_t start, stop;
      check(cudaEventCreate(&start)); check(cudaEventCreate(&stop));
      check(cudaEventRecord(start, stream.get()));
      for (int i = 0; i < 30; ++i) {
        require(!scaler->resize(texture->texture.point, stream.get()), "benchmark resize failed");
        require(!convert(), "benchmark conversion failed");
      }
      check(cudaEventRecord(stop, stream.get())); check(cudaEventSynchronize(stop));
      float ms = 0; check(cudaEventElapsedTime(&ms, start, stop));
      check(cudaEventDestroy(start)); check(cudaEventDestroy(stop));
      std::printf("CUDA area+10-bit conversion %dx%d -> %dx%d: %.3f ms/frame (30 GPU iterations)\n",
                  iw, ih, ow, oh, ms / 30);
    }
  }
}

int main(int argc, char **argv) {
  try {
    int count = 0;
    if (cudaGetDeviceCount(&count) != cudaSuccess || !count) {
      std::puts("SKIP: no CUDA device; not GPU acceptance"); return 77;
    }
    const bool benchmark = argc == 2 && std::string_view(argv[1]) == "--benchmark";
    require(!cuda::area_scaler_t::make(0, 10, 2, 2), "invalid source accepted");
    require(!cuda::area_scaler_t::make(10, 10, 0, 2), "invalid target accepted");
    require(!cuda::area_scaler_t::make(10, 10, 20, 2), "upscale accepted");
    require(cuda::test_identity_gbr_8bit_conversion(), "existing 8-bit identity regression");
    require(cuda::test_identity_gbr_10bit_conversion(), "existing 10-bit identity regression");
    int cases = 0;
    for (auto size : std::vector<std::array<int, 4>>{
      {32, 24, 16, 12}, {31, 23, 19, 17}, {31, 23, 1, 1}, {31, 23, 31, 1},
      {31, 23, 1, 23}, {256, 16, 256, 16}, {511, 217, 384, 162},
      {128, 128, 16, 16}, {17, 19, 16, 18}}) {
      for (int pattern = 0; pattern < 6; ++pattern) {
        run(size[0], size[1], size[2], size[3], pattern, false); cases += 2;
      }
    }
    for (auto size : std::vector<std::array<int, 4>>{
      {5120, 2160, 3840, 1620}, {5120, 2160, 1920, 810}, {5120, 2160, 1, 1}}) {
      run(size[0], size[1], size[2], size[3], 3, benchmark); cases += 2;
    }
    std::printf("CUDA scaling: %d area/identity cases, native equality, range, strides and bounds passed\n", cases);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1;
  }
}
