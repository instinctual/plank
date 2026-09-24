# Installed camera and microphone application reader

This standalone reader selects only the production PLANK Camera UUID and PLANK
Microphone UID. It validates application delivery from the installed Host, without
installing another extension or selecting any local physical input. It never
changes default devices or saves media. Use only the authorized development Mac
with macOS27/SDK27 and deployment target27.0. Results and machine paths stay in
the private audit directory.

Build from a clean source checkout into a new output directory:

```sh
bash "$PLANK_SOURCE_ROOT/scripts/test/build-macos-installed-media-consumer.sh" \
  "$PLANK_SOURCE_ROOT" "$PLANK_PROBE_OUTPUT" --adhoc
```

The script runs synthetic ASan/UBSan validation of the reader's sample checks,
compiles with warnings as errors and signs the local app. `--sign` instead uses
the privately supplied `PLANK_MACOS_SIGNING_IDENTITY` Developer ID certificate.
It neither notarizes nor opens a device. This app embeds no extension and needs
no system-extension provisioning profile. Ad hoc signing is a local component
check, not distribution approval or evidence of camera/microphone consent.

Inventory does not start capture:

```sh
reader_app="$PLANK_PROBE_OUTPUT/PLANK Installed Media Reader.app"
reader="$reader_app/Contents/MacOS/installed-media-consumer"
"$reader" --inspect
```

The camera is absent until an authenticated Client session enables forwarding
and the Host accepts its first frame. The microphone may be present and silent
without an active source. Inventory exits zero with explicit presence/format
fields; that exit status is not a streaming pass.

Request normal privacy consent through a deliberate GUI launch for each medium:

```sh
open -n "$reader_app" --args --request-permission camera
open -n "$reader_app" --args --request-permission microphone
```

Approve the actual OS prompts before capture. Capture modes require existing
authorization and report exit3 if it is missing. Do not change TCC, copy another
app's identity, or infer that synthetic probe consent applies to this reader.
Run captures under the same authorized GUI app identity; direct execution is
useful only when macOS attributes it to that already authorized app.

With an ordinary authenticated Ubuntu Client session, selected webcam and
explicitly enabled camera/microphone forwarding, run each reader for2–120 seconds:

```sh
"$reader" --camera native native --seconds 10
"$reader" --camera pixels nv12 --seconds 10
"$reader" --microphone --seconds 10
```

The second camera argument chooses the source format (`native`, `nv12` or
`auto`); the first chooses the application's requested output. Explicit source
selection holds the configuration lock for that bounded capture. To investigate
concurrent consumers, overlap `native auto` and `pixels auto`, in both start
orders, with a microphone reader. Inspect delivered subtypes in every result;
an empty video-output settings dictionary alone does not prove coded delivery.
Concurrent negotiation can change the single device stream's source format.

Camera reports include native H.264/MJPEG versus NV12, dimensions, frame and
byte counts, monotonic presentation span, invalid samples and application drops.
Dimensions and subtype must remain stable. The permissive delivery threshold
(at least5fps and a presentation span of half the requested duration) allows
startup and physical auto-exposure below nominal30fps; sustained rate, frame
freshness and latency are separate gates. This reader does not compare captured
device payloads against received samples and never claims payload equality.

Microphone reports require48kHz interleaved stereo Float32 and finite samples,
and at least90% of the expected frame count. Reports show each channel's RMS,
nonzero samples, differing stereo frames and over-full-scale samples. Diagnostic
energy saturates only at absolute amplitude16 to bound corrupt-input accounting.
Silence and duplicated mono remain valid delivery. They do not qualify audible
forwarding or stereo routing: use controlled independent left/right source tones
to establish channel identity separately. Over-full-scale finite Opus output is
reported separately from malformed nonfinite samples.

Exit0 from capture means those delivery checks passed. No result establishes
source identity, codec payload preservation, color accuracy or A/V synchronization.
The existing native transport and decode probes retain their separate roles.
Repeat the installed matrix for both codecs, concurrent readers, mute/reopen,
disconnect/reconnect and physical unplug/reopen. Store bounded aggregate reports
privately and record unperformed hardware gates explicitly.
