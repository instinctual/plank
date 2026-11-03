# Intel NUC Client Qualification

## Current qualification policy

**Intel NUC Gen11 (Tiger Lake) is not qualified for PLANK Client deployment.**
The operator chose to exclude this generation on 2026-11-03 rather than pursue
further diagnosis or add hardware-specific recovery workarounds. This is a
deployment/acceptance policy, not a runtime hardware block or a claim that every
Gen11 system fails. Other models still require exact-package session acceptance.

The tested Tiger Lake Iris Xe Client repeatedly reported a 100ms VA-API surface
timeout during 5120x2160/60 HEVC 10-bit 4:4:4 identity sessions. Kernel video-engine
hangs, resets and fence expiry followed; the stream ended while the main process
survived. The inspected sessions had zero unrecovered video data after FEC.

Five ten-minute controls passed without new kernel GPU errors:

- independent GStreamer decoding of separately encoded control footage;
- the installed Client's exact FFmpeg libraries decoding that control;
- the same decoder exporting surfaces with four retained leases;
- the recorded failing stream decoded through the installed FFmpeg libraries;
- that recording decoded and sampled into a ten-bit offscreen EGL target,
  with three fenced leases: 36,000 frames, no skipped samples, maximum surface
  synchronization time 5.66ms.

The recording retained packet contents and boundaries, not live arrival timing.
The controls do not reproduce Qt, compositor or multi-output integration. They
do not establish whether the cause is in PLANK, FFmpeg, the driver or the kernel.
The planned single-output live comparison was cancelled with the qualification
decision. Unbuilt decoder-recovery changes were removed from the working tree.
The ordinary installed Client and driver were unchanged. Private captures and
machine evidence remain outside Git; the reusable diagnostic is documented in
[`probes/video/vaapi-decode.md`](../../probes/video/vaapi-decode.md).

## Qualification procedure and historical results

The dated results below describe their original packages and implementations;
they are not current build instructions or acceptance of a new candidate.

Run this gate on every supported NUC generation with its production Ubuntu
kernel, `intel-media-va-driver-non-free` (`iHD`), libva, FFmpeg, GStreamer's
`vah265dec`,
compositor, and display. On Ubuntu, install `gstreamer1.0-plugins-bad` for the
VA decoder. The DMA-BUF probe additionally needs `build-essential`, `pkgconf`,
`libgstreamer1.0-dev`, `libgstreamer-plugins-base1.0-dev`, and `libdrm-dev`.
The Wayland presentation probe needs `wayland-protocols` and the Wayland/EGL
development libraries. It uses the staging commit-timing protocol when the
compositor advertises it.
Copy both the Ada driver-auto and SFE-disabled HEVC test streams from
`artifacts/qualification/video/` to the NUC.

```bash
./scripts/test/probe-intel-vaapi-decode.sh \
  artifacts/qualification/video/plank-flame-loop-150s-sfe-auto-paired.hevc \
  9000

./scripts/test/probe-intel-vaapi-decode.sh \
  artifacts/qualification/video/plank-flame-loop-150s-sfe-disabled.hevc \
  9000

./scripts/test/probe-intel-vaapi-dmabuf.sh \
  artifacts/qualification/video/plank-flame-loop-150s-sfe-disabled.hevc \
  9000

./scripts/test/validate-intel-identity-pixel.sh \
  artifacts/qualification/video/plank-flame-loop-150s-sfe-disabled.hevc \
  600

XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
  ./scripts/test/probe-intel-wayland-xr30.sh 9000

XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
  ./scripts/test/probe-intel-client-pipeline.sh \
  artifacts/qualification/video/plank-flame-fullscreen-loop-150s-sfe-auto.hevc \
  9000

PLANK_ALLOW_DISPLAY_STOP=yes \
  ./scripts/test/run-intel-client-kms-qualification.sh \
  artifacts/qualification/video/plank-flame-fullscreen-loop-150s-sfe-auto.hevc \
  300 16000 /dev/dri/card1

./scripts/test/probe-intel-recovery-pixels.sh \
  plank-recovery-ref-invalidate-reference.hevc \
  plank-recovery-ref-invalidate.hevc 180 600 120
```

The script fails unless VA-API exposes `VAProfileHEVCMain444_10` with the VLD
entry point, the stream retains the full-range GBR identity metadata, GStreamer
negotiates a Y410 VA-memory surface, all requested frames decode, and average
throughput reaches 60 fps. It counts hardware buffers at a VA-only pipeline
boundary; requesting FFmpeg `-hwaccel vaapi` alone is not proof because FFmpeg
may silently fall back to software. For the current long-loop vectors:

```text
auto_sha256=21c2007a97c7fc777b98dd24e5aba9fc1b62f2f2b3453f8bc9d72f1d62118fe1
disabled_sha256=261157e974092e704b6ec4b799a1dabddfd3efbfc86ca6286b6e7a0282dfcad1
fullscreen_auto_sha256=7a60394a6d3ee2bd1de948ef673bb2204d9d8c465d25ae1b9def663fa3593156
fullscreen_disabled_sha256=cf0ce9cb7035c62e49d872f3a6b718f9cd441f3860753525364d9a93d0aba185
final_auto_sha256=a483c4301590ae40b5621ee734db31a056860822a8874fd0223ce333bb07a0b1
final_disabled_sha256=dfb18707b03739540541beb3b369369ce4bceb8811658b259f9281dd6feff94f
frames=9000
resolution=3840x2160
codec=HEVC Rext 10-bit 4:4:4
```

Decode throughput is only the first gate. Use the DMA-BUF probe to qualify an
EGL import without an 8-bit copy. The client implementation must then reverse
the `Y=G,U=B,V=R` identity mapping in its shader, verify channel order with pixel
patterns, and measure decode-to-presentation p95 against the 8 ms target.

## NUC13ANKi7 Result — 2026-08-19

The NUC has Raptor Lake-P Iris Xe graphics (`8086:a7a0`), Ubuntu 26.04, Mesa
26.0.8, libva 1.23, and Intel iHD 26.1.2. The driver advertises HEVC Main444
10-bit VLD with `VA_RT_FORMAT_YUV444_10`. Its active 3840x2160/60 Wayland scanout
is XR30, independently proving a 10-bit RGB display path.

The Intel hardware path accepts the unchanged stream. GStreamer 1.28.2
negotiates `main-444-10` directly to `video/x-raw(memory:VAMemory),format=Y410`
on `/dev/dri/renderD128`. Both complete real-content artifacts pass:

| Stream | Frames | Elapsed | Average throughput |
| --- | ---: | ---: | ---: |
| Ada driver-auto SFE | 9,000 | 40.013 s | 224.93 fps |
| SFE disabled | 9,000 | 37.991 s | 236.90 fps |

These are accelerated-throughput results, not per-frame latency percentiles.
They average 4.45 and 4.22 ms per frame respectively, leaving ample throughput
capacity for 60 Hz.

### Physical Wacom core-pen result — 2026-08-20

A USB PTH-660 (`056a:0357`) exposed separate pen, pad, and touch nodes. The
PLANK udev rule granted the active desktop session access only to the
pen node. During a focused stream, the Moonlight client opened and exclusively
grabbed that node, normalized libinput tablet-tool events, and sent them over
the existing ordered pen protocol. The Rocky host received proximity,
position, distance, pressure tip transitions, and two-axis tilt through its
uinput tablet. Disconnect released the client device. This passes the core-pen
transport gate; ExpressKeys, ring, multitouch, tool serials, barrel rotation,
and tangential pressure remain outside this baseline.

### Exact raw-HID Wacom result — 2026-08-20

Both PTH-660 HID interfaces were then redirected without translating their
reports. The client forwarded the original 949-byte pen/pad and 549-byte touch
descriptors, all input reports, feature-report reads/writes, and output reports.
Rocky's stock `hid-wacom` driver created native Pen, Pad, and Finger devices
with `44800x29600` pen geometry, 8191 pressure levels, distance, tilt,
wheel/rotation, and `8960x5920` touch geometry. XInput confirmed raw stylus
motion, pressure transitions, and tilt from the redirected device.

The live 4K session exclusively grabbed the client's pen, pad, and touch nodes
and suppressed the normalized fallback. The user confirmed full DP-2 reach,
the Ctrl plus bottom-edge Flame gesture, and working Flame Tablet Margins at
both 5% and 20%. The path applied only standard output geometry mapping; it did
not read Flame preferences or pre-scale tablet coordinates. The encrypted
PLANK integration then matched both report descriptors, USB identity,
and host event capabilities, cleaned up on disconnect, recreated the group on
reconnect, and reproduced the Flame gesture and Tablet Margins behavior. The
standalone plaintext bridge remains a test fixture only.

A 2026-08-21 packaged-session retest started Flare before the remote raw-HID
device existed. Native pressure continued to work and Flame persisted 5% on
all four margin controls, but the host Wacom driver's tablet area remained
`0 0 44800 29600`. Restarting Flare with PLANK still connected
restored adjustable Tablet Margins. This confirms an application
initialization-order issue rather than a raw-HID or scaled-span mapping fault:
attach the redirected tablet before starting Flame, or restart Flame after a
late connection. PLANK continues to forward the physical device
unchanged and does not emulate Flame's margins.

### Authenticated automatic Desktop launch — 2026-08-20

The client completed a fresh interactive workstation login through the PAM
broker and automatically started `Desktop`; it did not display the upstream
application chooser or expose Steam. The active session requested
3840x2160x60 at 100 Mbps and reported
`8-bit-source/up-converted -> 10-bit H.264 4:4:4 -> 10-bit RGB identity
presentation`. Because Intel Gen12 does not accelerate H.264 High 4:4:4
Predictive 10-bit, the PLANK profile selected FFmpeg software decode
to `gbrp10le` and retained Vulkan presentation. The route was explicitly
approved as `enx207bd2039662`; discovery remained available independently of
that credential-bearing route check.

The production client bundle now uses FFmpeg 9.0.1. It identifies the correctly
signaled stream as `gbrp10le` and silently
falls back to software even when VA hardware frames are requested. Earlier
FFmpeg measurements of 95.78 and 109.52 fps are therefore invalidated. Do not
change the stream's GBR matrix metadata to work around an FFmpeg negotiation
issue. The client should use the proven Y410 VA surface and import it without a
CPU copy.

The client was built natively on the NUC against FFmpeg 9, then launched with
private `libavcodec.so.63`, `libavutil.so.61`, `libswscale.so.10`, and
`libswresample.so.7` libraries beside the executable. `/proc/<pid>/maps`
confirmed that the running service loaded all four private libraries rather
than Ubuntu's system FFmpeg. `scripts/build/build-client-ffmpeg.sh` pins the official
9.0.1 archive by SHA-256 and reproduces this bundle.

The dedicated DMA-BUF probe requests the required `GstVideoMeta` allocation,
checks every output memory and FD without mapping it, and imports a representative
frame through EGL with the advertised modifier. Both 9,000-frame vectors passed:

| Stream | DMA-BUF throughput | Surface |
| --- | ---: | --- |
| Ada driver-auto SFE | 225.29 fps | Y410, modifier `0x0100000000000002` |
| SFE disabled | 237.50 fps | Y410, modifier `0x0100000000000002` |

The preferred fullscreen-footage stress pair also passed. Driver-auto decoded
at 248.83 fps and disabled at 251.09 fps. The auto stream's higher 78.43 Mbps
rate therefore does not threaten the NUC's decode throughput.

The surface is one 3840x2160 plane with a 15,360-byte stride. Mesa does not
expose `GL_EXT_YUV_target` on this GPU, so the client uses the RGB-identity
method instead of a YUV sampler. Y410 packs `A:V:Y:U`; importing the same
DMA-BUF storage as XR30 interprets those fields as `X:R:G:B`. Sampling it as an
external RGB EGL image therefore reconstructs `R=V,G=Y,B=U` without a matrix,
copy, or loss of precision.

Frame 600 of the real SFE-disabled loop passed an independent center-pixel
comparison. Software decoding produced `R=183,G=177,B=168`; the VA-API Y410
DMA-BUF, XR30 alias, and GLES shader produced the same three 10-bit values. The
decoded surface was never CPU-mapped; readback was limited to the two-pixel
test output.

The integrated Moonlight client also passed a live Sunshine session. It
negotiated HEVC Rext 10-bit 4:4:4 plus the PLANK identity feature,
decoded `gbrp10le` through Intel VA-API to Y410, and presented the Y410/XR30
alias through EGL. Over a 30-second sample it received and decoded 60.05 fps,
rendered 59.89 fps, reported 0.00% network loss and 0.26% jitter-buffer drops,
and measured 0.36 ms average decode, 0.03 ms queueing, and 4.61 ms rendering
including vsync. The host simultaneously reported the source as
`8-bit-source/up-converted` and approximately 79 Mbps of video payload.

Two subsequent 170-second client runs each provided more than 160 seconds of
active streaming, covering a complete 3,583-frame fullscreen Flame loop.
Sunshine was explicitly pinned to NvFBC `output_name = 1`, the 3840x2160
`DP-2` output; default output `0` is the narrow scopes display and must not be
used for this workstation. The runs received/decoded 60.00/60.00 and
60.01/60.01 fps, rendered 59.98 fps, and had 0.00% network loss. Both reported
0.04% client pacer drops, so drop-free long-session pacing remains open. Decode
averaged 0.33 ms, frame queueing 0.77-0.80 ms, rendering including V-sync
4.78-4.79 ms, and network latency 1 ms. Moonlight also warned that it could not
raise its render and audio thread priorities; causality has not been
established. The client retained the 10-bit identity-GBR Y410/XR30 zero-copy
path while the host reported about 79 Mbps. The earlier scopes-display run is
not a content qualification.

A matched priority A/B raised only the test shell's inherited `RLIMIT_NICE`
from 0 to 40, allowing Moonlight's render and audio priority requests to
succeed. The full-loop result still had 0.03% pacer drops and rendered 59.99
fps; decode, queueing, and render averages were 0.35, 0.85, and 4.81 ms. This is
not a material improvement over the two unprivileged controls. The limit was
restored to 0 and the binary retained no file capabilities. Do not grant
Moonlight extra scheduling privilege for this result; instrument pacer-drop
timestamps against Wayland presentation feedback instead.

Moonlight commit `46869740` adds that instrumentation and exact counters for
pacing catch-up, render catch-up, and queue overflow. It also closes an
observability gap where overflow frames were freed without being included in
the aggregate. The rebuilt, unprivileged client then completed two consecutive
full-loop runs at 60.00 fps received, decoded, and rendered, with 0.00% network
loss and exact pacer totals of `0/0/0`. Decode averaged 0.34-0.35 ms, queueing
0.73-0.76 ms, and rendering 4.71-4.78 ms. No drop event occurred to classify,
so retain the earlier repeatable 0.04% results and keep the long-session pacing
gate open until the instrumented client captures a recurrence or a broader soak
establishes the new result as stable.

A later instrumented soak was stopped at 7:27 to release the workstation. It
received, decoded, and rendered 60.00 fps with no network loss. The only two
drops occurred at 9 and 10 seconds after launch: both were render-queue catch-up
events with queue depth 1, target depth 0, and frame ages of 9 and 5 ms. No
pacing-queue or overflow drop occurred, and there were no further drops during
more than two complete content loops. The aggregate rounded to 0.01%. This
localizes the reproduced issue to client render-queue priming near stream
startup rather than sustained network, decode, or content load. The next client
experiment should adjust or explicitly gate startup priming; scheduling
privilege is not justified.

Moonlight commit `c71591a0` implements the resulting startup fix by seeding the
render-queue history with its known empty initial state. This gives the first
500 ms the same bounded grace period used after a queue drains, instead of
selecting an immediate target depth of zero. The commit built successfully on
the dedicated NUC. Its first validation attempt was invalidated when the client
network fell to 2.82 fps with 96.60% packet loss; that run was discarded. After
the NUC was moved to its 1 Gb/s USB Ethernet path, 20 pings to the host had zero
loss and 1.576 ms average RTT. All five fresh 35-second connections then passed
with zero network loss and exact pacer totals of `0/0/0`; queue delay remained
between 0.52 and 0.72 ms. A subsequent full-loop run received, decoded, and
rendered 60.00 fps with `0/0/0` drops, 0.33 ms decode, 0.63 ms queueing, and
4.65 ms rendering. The bounded startup grace therefore removes the reproduced
discard without adding persistent queue depth. A final 10:20 confirmation soak
covered more than four complete footage loops and sustained 60.00 fps received,
decoded, and rendered with zero network loss and exact pacer totals of `0/0/0`.
Decode averaged 0.32 ms, queueing 0.61 ms, and rendering including V-sync
4.75 ms. This closes the startup-pacing gate for the tested NUC and build.

Sunshine's NvFBC backend now forwards the driver's display-render timestamp on
new frames. In a 60-second live validation, Moonlight reported host processing
latency of 4.2/34.1/17.1 ms min/max/average while receiving, decoding, and
rendering 59.99 fps. Network loss and jitter drops remained 0.00%, pacer totals
remained `0/0/0`, and decode, queue, and render averages were 0.35, 0.66, and
4.82 ms. Host processing spans display-render start through packetization; it
is not an NVENC-only measurement. Network-to-photon still requires a shared
host/client clock or a physical capture measurement.

Moonlight commit `4628bd82` adds an exact fixed-memory histogram for the host
field so frame-budget analysis is not limited to averages. A complete
170-second process covering the fullscreen footage loop reported 29.2 ms p95
and 4.3/34.2/17.1 ms min/max/average host processing. It sustained 60.00 fps
for input, decode, and render, with 0.00% loss and jitter drops and pacer totals
of `0/0/0`; decode, queue, and render averages were 0.34, 0.72, and 4.80 ms.
The 29.2 ms interval includes Xorg's render-to-capture phase and an overlapping
encode pipeline, so it is a latency measurement rather than a serial 60 Hz
throughput budget.

Moonlight commit `3c9ef2b2` exposes the negotiated precision stages in both
startup diagnostics and the performance overlay. A full-loop validation
reported `8-bit-source/up-converted`, `10-bit HEVC 4:4:4`, and `10-bit RGB
identity` for source, codec, and presentation respectively. It sustained 60.01
fps for input, decode, and render, with 0.00% network and jitter drops, pacer
totals of `0/0/0`, and 29.1 ms host-processing p95. This closes the explicit
source-precision labeling gate for the identity GBR baseline.

The integrated H.264 identity implementation was matched on 2026-08-20 with
the fullscreen Flame loop and software decoding on this NUC. The 10-bit
`gbrp10le` stream reported `8-bit-source/up-converted -> 10-bit H.264 4:4:4 ->
10-bit RGB identity presentation`; it received/decoded 59.97 fps, rendered
59.96 fps, averaged 6.29 ms decode, and recorded 0.03% jitter loss plus pacer
totals `0/3/0`. Native 8-bit x264rgb reported the corresponding native source
stages, the same frame rates, 4.93 ms decode, 0.02% jitter loss, and pacer totals
`0/2/0`. The 59.97 fps input rate exactly matches the host DP-2 physical mode
(59.973 Hz), while this NUC output is 60.000 Hz. Encoder/transport throughput
therefore reaches full source cadence, but the catch-up drops leave the strict
zero-drop gate open. H.264 High 4:4:4 10-bit and native RGB decoding currently
use FFmpeg software decode; the Intel Vulkan hardware negotiation attempt falls
back to `gbrp10le` or `gbrp` as expected.

This live pass used a PLANK FFmpeg 8.0.1 build with
`AV_PIX_FMT_GBRP10` admitted to the HEVC hardware-format list. Unpatched FFmpeg
rejects hardware negotiation for the correctly signaled matrix-0 stream and
falls back to software. Keep this patch explicit until it is replaced by an
upstream-compatible capability path; do not change the bitstream metadata.

The final matched recaptures also passed every file-backed NUC gate. Intel
VA-API decoded all 9,000 driver-auto frames at 248.04 fps and all disabled
frames at 250.41 fps. The DMA-BUF/EGL path processed them at 248.71 and 250.98
fps respectively using modifier `0x0100000000000002`, without mapping a decoded
surface to the CPU. At frame 600, software reference and Y410-as-XR30 produced
`R=82,G=67,B=63` for auto and `R=86,G=94,B=98` for disabled. Their SHA-256
values are `a483c4301590ae40b5621ee734db31a056860822a8874fd0223ce333bb07a0b1`
and `dfb18707b03739540541beb3b369369ce4bceb8811658b259f9281dd6feff94f`.

The strict serial Wayland presentation soak presented all 9,000 frames with
hardware clock/completion feedback, one-frame depth, and 9,000 zero-copy
imports. Decode and surface-to-swap p95 were both 0.202 ms, while
submit-to-present p95 was 17.046 ms. It averaged 59.801 fps and reported 25
missed refresh intervals, so the frame-pacing gate failed. This reconfirms that
the remaining file-backed limitation is Mutter/fixed-vblank presentation, not
Intel decode or DMA-BUF/EGL throughput.

The fullscreen Wayland probe selected AR30 (`10:10:10:2`) at 3840x2160 and
completed a 9,000-frame, 150-second soak. Swap submission p50/p95 was
0.023/0.034 ms. Wayland frame-callback p50/p95 was 16.662/16.755 ms, which
represents 60 Hz compositor cadence rather than GPU processing time.

The integrated probe timestamps each access unit immediately before
`vah265dec`, decoded DMA-BUF availability, EGL swap submission, and the
`wp_presentation` hardware event. It waits for presentation before submitting
the next frame, keeping the maximum queue depth at one. Both fullscreen vectors
presented all 9,000 frames with hardware-clock, hardware-completion, and vsync
feedback:

| Stream | DMA-BUF fps | Surface-to-swap p95 | Submit-to-present p95 | Zero-copy frames |
| --- | ---: | ---: | ---: | ---: |
| Driver-auto SFE | 248.83 | 0.192 ms | 17.038 ms | 8,995 / 9,000 |
| SFE disabled | 251.09 | not recorded | 17.028 ms | 8,997 / 9,000 |

The auto run's decoder-submit-to-surface p95 was 0.201 ms and swap-call p95 was
0.135 ms. Surface availability is not proof that Intel's asynchronous decode
engine has completed; the hardware presentation timestamp is the authoritative
end boundary. The actual p95 is one 60 Hz refresh because this strictly serial
probe begins the next decode only after the prior frame is presented. The newer
cadence gate shows that this mode can miss refreshes even though every requested
frame is eventually presented. It also fails if the 8 ms client target is
defined as submit-to-photon.

A controlled 300-frame phase test scheduled decoder input 6 ms before a
hardware-derived target vblank. The controlled results were:

| Mode | Lead | Effective fps | Submit-to-present p95 |
| --- | ---: | ---: | ---: |
| Serial | 6 ms | 29.85 | 22.614 ms |
| Threaded | 0 ms | 60.00 | 50.318 ms |
| Threaded | 1 ms | 59.60 | 34.178 ms |
| Threaded | 6 ms | 60.00 | 39.257 ms |

The 1 ms case missed refreshes and is not a valid 60 Hz result. All 300 frames
in the 6 ms threaded control were hardware-clocked, vsynced, and zero-copy.
However, a 60-frame repeat at the same setting missed two refresh intervals,
averaged 58.03 fps, and reached 55.945 ms p95. The threaded result is therefore
not repeatably qualified even at the higher-latency setting.
Mutter accepted a `wp_commit_timing_v1` timestamp on every scheduled frame, but
it did not eliminate the extra vblank; that protocol constrains presentation
to occur no earlier than the requested time and does not guarantee same-vblank
latching. Threading is therefore a throughput mechanism, not the latency fix.
Keep the production queue bounded and investigate asynchronous feedback or a
direct-display path before adopting it. Network-to-photon remains unmeasured
because this file-backed probe starts at decoder submission rather than packet
arrival.

The asynchronous-feedback follow-up confirmed why the blocking design was
stable. Without FIFO, Mutter used mailbox replacement and discarded pending
presentation feedback. FIFO preserved every commit but allowed four frames in
flight, reaching 122.505 ms p95. Explicitly limiting compositor in-flight work
to one frame removed that unbounded queue, but a missed refresh permanently
ratcheted later frames from about 39 ms to 56 ms unless stale content was
dropped.

The live-stream recovery policy now drops a decoded surface when capacity
becomes available more than 1 ms after its hardware-derived target. In a
300-frame fullscreen-content run it dropped 2 frames, then presented the
remaining 298 at exactly 60.00 Hz with 22.615 ms submit-to-present p95. Surfaces
were ready 5.700 ms before target at p50, swaps completed 0.403 ms before target,
and hardware presentation occurred 16.668 ms after target. This is the best
bounded Wayland result, but it still fails the no-drop qualification gate and
cannot meet 8 ms.

The active HDMI display exposes neither VRR nor tearing control. Mutter
advertises a DRM lease device but no leaseable connector; the active HDMI output
remains compositor-owned.

## Direct-KMS Result

The controlled direct-KMS probe temporarily stops the display manager, acquires
DRM master, and restores the graphical session on exit. Run it only over a
remote shell. It decodes the real fullscreen stream to Y410 DMA-BUFs, aliases
their identical packed layout as XR30, and queues legacy page flips against
kernel vblank timestamps. It never maps decoded pixels to the CPU. Synthetic
60 Hz access-unit timestamps make input, decoded output, and target vblank
matching explicit; a cache reuses framebuffers for the decoder's nine surfaces.

| Submit lead | Displayed | Stale drops | Effective fps | Submit-to-present p95 |
| ---: | ---: | ---: | ---: | ---: |
| 8 ms | 151 / 300 | 149 | 30.00 | 24.505 ms |
| 12 ms | 286 / 300 | 14 | 57.18 | 11.954 ms |
| 14 ms | 294 / 300 | 6 | 58.79 | 13.945 ms |
| 16 ms | 300 / 300 | 0 | 60.00 | 15.947 ms |

At 16 ms lead, all 300 frames presented at exactly 60.00 Hz with no missed
refresh intervals. Decode p95 was 0.304 ms, but the decoded-surface callback
did not mean the Intel implicit fence was ready for scanout. With less lead,
i915 deferred some tear-free flips by one refresh. This direct path removes
Mutter from the measurement yet establishes the same practical boundary: the
current fixed-refresh HDMI chain needs approximately one refresh of lead. It
passes the direct-KMS 60 Hz gate at 16 ms and fails the separate 8 ms latency
gate. Meeting 8 ms tear-free requires a presentation path with VRR or another
mechanism that can latch completed frames between fixed vblanks.

## Controlled-Loss Decode Continuity

Two 600-frame real-content host runs omitted complete access unit 180. The
reference-invalidation stream called `NvEncInvalidateRefFrames()` for timestamp
180 two frames later and contained no recovery IDR. The emergency stream skipped
reference invalidation and forced an IDR with VPS/SPS/PPS at source frame 182;
after the omitted picture, it appears as output packet 181. Both host runs kept
zero deadline misses and passed the capture-to-bitstream p99 robustness gate.

The NUC decoded all 599 remaining pictures through `vah265dec` to Y410 VA
surfaces. Reference invalidation reached 244.99 fps and forced IDR reached
245.79 fps. This proves exact loss injection, recovery action, bitstream
structure, and Intel hardware-decoder continuity.

The invalidation vector was then compared against its synchronized 600-frame
no-loss vector after Intel hardware decode and Y410 download. All 179 frames
before the omission were SHA-256 identical. Only source frame 181 differed
after access unit 180 was omitted; exact decoded-pixel identity resumed
permanently at source frame 182. The measured two-frame healing interval passes
the 120-frame bound and proves that invalidation removes persistent decoder
corruption, not merely that decoding continues.

```text
reference_sha256=5685110f93444b94a6e9b853e20551ef3434a56595665a78e331fbfae823d019
invalidation_sha256=1532bf8b3e53b6793f55ef13218feb11ddbd1a7bc173056db7d1cb648545e4d9
forced_idr_sha256=3c5adf5295c08b0bbe33b4b23f47bcf1111b3a00bf71e6b8be7afb1e8a5a4026
```

```bash
./scripts/test/probe-intel-recovery-decode.sh \
  plank-recovery-ref-invalidate.hevc \
  plank-recovery-forced-idr.hevc \
  599 181

./scripts/test/probe-intel-recovery-pixels.sh \
  plank-recovery-ref-invalidate-reference.hevc \
  plank-recovery-ref-invalidate.hevc 180 600 120
```

## Live Transport FEC

The fullscreen Flame loop was streamed at 3840x2160x60, 100 Mbps requested,
HEVC Rext 10-bit 4:4:4 identity GBR. Moonlight now reports cumulative recovered
FEC blocks, recovered data shards, failed blocks, and wholly missing frames.
Sunshine's qualification-only
`SUNSHINE_QUALIFICATION_DISABLE_UDP_GSO=1` switch selects its existing
`sendmmsg()` fallback so the `netdev` egress hook sees individual datagrams.
The switch is never a production default.

| Loss profile | Host FEC | Dropped datagrams | Recovered blocks/shards | Failed blocks/frames | Client result |
| --- | ---: | ---: | ---: | ---: | --- |
| 5% random, 50 s | 20% | 16,252 | 2,343 / 13,462 | 0 / 0 | 60.02 fps, no drops |
| 10% random, 50 s | 20% | 33,807 | 2,398 / 27,880 | 16 / 16 | 59.42 fps, 1.47% loss; bounded IDR recovery |
| 10% random, 50 s | 30% | 26,823 | 1,987 / 20,577 | 0 / 0 | 60.01 fps, no drops |
| 10% random, 155 s | 30% | 127,982 | 9,130 / 97,906 | 5 / 5 | 59.94 fps decode; five RFI recoveries, no decoder-driven IDR |
| Three 20 ms outages | 20% | time-bounded | 0 / 0 | 0 / 15 | 59.63 fps, 0.77% loss; bounded IDR recovery |

The shorter runs had zero jitter and exact pacer totals `0/0/0`. The sustained
run recorded 0.11% jitter loss and pacer totals `0/9/3`; it remained close to
60 fps after recovery. The 30% profile substantially reduces the 10% random-loss
tail but reduces encoder payload from about 79 to 69 Mbps to retain the requested
media-plus-FEC ceiling. Keep 20% for clean or moderate-loss links; select 30%
for sustained high loss. Run a random profile concurrently with the client using:

```bash
SUNSHINE_QUALIFICATION_DISABLE_UDP_GSO=1 sunshine ...
./scripts/test/inject-live-video-loss.sh 192.0.2.250 10 50 enp1s0
```

The remaining packet-loss gate is synchronized decoded-pixel comparison after
FEC or reference invalidation; frame continuity alone cannot prove clean
post-recovery pixels.

### FEC payload identity

A release client with `LC_DEBUG` enabled for moonlight-common-c exercised its
built-in FEC validation mode for one complete 170-second fullscreen loop. For
every protected block, the client retained one original data shard, removed it
from the Reed–Solomon input, reconstructed it, and compared every recovered
byte with the retained source before submitting that packet to the normal
depacketizer and Intel VA-API decoder.

The run validated 9,992 blocks and 9,992 reconstructed data shards with no
assertion or byte mismatch. Input, decode, and render all sustained 59.99 fps;
network, jitter, and pacer drops remained zero, decode averaged 0.34 ms, and
host-processing p95 was 27.6 ms. This closes FEC compressed-payload identity
on the real sequence: the decoder consumed the byte-identical recovered stream
throughout. Direct decoded-pixel comparison remains required for healing after
reference invalidation, where the post-loss stream intentionally differs from
the no-loss reference.

Build the validation client without enabling Qt's unrelated GUI assertions:

```bash
qmake6 .. CONFIG+=release DEFINES+=LC_DEBUG
make -j"$(nproc)"
```

### Extended-block recovery correction

A second validation combined the real fullscreen loop, negotiated 16-block FEC,
30% parity, and 10% random datagram loss. It exposed an inherited reconstruction
TODO: Sunshine generated parity before fully normalizing `multiFecBlocks`, while
Moonlight restored only the legacy two-bit field. A recovered shard could
therefore carry stale block metadata and make a later block look like block 0.
Sunshine now initializes the complete field before Reed–Solomon generation, and
Moonlight deterministically restores both extended block fields after recovery.

The corrected validation client survived 129,146 dropped datagrams, byte-checked
9,737 reconstructed blocks, and reported no mismatch, decoder error, or
decoder-driven IDR. Its deliberate extra one-shard loss produced 51 failed
blocks and 48 post-invalidation frames while sustaining 59.40 fps. The normal
release repeat dropped 127,982 datagrams, recovered 9,130 blocks and 97,906 data
shards, and had only five unrecoverable frames. All five healed through
reference invalidation; decode sustained 59.94 fps, render sustained 59.87 fps,
and the client issued no emergency IDR after startup. The loss rule was removed
automatically after each run.

After restoring the production-default FFmpeg-backed `nvenc` encoder, a final
170-second no-loss regression covered the complete 3,583-frame source loop. The
client sustained exactly 60.00 fps at input, decode, and render with zero
network, jitter, FEC, or pacer drops. Decode averaged 0.34 ms, frame-queue delay
0.70 ms, render including V-sync 4.73 ms, and host-processing p95 was 29.2 ms.
The client reported `8-bit-source/up-converted`, `10-bit HEVC 4:4:4`, and
`10-bit RGB identity` for the three precision stages.

## Scaled Dual-Monitor Span — 2026-08-21

The authenticated topology endpoint reported the 5120x2160 X11 desktop as
3840x2160 `DP-2` plus 1280x2160 `DP-1`. With one 3840x2160 NUC display, the
client negotiated protocol version 1, feature flags `0xf`, and
`scDisplayMode=scaled-span`; it sent no physical-output ID. NvFBC captured the
complete 5120x2160 screen. CUDA scaled it to 3840x1620 at offset `+0+270` in a
3840x2160 encoded frame, preserving aspect ratio and adding black bars without
changing Xorg or the host monitor layout. This makes Flame and its scopes
simultaneously visible. Raw Wacom reports remain unchanged, while normalized
absolute input uses the same content rectangle.

A 149-second real Flame-loop run delivered 8,936 10-bit H.264 4:4:4 frames.
The FFmpeg 9 client received and decoded 59.96 fps, rendered 59.91 fps, and lost
no frames to the network. Software decode averaged 7.00 ms; queueing averaged
0.86 ms and rendering including V-sync averaged 5.64 ms. Six render catch-up
drops and one queue-overflow drop occurred during startup, followed by one
render catch-up event at 21 seconds; aggregate jitter loss was 0.08%.

Host CUDA conversion averaged 5.43 ms with 7.66 ms p95. Direct x264 completion
averaged 9.75 ms with 11.99 ms p95 and only one sample above 16.67 ms. The
display-to-packet measurement was 23.65 ms average and 31.73 ms p95 because it
also includes waiting for the next captured refresh. Scaled spanning therefore
passes sustained 60 fps throughput, but it does not close the separate
end-to-end latency or startup-drop gates. GPU scaling before readback is already
active for this 10-bit path; further headroom work should concentrate on the
software decode path and bounded capture/encode overlap.

The initial span build used CUDA point sampling and produced visibly poor
downscaling. The 10-bit software-CUDA path now selects linear texture sampling
only when the capture and encoded dimensions differ, retaining point sampling
for one-to-one capture. Live inspection confirmed substantially better span
quality; a 20-second sample showed about 7% GPU SM utilization.

Raw-HID tablet coordinates and pressure were correct across the span. Flame's
Tablet Margins initially changed a stale RGS virtual tablet instead of the
redirected Intuos. Removing the still-running RGS sender left only the exact
UHID Wacom interfaces; Flame then applied its 5% area directly to the Intuos,
and live testing confirmed that adjustable margins work without a watcher or
PLANK-side margin emulation.

The bilinear implementation then completed a 7-minute real-content run. It
received and decoded 59.98 fps and rendered 59.93 fps with zero network loss.
CUDA conversion p95 was 7.38 ms, x264 completion p95 was 12.31 ms, pinned GPU
readback p95 was 4.03 ms, and depth expansion p95 was 3.69 ms. Eleven of 25,667
x264 completions exceeded 16.67 ms. The client decode, queue, and render means
were 7.44, 2.15, and 5.97 ms. Pacer totals were `0/16/2`, concentrated at
startup with occasional later render catch-up; this preserves the 60 fps
throughput result but leaves startup and presentation-tail work open.

## Topology Generation and Disconnect Safety — 2026-08-21

Protocol v1 feature flags now equal `0x1f`; bit `0x10` binds a launch and active
capture to the topology generation returned by the authenticated endpoint. A
live scaled-span launch sent that generation explicitly. Changing only the X11
primary flag from `DP-2` to `DP-1` changed the generation, ended the stream
within the one-second polling bound, and removed Pen, Eraser, Pad, and Finger
from XInput. Restoring `DP-2` preserved the original 5120x2160 geometry.

A deterministic launch race changed the primary flag after the client's
topology fetch but before `/launch`. The host returned 409 without consuming
the PAM session. Moonlight fetched the new generation, retried exactly once,
started video successfully, and consumed the one-use token only after success.
Restoring the original primary flag ended this second bound stream and again
removed all four virtual Wacom devices. Graceful tablet disconnect and a
separate forced Moonlight `SIGKILL` also left no raw client descriptors or host
UHID/XInput devices. Seamless hot-plug remapping remains future work; the
current behavior deliberately fails closed and requires fresh authentication.

## Client-Native Stream Resolution — 2026-08-21

Moonlight commit `d543d89b` removes the PLANK-only hardcoded
3840x2160 assignment. After SDL video initialization, the client now matches
the Qt UI to its physical display, requests that display's native safe-area
resolution, and aspect-fits resolutions above the currently qualified
3840x2160 software-decode ceiling. Both axes are kept even for consistent host
scaling and presentation. If display detection fails, the qualified 4K mode is
the fallback.

Moonlight commit `1e8b9a41` refines this policy for matching high-resolution
displays. In automatic mode, if the physical client display exactly matches
the selected host canvas, the client requests that resolution without the 4K
fit. This avoids a host downscale followed by a client upscale; for example,
a 5120x2160 client viewing the 5120x2160 scaled host span remains pixel-for-
pixel. Non-matching displays, detection failures, and explicit overrides keep
the qualified 3840x2160 ceiling. Display discovery and custom-resolution UI
retain the upstream 8192x8192 safety limit.

The Qt selection suite passes ten cases, including an exact 5120x2160 match,
a non-matching 5120x2160 display, and an explicit over-4K override. A live
5120x2160 run remains required because native resolution increases the current
H.264 software-decoder workload.

On the Raptor Lake development NUC, replacing `intel-media-va-driver` with
the matching `intel-media-va-driver-non-free` 26.1.2 build did not add H.264
High 10 or High 4:4:4 decode profiles. Both variants expose H.264 constrained
baseline, main, and high only, while HEVC Main 4:4:4 10 remains available.
The package uses the non-free driver so the qualified appliance receives the
full codec implementation. This does not change the H.264 result: the current
H.264 High 10 4:4:4 identity stream still requires FFmpeg software decoding.

Auto selection is enabled by default. A saved preference can disable it and
use the existing width/height setting as an explicit override; an automatic
session does not overwrite that saved resolution. The NUC currently reports
3840x2160 at 59.98 Hz, so its selected stream remains 3840x2160 at the integer
60 fps protocol rate.

The pure selection tests passed all seven cases under Qt 5.15 on Rocky and Qt
6.10 on Ubuntu, including native, explicit, over-4K, ultrawide, and detection
failure behavior. The full FFmpeg 9 client rebuilt successfully, started under
the live user service, and was regenerated into a byte-reproducible DEB from a
clean worktree. A fresh authenticated scaled-span session and Wacom check at a
non-4K override remain the next live validation.

The subsequent direct-connect build authenticated from password-on-stdin,
selected the native 3840x2160 mode, launched Desktop without a chooser, and
consumed the one-use token. Its process metadata contained only the host and
username. Both generic unmapped-gamepad warning paths were removed because the
raw Wacom pen and pad intentionally are not SDL game controllers. Diagnostic
SDL logging remains available, but it no longer produces a user-facing modal.

That live run initially exposed a regression. Scaled-span delivered only 56.50
fps over 168 seconds, and a single-output A/B produced essentially the same
56.31 fps. Both modes visibly stalled Flame on the physical host despite zero
network loss, ruling out span scaling and client presentation.

The cause was synchronous output-topology enumeration added to the capture
callback once per second. NVIDIA/X11 enumeration blocked physical presentation
and the NvFBC capture cadence. The topology generation is now checked once at
launch, where a mismatch returns `409` and makes the client refresh and retry;
the capture hot path does not poll stable monitor state. With scene-cut 40,
16 slices, and all other codec settings unchanged, a 193-second single-output
rerun received/decoded 59.95 fps and rendered 59.91 fps. Capture-start p99/max
fell from 106.4/118.8 ms to 16.9/20.4 ms, packet cadence max fell from 125.7 ms
to 34.7 ms, and x264 completion was 12.36 ms p95 with no frame over 16.67 ms.
The user confirmed that physical Flame playback no longer stuttered.

## Per-Workstation Display Preference — 2026-08-21

Scaled desktop span is the default whenever an authenticated host reports more
than one output and supports spanning. The workstation tile context menu now
provides **Display…**, which offers the scaled span followed by each physical
monitor, with the primary monitor listed first. The selection is saved per host
and applied to the next connection; changing it does not alter the active
stream or the host's Xorg layout.

Moonlight caches the last authenticated topology so the menu remains available
after a client restart. A host without cached topology asks the user to connect
once before choosing a display. The Qt topology tests cover serialization and
confirm that an empty preference selects scaled span. On the NUC, a restart
restored the 5120x2160 span and both DP-2/DP-1 choices, and a fresh launch sent
`scDisplayMode=scaled-span` without a physical-output ID.

## Adaptive A/V Correction Prototype — 2026-08-21

The FFmpeg 9 client test build ran a 6 minute 35 second 3840x2160p60
scaled-span session with video-master adaptive audio resampling. After the
180-second acquisition/warmup interval, the final 211.546-second window passed
the 20 ms drift and 20 ms/hour fitted-drift gates: endpoint relative drift was
`5.751 ms`, fitted projection was `-6.310 ms/hour`, and the raw audio clock was
`-290.035 ms/hour`. Correction settled at 84–87 ppm, with zero skipped audio
blocks and a bounded SDL playback queue. The required two-hour soak remains.

Synchronized `plank-client 0.1.0-0.5` and
`plank-host 0.1.0-0.5.el9` packages were then installed. A fresh
installed-client launch authenticated, selected scaled-span at 3840x2160p60,
negotiated the 10-bit H.264 4:4:4 identity path, started adaptive audio
correction, consumed its one-use token, and initialized input. Host `libinput`
reported the forwarded Intuos Pro M pen, pad, and finger devices with tablet,
tablet-pad, pointer, and gesture capabilities. The client user service was
restored after the smoke test.

The synchronized 0.6 follow-up replaced PLANK's inherited 30 ms
decoded-audio drop guard with bounded resampler catch-up. Its 7,303.019-second
post-warmup run skipped no audio and kept the queue bounded, but accumulated
relative drift reached 26.430 ms despite a passing 12.264 ms/hour fitted rate.
This isolated the remaining problem to phase convergence. A phase-feedback
prototype then ended a 1,002.066-second measurement at 1.308 ms relative drift
and 12.579 ms/hour fitted drift with zero skips. The full synchronized 0.7
two-hour repeat remains required.

## End-User NUC Thermal Diagnosis — 2026-08-22

Read-only inspection of the fresh NUC13ANKi7 while receiving the native
5120x2160p60 stream found no unexplained background load. PLANK's
Moonlight process averaged about 249% CPU over five seconds. Work was
concentrated in `PacerRender`, three `Session Exec` threads, and `FFDecoder`,
while the 16-logical-CPU system remained about 82% idle overall. This explains
why aggregate load appeared low despite several sustained busy cores.

The CPU package measured 74--84 degrees C at approximately 27--29 W, and the
fan increased from about 3,900 to 4,200 RPM. The Intel GPU remained near idle
at 300 MHz and roughly 0.35 W. Client logs confirmed that the H.264 High 4:4:4
Predictive 10-bit GBR-identity stream could not use Intel VA-API or Vulkan
hardware decoding and fell back to FFmpeg software decode as `gbrp10le`.
The observed fan behavior therefore matches CPU decode, presentation, and
pacing of roughly 664 million output pixels per second; no memory pressure,
thermal-throttling warning, or runaway auxiliary process was found.

One real client reconnect occurred during the inspection. Host logs showed the
graphical session move from the user desktop to the GDM greeter and then to a
new user session during login/logout. The supervisor replaced the display
worker at each handoff and the client reconnected successfully. This was not a
recurring decoder failure and does not explain the sustained thermal load.
No configuration was changed on the production-workflow NUC. A future A/B at
3840x2160 would reduce pixel workload by 25% and isolate the cost of native
5120-wide software decoding.
