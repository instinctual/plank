# Isolated Intel VA-API decode comparison

`plank-probe-vaapi-decode` exercises the Ubuntu Client's exact FFmpeg libraries
without Qt, a window, networking, audio or input. It does not install or replace
the Client. Use it only on an authorized idle test machine.

Manually dispatch `build.yml` with `product=linux-client-vaapi-probe`, the
expected `source_sha`, and `diagnostic_ffmpeg_cache` set to the exact cache key
from the installed Client's build log. This diagnostic-only job requires that
existing cache and verifies its receipt and patched source. A newer hosted
compiler does not select a different FFmpeg for this comparison. It neither
rebuilds dependencies nor creates a package; product cache rules are unchanged.
The artifact includes its source revision, binary checksum and library hashes.
Hosted parser/build checks are not hardware acceptance.

Transfer the artifact and an authorized private Annex B HEVC clip separately.
The clip must contain access-unit delimiters, begin at a keyframe, and be no
larger than 256 MiB. Never upload desktop captures as CI fixtures or artifacts.
Compare `LIBRARY-SHA256SUMS` with the installed Client's private libraries before
testing; select that directory with `LD_LIBRARY_PATH`, not the system FFmpeg.

```bash
LD_LIBRARY_PATH="$PLANK_CLIENT_RUNTIME" timeout --signal=TERM --kill-after=5 650 \
  ./plank-probe-vaapi-decode --input "$PLANK_PRIVATE_CLIP" \
  --mode decode --seconds 600 --fps 60 --width 5120 --height 2160
```

The probe requires VA-API, full-range HEVC 10-bit 4:4:4 identity and Y410 storage.
Every decoded surface must complete within the Client's 100 ms bound. The
decoder stays open while the clip repeats at the selected frame rate. No
software/profile fallback or driver setting change is made. The external
deadline is required because decoder submission or teardown can also block
inside a failed driver.

After a successful decode-only run, `--mode export` additionally exports each
surface read-only and retains at most four surface leases. It still does not
import or render those buffers. Compare kernel video-engine/reset messages
over each test interval as well as frame counts and synchronization times.

`--mode sample` adds offscreen GPU sampling through EGL/OpenGL ES on the exact
same DRM render node. It imports Y410 as XR30 with the original DMA-BUF modifier,
draws into a full-size ten-bit target and retains at most three surface leases
until their draw fences complete. It rejects software rendering and reports
skipped sampling draws if that bounded queue fills. No window, Qt, compositor
integration, CPU readback or system configuration change is involved. This tests
decoder/render-engine sharing; it is not full Client presentation or color
qualification. The external deadline remains necessary during GPU teardown.

A failure without rendering rules out Qt rendering as a necessary trigger for
that clip. It does not distinguish FFmpeg, driver, kernel or bitstream defects.
A passing run is limited to that clip, duration, codec and surface lifecycle;
it does not prove that the full Client or every stream is healthy. Record
whether the clip came from the actual failed stream or a separately encoded
control workload.

## Recording the actual decoder input

The same diagnostic artifact contains `libplank-video-record.so`. It is an
explicit temporary `LD_PRELOAD` recorder, never a product dependency. On an
authorized idle test Client, close the existing Client, create a private
directory owned by its desktop user (mode 0700), and launch its ordinary
executable with these two environment variables for that launch only:

```bash
PLANK_VIDEO_RECORD_DIR="$PLANK_PRIVATE_RECORDING" \
LD_PRELOAD="$PLANK_DIAGNOSTIC_DIR/libplank-video-record.so" \
  plank-client
```

Successful HEVC packet submissions are copied unchanged into separate files
per decoder context. Qualification decoders therefore do not contaminate the
live recording. H.264, audio, authentication and other network data are not
recorded. Files are created exclusively with mode 0600; the recorder refuses
a shared directory or a directory owned by another user. Total recording is
bounded by ten minutes and 4 GiB. A write failure disables recording without
changing the decoder's return value. File writes add some timing overhead;
record whether the failure reproduced with the diagnostic enabled.

Close the diagnostic launch before copying or replaying its files. The largest
file normally belongs to the live stream; verify the dimensions/profile during
replay. `plank-probe-vaapi-decode --inspect FILE.pvr` validates the packet framing
without opening a GPU. Use the same `--input` replay command above; the format
is recognized automatically. Replay streams one packet at a time from disk,
retains the original packet boundaries/flags, and repeats from the first packet
when needed. It does not reproduce original arrival timing or Qt presentation.
Malformed/truncated recordings are rejected, not silently repaired.

Recording files contain the remote desktop video. Keep them in private evidence
storage, never the repository or a hosted artifact. Remove the two environment
variables for all ordinary launches; no installed binary/configuration is edited.
