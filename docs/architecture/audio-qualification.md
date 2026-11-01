# Audio Qualification

Current desktop Clients use native PipeWire playback on Ubuntu and Core Audio
playback on macOS. Opus travels over the negotiated Kyber audio lane. The
shared audio clock and bounded resampling controls preserve synchronization;
there is no SDL playback queue or inherited audio Reed-Solomon transport.
Hosted callback/lifecycle tests do not replace real-output listening, device
switching or a long synchronized audio/video soak. See the
[Client removal plan](../development/plans/client-no-sdl.plan) for pending gates.

The dated results below describe earlier implementations. Their queue and
transport observations remain historical evidence, not claims about the current
Client. The telemetry command is maintained for current logs.

## Historical baseline — August 2026

The baseline streamed coupled stereo Opus at 48 kHz using
`OPUS_APPLICATION_RESTRICTED_LOWDELAY`. The high-quality stereo target is
512 kbps total for both channels, not 512 kbps per channel. At that time,
inherited audio Reed-Solomon recovery was separate from video FEC.

## End-to-End Delivery Gate

With a PLANK session active, run the non-destructive loopback gate
from the repository root:

```bash
PLANK_SSH_KNOWN_HOSTS=/path/to/known_hosts \
  ./scripts/test/run-audio-loopback-qualification.sh user@client
```

The runner resolves the client's default PipeWire sink, records that sink's
monitor, and injects a low-level 997 Hz tone into the host Sunshine sink. It
passes when the returned target band is at least 6 dB above a 3 kHz control
band. Pass a numeric PipeWire sink ID as the second argument when testing a
non-default output. WAV captures and metric files are written under
`artifacts/qualification/audio/` and excluded from Git.

Two live `hardware-test-host` to Intel NUC runs on 2026-08-21 passed with 11.70 dB and
13.60 dB target-to-control deltas. The second run used the restarted,
identity-bound session. They confirmed this path:

```text
host session sink -> Sunshine capture -> Opus/RTP -> Moonlight decode
                  -> PipeWire HDMI sink
```

The NUC opened a 720-sample stereo output buffer at 48 kHz, corresponding to
15 ms of audio per callback.

The restarted stream also passed the Stage A same-user ownership gate:
Sunshine, authenticated account `operator`, and the selected PLANK PAM
session all resolved to UID `540600009`. This proves the permitted live
path; automated host tests cover rejection and cleanup for a UID mismatch.

## Clock-Drift Telemetry

Launch the client from a terminal with
`PLANK_AV_SYNC_TELEMETRY=1 plank-client`, then begin a new
stream. This diagnostic-only process environment switch is not an
administrator policy. PLANK then logs audio media time with the native playback
queue/device latency and video media time at presentation about once per
second. Collect the persistent client log and analyze it from the repository
root:

```bash
./scripts/test/analyze-av-sync-telemetry.py client.log \
  --warmup-seconds 180 --min-duration-seconds 7200 \
  --max-skipped-audio-blocks 0
```

The analyzer reports p95 clock jitter, corrected and raw audio clock rates,
the long-term and backlog-correction ranges, skipped audio blocks, accumulated
relative A/V drift, and a least-squares drift fit across the measurement window.
Its one-hour projection uses the fitted slope; a separately labeled endpoint
projection is retained to expose short-window noise. Optional
`--max-relative-drift-ms` and
`--max-projected-relative-drift-ms-per-hour` arguments turn those metrics into
explicit gates. The analyzer normalizes the streams' independent starting
epochs, so it does not claim absolute lip-sync offset. A synchronized
flash/tone source and client-side event detector remain necessary for that
measurement.

### Packaged baseline result

A changing-content scaled-span run with synchronized 0.3 packages failed the
relative-clock gate after 1,307.501 seconds. Raw relative drift reached
`-44.544 ms`; the least-squares fit projected `-95.947 ms/hour`. Audio and
video jitter p95 were 10 ms and 14 ms. The client reported no audio packet
loss, queue overflow, decrypt failure, or renderer reinitialization, and its
packet and SDL playback queues remained bounded.

The individual fits localized the mismatch to the audio delivery clock
(`-100.809 ms/hour`) rather than video (`-4.862 ms/hour`). This telemetry uses
decoded 5 ms audio-frame progress and renderer queue estimates; it proves the
two client media clocks are not held together, but it does not measure
absolute acoustic-to-photonic offset. The unchanged two-hour run was stopped
once it exceeded both 20 ms gates. Phase 7 now requires video-master audio
correction before repeating the soak.

### Adaptive-correction prototype

A 6 minute 35 second live scaled-span run on 2026-08-21 qualified the first
bounded video-master prototype. After a 180 second warmup, the 211.546 second
measurement window projected `-6.310 ms/hour` fitted relative drift and ended
at `5.751 ms` relative drift. The uncorrected audio clock still measured
`-290.035 ms/hour`, while adaptive resampling settled between 84 and 87 ppm.
No audio blocks were skipped and the SDL queue remained bounded. This passes
the 20 ms and 20 ms/hour development gates, but it is not the required two-hour
soak or synchronized flash/tone offset measurement.

The first installed 0.5-package soak reproduced a separate inherited failure
at 7 minutes 42 seconds. Moonlight's generic 30 ms input-queue guard discarded
three decoded 5 ms blocks after a short scheduling burst, despite no packet
loss, decoder error, or connection failure. Dropping decoded audio violates the
zero-skip gate even though it immediately reduces queued latency.

Client 0.6 keeps that generic behavior outside PLANK sessions. A
PLANK stream instead applies bounded resampler catch-up above a 15 ms
input-queue target, limited to 10,000 ppm with 1,000 ppm update slew, and keeps
a 100 ms emergency ceiling. A real-content run activated 1,000 ppm catch-up,
returned to zero, and crossed the earlier failure point without skipping a
block. Unit tests cover the inactive, capped, and drained states.

The installed 0.6 run completed 7,303.019 seconds after warmup with zero audio
skips. Backlog correction peaked at 1,000 ppm and returned to zero. Audio/video
jitter p95 was 5/16 ms, and the fitted relative rate passed at 12.264 ms/hour,
but accumulated relative drift reached 26.430 ms and failed the 20 ms gate.
The individual fits showed corrected audio at 1.122 ms/hour and video at
-11.142 ms/hour. Rate correction alone therefore could not remove accumulated
phase error.

The follow-up controller adds slow phase feedback from actually submitted audio
frames with a 30-minute convergence horizon; the existing 250 ppm rate bound,
2 ppm update slew, and separate backlog recovery remain unchanged. A simulated
two-hour mismatch stays within 20 ms. A 20-minute real-content prototype then
measured 1.308 ms endpoint drift and 12.579 ms/hour fitted drift over its
1,002.066-second post-warmup window, with zero skips. This passes the development
gate; synchronized 0.7 packages still require the full two-hour repeat.

### Current handoff — 2026-08-22

- The canonical integration repository is now
  `https://github.com/instinctual/plank`. Do not publish PLANK
  changes to `instinctual/plankOS`; that repository is unrelated.
  Local `main` tracks `origin/main`, and `plank/wacom-raw-hid` tracks
  the matching branch on the new repository.
- Client phase commit `2404550e` and root phase commit `b39d621` are pushed.
- Synchronized 0.7 packages were built and installed on both targets:
  `plank-host-0.1.0-0.7.el9.x86_64` on hardware-test-host and
  `plank-client 0.1.0-0.7` on the NUC. The client package records
  Moonlight commit `2404550e` and bundles the private FFmpeg 9.0.1 runtime.
  Both package manifests passed. Artifact SHA-256 values are
  `40d3b4e2281ca64015de00d51ce3a2ee056bf002d1de29151a585de44104876a`
  for the RPM and
  `4e77835058d5d84afeee6607c6d351634493f28f4cc9f3833c7ddd806db3f747`
  for the DEB.
- The 0.7 host and client services were restarted and active. Client startup
  selected Intel VA-API decoding through FFmpeg 9.0.1 and decoded the HEVC Main
  10 stream. The host user service initially lacked `DISPLAY` and `XAUTHORITY`
  after reboot; importing `DISPLAY=:1` and
  `XAUTHORITY=/run/user/540600009/gdm/Xauthority` restored it. The PAM broker
  remained active.
- hardware-test-host was left at GDM with no `operator` graphical session and no Flame process.
  Consequently, authentication, scaled-span, Wacom, and real-footage smoke
  checks were not repeated, and the soak was deliberately not started. No
  screen inhibitor or temporary blanking override was installed.
- The packaged 0.6 soak log is
  `~/plank-avsync-soak-0.6.log` on the NUC. The
  phase-prototype log is `plank-avsync-phase-test.log` in the same
  directory.
- When an operator is on site, log into hardware-test-host, start the full-screen changing
  Flame loop, and smoke-test authentication, scaled-span, Wacom pressure and
  margins, video, and audio. Then run the 125-minute 0.7 soak with 180 seconds
  warmup and the 7,200-second minimum-duration gate.
- Pass criteria remain at most 20 ms endpoint drift, at most 20 ms/hour fitted
  drift, and zero skipped audio blocks. Afterward, restore normal screen-blanking
  policy and confirm both packaged services are active.

## Remaining Phase 7 Gates

This tone test proves routing and decoded sample delivery; it does not prove
A/V synchronization. Before Phase 7 is complete:

- live-qualify the Stage A PAM-account/desktop-owner launch gate and reject
  cross-user audio access;
- measure audio offset against the video presentation clock, including p95 and
  p99 jitter;
- verify packet-loss recovery and bounded jitter-buffer behavior;
- run a two-hour changing-content test of bounded video-master correction with
  no audible glitches, skipped audio blocks, or accumulating A/V drift;
- measure a synchronized flash/tone source to establish absolute offset; and
- repeat disconnect and session-switch cleanup after the corrected soak.
