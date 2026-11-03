# Intel VA-API packed BT.709 presentation

Accepted September 8, 2026: the operator tested `1.0.68-vaapi-bt709` on
the Dev NUC and reported that playback works and the flashes are gone.
Offscreen and Intel GPU shader pixel checks passed. Post-install GPU-engine
telemetry and a Linux identity streaming regression test were not independently
recorded; those are separate from this functional acceptance.

## Scope and failure

The Dev NUC's 1.0.66 Mac HEVC 10-bit 4:4:4 connection passed exact
VA-API fixture decoding to `xv30le`, then failed `pl_map_avframe_ex()` in
Vulkan presentation. EGL's non-identity 10-bit/HDR gate prevented use of the
working raw packed-surface import. The active stream fell back to software;
Intel DRM video-engine counters remained zero. Queue overflows were observed,
but the reported intermittent yellow/green flashes are not yet attributed.

## Change

Only the explicit ScreenCaptureKit/VideoToolbox HEVC RExt10 4:4:4 tuple selects
the new VA-API packed BT.709 EGL path. Prefer it before Vulkan. Require a
single-plane Y410 composed surface and import its unchanged DMA-BUF storage as
XR30. The shader samples V:Y:U, subtracts exactly 512/1023 from chroma, and
applies full-range BT.709 once in high precision. Preserve sRGB transfer and
10-bit component values. There is no runtime CPU surface download, repack or
upload, and no encoder, transport, queue, input or Host change.

Do not label the Mac stream RGB identity or HDR. Linux identity mode keeps its
existing channel mapping. Apple Main10 4:2:0 keeps its existing presentation path.
From 1.3.15, HEVC requires hardware decoding; H.264 retains exact-format software
fallback. Hardware acceptance still requires the real profile fixture
and EGL surface import; the new path also compiles its shader during that test.

## Validation

`tests/video/packed-bt709-policy.cpp` checks exact tuple selection and negative
cases. `tests/video/packed-bt709-shader.cpp` runs the actual shipped fragment
shader through an external EGL image into an RGB10 framebuffer. Compare all
1024 neutral gray codes and 441 color samples to an independently derived
BT.709 reference, then verify both identity shader modes. Allow at most one
10-bit code of matrix rounding error and no identity error.

Build only on linux-client-builder. Run shader tests offscreen there, then run the same
binary on the Intel test NUC. This synthetic test is not proof of VA-API decode:
the installed candidate must separately pass its real hardware decode/import
test and a live Mac stream with increasing video-engine counters. Confirm
colors, frame rate, CPU load, and flashes interactively. Check the Linux
identity path separately; unrun gates must remain explicit in HANDOFF.
