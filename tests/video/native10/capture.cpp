// Production-header fixtures: no X server or GPU required.
#include "src/frame_timing.h"
#include "src/platform/linux/x11_capture_batch.h"
#include "src/platform/linux/x11_rgb10.h"
#include <cassert>
#include <iostream>
#include <limits>
#include <random>
#include <vector>

namespace {
std::vector<int> calls;
int fail_at = 0, mismatch = 0;
xcb_get_geometry_cookie_t geometry(xcb_connection_t*, xcb_drawable_t drawable) {
    calls.push_back(int(drawable)); return {drawable};
}
xcb_shm_get_image_cookie_t image(xcb_connection_t*, xcb_drawable_t drawable,
    int16_t x, int16_t y, uint16_t width, uint16_t height, uint32_t mask,
    uint8_t format, xcb_shm_seg_t segment, uint32_t offset) {
    assert(drawable == 2 && x == 4 && y == 8 && width == 16 && height == 10);
    assert(mask == ~0U && format == XCB_IMAGE_FORMAT_Z_PIXMAP && segment == 17 && offset == 0);
    calls.push_back(3); return {3};
}
template<class T> T* reply(unsigned sequence, xcb_generic_error_t** error) {
    assert((calls.size() >= 3 && calls[0] == 1 && calls[1] == 2 && calls[2] == 3));
    calls.push_back(int(sequence + 3));
    if (fail_at == int(sequence)) {
        *error = static_cast<xcb_generic_error_t*>(std::calloc(1, sizeof(xcb_generic_error_t)));
        (*error)->error_code = 8;
        return nullptr;
    }
    if (fail_at == int(sequence + 3)) return nullptr; // broken connection, no error reply
    return static_cast<T*>(std::calloc(1, sizeof(T)));
}
xcb_get_geometry_reply_t* geometry_reply(xcb_connection_t*, xcb_get_geometry_cookie_t cookie, xcb_generic_error_t** error) {
    auto* r = reply<xcb_get_geometry_reply_t>(cookie.sequence, error);
    if (r) { r->width = mismatch == int(cookie.sequence) ? 127 : 128; r->height = 64; r->depth = mismatch == 4 ? 24 : 30; }
    return r;
}
xcb_shm_get_image_reply_t* image_reply(xcb_connection_t*, xcb_shm_get_image_cookie_t cookie, xcb_generic_error_t** error) {
    auto* r = reply<xcb_shm_get_image_reply_t>(cookie.sequence, error);
    if (r) { r->size = mismatch == 3 ? 4 : 16 * 10 * 4; r->depth = mismatch == 5 ? 24 : 30; }
    return r;
}
void capture_test() {
    const platf::x11::capture_api_t api {geometry, geometry_reply, image, image_reply};
    for (fail_at = 0; fail_at <= 6; ++fail_at) for (mismatch = 0; mismatch <= 5; ++mismatch) {
        calls.clear();
        const auto result = platf::x11::capture_batch(api, nullptr, 1, 2, 4, 8, 16, 10, 128, 64, 17);
        assert(result.valid == (fail_at == 0 && mismatch == 0));
        assert((calls == std::vector<int>{1, 2, 3, 4, 5, 6})); // drain all replies even after errors
        assert(result.geometry_wait_us >= 0 && result.image_wait_us >= 0);
    }
}
void pixel_test() {
    std::mt19937 generator(1);
    for (const std::size_t width : {0U, 1U, 7U, 8U, 9U, 1023U, 1024U, 3840U, 5120U, 7681U}) {
        for (std::size_t alignment = 0; alignment < 8; ++alignment) {
            std::vector<uint32_t> pixels(width + alignment);
            for (auto& pixel : pixels) pixel = generator(); // includes nonzero alpha/padding
            std::vector<uint16_t> green(width + alignment + 1, 0xeeee), blue = green, red = green;
            const auto original = pixels;
            platf::x11::unpack_xrgb10_to_gbr10_row(pixels.data() + alignment,
                green.data() + alignment, blue.data() + alignment, red.data() + alignment, width);
            for (std::size_t x = 0; x < width; ++x) {
                const auto p = pixels[alignment + x];
                assert(red[alignment + x] == (p & 1023));
                assert(green[alignment + x] == ((p >> 10) & 1023));
                assert(blue[alignment + x] == ((p >> 20) & 1023));
            }
            assert(pixels == original);
            for (std::size_t x = 0; x < alignment; ++x) assert(red[x] == 0xeeee && blue[x] == 0xeeee && green[x] == 0xeeee);
            assert(red.back() == 0xeeee && green.back() == 0xeeee && blue.back() == 0xeeee);
        }
    }
    // Every ten-bit code must remain distinct in each plane.
    std::vector<uint32_t> ramp(1024); std::vector<uint16_t> r(1024), g(1024), b(1024);
    for (unsigned i = 0; i < 1024; ++i) ramp[i] = i | i << 10 | i << 20 | 0xc0000000U;
    platf::x11::unpack_xrgb10_to_gbr10_row(ramp.data(), g.data(), b.data(), r.data(), ramp.size());
    for (unsigned i = 0; i < 1024; ++i) assert(r[i] == i && g[i] == i && b[i] == i);
    for (unsigned h = 0; h <= 2161; h += 7) for (unsigned count = 1; count <= 16; ++count) {
        std::size_t next = 0;
        for (unsigned i = 0; i < count; ++i) {
            auto [first, last] = platf::x11::row_range(h, i, count);
            assert(first == next && last >= first && last <= h); next = last;
        }
        assert(next == h);
    }
}
void timing_test() {
    video::timing_samples_t samples;
    static_assert(sizeof(samples) < 17000);
    assert(samples.summary().count == 0);
    samples.push_back(-1); samples.push_back(std::numeric_limits<double>::infinity()); samples.push_back(std::numeric_limits<double>::quiet_NaN());
    assert(samples.size() == 0);
    constexpr unsigned count = 1000000;
    for (unsigned i = 1; i <= count; ++i) samples.push_back(i);
    const auto summary = samples.summary();
    assert(summary.count == count && summary.window_samples == 2048);
    assert(summary.mean == (count + 1.0) / 2 && summary.maximum == count);
    assert(summary.p50 == count - 1024 && summary.p95 == count - 102 && summary.p99 == count - 20);
    assert(summary.over_budget == count - 16666);
}
}
int main() { capture_test(); pixel_test(); timing_test(); std::cout << "native10 capture, RGB10 precision and bounded timing passed\n"; }
