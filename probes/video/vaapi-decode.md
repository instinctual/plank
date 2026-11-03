# Isolated Intel VA-API decode comparison

`plank-probe-vaapi-decode` exercises the Ubuntu Client's exact FFmpeg libraries
without Qt, a window, networking, audio or input. It does not install or replace
the Client. Use it only on an authorized idle test machine.

Manually dispatch `build.yml` with `product=linux-client-vaapi-probe` and the
expected `source_sha`. This diagnostic-only job requires an existing verified
Client FFmpeg cache. It neither rebuilds dependencies nor creates a package.
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

A failure without rendering rules out Qt rendering as a necessary trigger for
that clip. It does not distinguish FFmpeg, driver, kernel or bitstream defects.
A passing run is limited to that clip, duration, codec and surface lifecycle;
it does not prove that the full Client or every stream is healthy. Record
whether the clip came from the actual failed stream or a separately encoded
control workload.
