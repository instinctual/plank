# macOS sender-drain measurement

This is a historical experiment record. Source-first video FEC is now the
shared sender for all platforms. The old two-archive Mac-only comparison
script and feature switches have been removed. Use the release build runbook
and `scripts/test/run-plank-transport-native-loopback.sh` for current gates.

## Latest: .53 source-first FEC candidate

### Live comparison collected after user disconnect

The .53 test ended 01:21:27 local time. Full Host run: 12,898 captures,
1 pre-encode skip, no encoder/recovery/send drops, 12,895 video frames and
46,436 audio packets sent; no video-queue evictions or audio-send drops.
Two-minute bounded Host sender trace: 6,869 frames, 58 keys, mean key submission
24.379 ms versus 26.208 ms in .51. Key bytes decreased 1,062,620 → 993,594;
this is not a byte-identical workload or proof of faster submission per byte.
Key matrix/repair preparation means 5.841/0.708 → 2.971/0.168 ms, while Quinn
calls mean 18.749 → 20.084 ms. Stage scheduling differs with the new ordering;
these are elapsed wall times, not isolated CPU or mutex-wait measurements.

The Client log hit its 10 MiB cap because both tests ran in the same Client
process. .53 receive trace is complete; render trace stops at 105.12 seconds,
24,031 of 27,407 rows. Decode trace/final transport statistics are absent.
The complete-trace parser correctly refuses this file. A separate inspection
validated the receive begin/end/count and used only the recorded render prefix
for an equal 5–100 second comparison, without manufacturing a trace end.

| Measurement | .51 Host / .52 Client | .53 Host / .52 Client |
| --- | ---: | ---: |
| Mean key receive gap, seconds 5–100 | 44.332 ms | 36.867 ms |
| Render catch-up drops, seconds 5–100 | 23 | 10 |
| Of those within 200 ms after key receive | 22 | 10 |
| Overflow drops, seconds 5–100 | 0 | 0 |
| Missing frame sequence IDs in full 120-second receive trace | 5 | 0 |
| Mean key receive gap, seconds 5–120 | 43.772 ms | 35.950 ms |
| Mean gaps across first three frames after keys, seconds 5–120 | 7.386 ms | 9.800 ms |

GPU waits and render durations remain similar in the matched interval; new
mean/max GPU waits 6.850/32.391 ms, render 4.536/22.163 ms. Complete receive
does not mean there was no packet loss: FEC could have recovered lost sources.
The truncated file prevents a full-run Client loss/audio/decode result.

This is directional improvement, with remaining post-key render catch-up.
Footage/encode timing and payload sizes differed, so do not attribute the whole
gain to the sender change. The next live trace requires quitting/relaunching
the Client to obtain a fresh product log before one two-minute session. Keep
the existing log cap and Client playback policy unchanged. Raw log hashes and
paths are in HANDOFF. No code or runtime settings changed during this analysis.

### Implementation and synthetic qualification

The user selected reducing keyframe processing/submission delay before Client
render-policy changes. In the .51/.52 run, keyframes averaged 1,062,620 bytes
and 26.208 ms submission, versus 101,328 bytes and 3.289 ms for deltas. That
ratio alone is not abnormal per-byte work. The avoidable dependency is preparing
all RaptorQ repairs before submitting any systematic source packet.

The .53 macOS-only experiment sends originals first, then computes/sends the
same library repair packets. OTI, IDs, padding, repair count, wire layout, MTU,
queue limits and .51 rate/window policy remain unchanged. Default builds/Linux
retain their prior path. No Client, capture or encoder change.

Tests compare originals byte-for-byte with RaptorQ 1.8.1 across single/multiple
blocks, sub-block partitions, alignment and padding. Reconstruction passes at
0/5/10/20% deliberately omitted source packets with unchanged repairs. This
is not 20% loss over both source and repair traffic or a WAN loss matrix.

On the Mac, synthetic 1,100,123-byte CPU preparation averages 1.903 ms before
any packet was ready in the baseline; source-first originals are ready at
0.081 ms, total preparation 1.911 ms. These are isolated preparation timings,
not the larger preparation times observed concurrently with live capture.

`scripts/test/test-macos-source-first.sh` compares the retained .51 archive to .53
through genuine QUIC/C ABI send/complete-receive, synthetic 1,100,123-byte
keyframes, 20 alternating independent connections each. All byte/counter
checks pass. Excluding the first two warm-up pairs, baseline mean 7.022 ms,
candidate 5.115 ms; medians 7.023/5.123 ms (~27% sooner). This includes receiving
and reconstructing the original payload, not encoding, decoding or display.
Both endpoints run on the same Mac; it does not qualify WAN stutter or sustained
video/audio load. Total FEC work still occurs before the next frame can be sent.

Build/sign/install gates and exact provenance are in HANDOFF. .53 is installed
on the dedicated Mac; existing Client .52 remains the live trace tool. Next
compare the same two-video workload, complete-receive gaps and following-frame
bursts, sender totals/evictions, receiver loss and render drops. Do not declare
the visible stutter fixed from a loopback improvement alone.

## Earlier .50 measurement

September 8, 2026. Diagnostic Host1.0.50-macos-host; exact source and binary
provenance in HANDOFF. User played two browser-video windows at5120x2160,
unchanged50Mbps encoder target/100Mbps peak. Capture/encoder settings match .48.
No pacing, FEC, queue-size or Client changes in this measurement.

## Observations

First120seconds began00:01:23 local time. Sender trace contains6618 completed
submissions,181 keyframes, and116 cumulative queue evictions at its final
dequeue. The full session ended00:03:59:8997 complete captures,1 pre-encode skip,
zero VideoToolbox drops,320 recovery-or-send drops,132 actual transport queue
evictions,8675 sent video frames,31292 audio packets and zero audio-send drops.
Recovery-or-send drops include deliberate dependent-frame suppression; do not
interpret320 as320 transport evictions or network packet losses.

| Average keyframe sender stage | Elapsed ms |
| --- | ---: |
| Copy, RaptorQ initialization and repair generation | 6.08 |
| Pacer reservation/wait, including scheduling delay | 60.29 |
| Quinn synchronous datagram submission calls | 14.01 |
| Remaining framing/control/dispatch work | 1.12 |
| Total after dequeue | 81.50 |

Average keyframe size928216bytes. Its average pre-dequeue residence was11.25ms
(separate from the above), and capture trace mean key encoding time22.16ms.
Sender-wide pacer elapsed accounts for70.78% of time inside submissions.

Frame4189 is a concrete causal sequence:

- Encoded1,601,896byte sample in25.819ms; packaged Annex-B frame1,601,981bytes.
- Dequeued with an empty pending queue and only0.018ms residence.
- RaptorQ/framing produced1628 datagrams totaling2,126,168bytes.
- Sender processing took139.354ms:8.574ms FEC preparation,101.769ms pacer,
  26.964ms Quinn calls, and the remaining small framing/control overhead.
- Next dequeued frame was4192, with86.8ms residence and3 other frames pending.
  Cumulative queue evictions rose74→76 while4189 drained:4190/4191 were lost
  locally before transmission. The recovery key4196 subsequently took130.105ms.

## Interpretation and limits

The encoder is not dropping output in this run. Large normal keyframes expose
the single-frame-at-a-time sender's drain-time mismatch with its four-frame
pending queue. At60fps four frames represent roughly67ms of arrivals; a125–139ms
drain readily exceeds that capacity. This supports a sender-side cause of the
observed stalls, not an inference that the Internet path itself is saturated.

Every traced frame used a136,000,000bps software budget, derived from the
configured100Mbps peak times1.35 plus1Mbps. This is not a measurement of available
link capacity. Frame4189's datagram bytes alone require125.069ms at that rate,
before FEC processing. Across keyframes the mean nominal serialization is72.51ms
versus81.50ms measured total; mean per-frame ratio1.122. Timer refinement alone
cannot eliminate that configured serialization budget.

Timers do warrant attention:34574 sleeps requested only1.342s in aggregate,
while total pacer elapsed was39.882s (roughly39us requested and1.15ms pacer
elapsed per sleep). But pacer elapsed includes reservations and scheduler delay;
the burst allowance and virtual timeline interact with wakeups. Do NOT call the
whole difference avoidable wasted time or assume a30x throughput improvement
from a more precise timer. Likewise Quinn call time includes locking and actual
submission, not exclusively contention. These are elapsed wall times, not CPU,
ACK or wire-delivery times. Instrumentation overhead was not independently
benchmarked; no synchronous per-frame log output occurred during playback.

## Original proposal after .50 (superseded by authorized .51 experiment)

Keep encoder settings, Client, FEC policy and queue capacity unchanged. Test a
bounded sender burst budget that can drain a keyframe promptly while retaining
longer-term rate limits and network backpressure. Validate receiver loss and
latency rather than merely moving the backlog into Quinn or kernel buffers.
Do not remove pacing entirely, enlarge latency queues, switch congestion
controllers, or resume low-latency encoder changes on the strength of this trace.
Any shared transport policy change also needs Linux regression qualification.

Raw numeric log is retained outside Git at
`~/.cache/plank-build/work/host-sender-1.0.50.log`.
Reproduce with `scripts/test/analyze-sender-timing.py` and
`scripts/test/analyze-macos-frame-timing.py`. Align by frame number; capture sample
sizes omit Annex-B parameter-set additions included in sender payload sizes.

## Combined fast-send result: .51

The user explicitly authorized removing our application datagram pacer and
raising the Quinn window budget together. Exact build and feature scope are in
HANDOFF. User reports fewer stutters, but still unacceptable stutter. No further
code or runtime settings were changed during this analysis.

| First 120-second sender trace | .50 | .51 |
| --- | ---: | ---: |
| Queue evictions at last dequeue | 116 | 0 |
| Mean keyframe submission time | 81.50 ms | 24.69 ms |
| Mean keyframe queue residence | 11.25 ms | 0.028 ms |
| Mean keyframe payload | 928 KB | 1204 KB |
| Mean keyframe encode time | 22.16 ms | 22.41 ms |

The workloads are not pixel-identical. .51 delivered about50.04Mbps encoded
payload versus48.34Mbps previously. .51 traced6890 sender frames/58keys,
zero failed submissions, zero pacing sleeps, and zero queue evictions. Full
Host session:6955 complete captures,5 pre-encode skips,0 encoder drops,
0 recovery/send drops,6949 video sent,24204 audio sent,0 audio-send drops.
Worst submission was53.37ms for a delta frame;51.24ms fell inside one Quinn
call, coinciding with a capture callback stall. This is elapsed time, not proof
of a particular lock or an on-wire stall. Keys averaged7.87ms FEC preparation
and16.10ms Quinn calls. Capture callback gaps reached88.39ms; output-handler
dispatch delay reached79.54ms. PTS gaps include304 at33.33ms and1 at50ms, giving
roughly57.45 complete captures/sec despite a requested60fps.

wan-test-client Client1.0.45 log for this connection:6374 video frames received,
0 receive drops,0 KyProto drops,544292 FEC source symbols and0 missing source
symbols. Reported network/decode/render57.42/57.42/56.97fps; VA-API Main10/P010
hardware decoding; decode completion p95/p99/max1/1/35ms. Frame queue drops:
41 render catch-up plus9 startup overflow, reported0.79%. Render-call latency
p95/p99/max6/10/189ms; the maximum is not timestamped and may include startup.
QUIC-lost546 is also reported: this is the Client endpoint's outbound QUIC loss
counter, not evidence of missing incoming video source symbols. Do not claim
the entire network had zero loss. Host continued until00:23:59 after Client
disconnected00:23:49; raw frame totals cover different lifetimes, so their
difference is not a lost-frame count.

The recurring render catch-up drops closely follow normal120-frame keyframes:

| Keyframe submission completed (Host local time) | Client render catch-up |
| --- | --- |
| 00:22:00.979 | 00:22:01.019 |
| 00:22:03.152 | 00:22:03.179 |
| 00:22:05.240 | 00:22:05.275 |
| 00:22:07.317 | 00:22:07.359 |

This temporal alignment supports a keyframe delivery burst followed by Client
render catch-up as the remaining periodic mechanism. It does not isolate QUIC
wire delivery, FEC reconstruction, decoder output batching and render scheduling
from one another. Frame pacing logs as disabled; the render queue's independent
catch-up policy still runs in `Pacer::renderFrame()` and discards frames over a
history-derived depth, even with recorded ages6–19ms. Do not remove bounded
queues or assert that this policy alone is defective without tracing arrivals.

Next focus: keyframe receive/reconstruction, decoded-frame arrival, and render
queue policy, while retaining .51 as the experimental comparison. Further
sender budget increases are not justified by the now-zero sender queue drops.
Raw Host log: `~/.cache/plank-build/work/host-sender-1.0.51.log`, SHA-256
`918716eb0cc6957fea625dc2f328d12e105293df3159f00a236425800e286ec8`.

## Client receive-to-render code investigation

Reviewed after checkpoint c94f4f5 was pushed. Installed Client source remains
34e6f974; no Client policy modification or new package is part of this review.

1. The native sender emits a reliable KyProto config/group marker before each
   keyframe, then sends the complete media object through RaptorQ datagrams.
   KyProto requires that marker before releasing a group's media. Its missing
   sequence timeout is conditional, not a fixed50ms delay applied to every
   healthy frame. Group-marker arrival and object reconstruction are possible
   batching boundaries; existing logs do not time them separately.
2. Root `receive_video()` immediately enqueues each complete media packet and
   wakes the Client receive thread. `plankTransportVideoReceiveLoop()` submits
   complete frames immediately to `LiSubmitPlankVideoFrame()`. The receive API's
   50ms timeout is a wait-until-available limit, not a per-frame sleep.
3. The assembler queues valid keyframes normally. Normal contiguous keyframes
   do not automatically flush/restart the FFmpeg decoder. Hardware output is
   passed to the render queue with preserved presentation timestamps, but
   `pkt_dts` is repurposed as local decode-completion time for queue-age logging.
   A dropped frame's6ms logged age therefore does NOT prove6ms total latency.
4. `Pacer::renderFrame()` renders one frame, then immediately trims pending
   frames to a history-derived target:2 if the queue was recently empty,
   otherwise0 (or1 for the NO_BUFFERING renderer path). A transient depth3
   therefore loses a frame even when it has only just been decoded. Neither
   media PTS nor actual lateness participates in that catch-up decision.
   The hard enqueue cap remains4, independently of this trimming.
5. Pacing-disabled bypasses the extra pacing queue, NOT this render queue.
   EGL waits for the previous GPU fence/swap separately; the recorded renderer
   call time does not include `waitToRender()`. Consequently low average render
   and decode measurements do not rule out burst-related presentation stalls.

The logs and this code support, but do not fully prove, the sequence
keyframe delivery delay → clustered decoded frames → depth-only catch-up drop.
Do not attribute every gap to this policy: source cadence is below60fps and
sporadic Host scheduling stalls are independently measured. Nor does removing
the render limit repair time already spent delivering a complete keyframe.

Corrective direction: distinguish a brief delivery burst from persistent
playout lateness, retaining the existing finite surface/queue bound and prompt
recovery after a real stall. Do not add an unbounded buffer, a universal fixed
jitter delay, or a low local-age exemption alone (which misses upstream delay).
Before choosing thresholds, correlate the same frame number/PTS at complete
receive, decode completion, render dequeue, GPU-wait completion and render/drop.
A bounded Client trace should capture these in one workload, with the .51 Host
unchanged, rather than another series of sender-rate changes. Normal Linux
Host→Client playback, A/V sync, high-refresh output, reconnect and prolonged
stall recovery remain gates for any shared Client policy change.

## Synchronized Client .52 result

User installed .52 and ran the same workload, then disconnected. Received
complete numeric traces:6834 receive rows,6824 decode rows,27205 render events;
no ambiguous millisecond PTS joins or capacity exhaustion. First120seconds of
this run begin around00:45:31 local time. Excluding startup's first5seconds:

- 56keyframes: mean preceding complete-receive gap43.772ms, median43.760ms,
  p9556.702ms, maximum65.903ms. Delta receive gap mean17.341ms.
- Complete-receive→decoded-output mean0.829ms, p951.032ms, maximum5.461ms.
- 27render catch-up drops;26occur within200ms after a keyframe is received.
  Their local decoded-queue ages average13.963ms, maximum19ms.
- GPU-wait mean6.919ms, p9516.194ms, maximum32.501ms. Render-call mean4.487ms,
  p955.491ms, maximum19.786ms. These are CPU-side elapsed intervals, not scanout.

Concrete normal keyframe331:54.947ms gap since the preceding complete receive;
1113876byte payload; decoded4.635ms after receive; rendered from+4.648to+21.052ms.
Following delta332 arrives at+7.978ms,333at+10.102ms,334at+13.272ms. Their decode
delays are0.838/0.869/1.687ms. Render enqueue depth rises1→2→3. Immediately after
key331's render call completes,332 is dropped at+21.059ms with local age12ms,
while333and334 are later rendered. This proves the short burst exists before
decoder output and that depth-only trimming discards a frame from that burst.
It does not prove that the original54.947ms delivery gap can be removed by a
Client queue-policy change. Capture, FEC/QUIC and reliable group marker timing
remain upstream of the Client's complete-receive measurement.

The unchanged .51 sender has zero queue evictions and zero failed submissions
in its120second trace; mean key submission26.208ms, max37.369ms. Full Host:
9574complete captures,0pre-encode/encoder drops,3recovery/send drops,
9569video sent,33594audio sent,0audio-send drops.

Full Client run:9567video received,11receive drops,10KyProto drops,
824335source symbols with88missing;34audio receive drops. Thus this run is NOT
loss-free, unlike .51's previous Client sample. Trace receive sequence gaps
occur around0.273/3.573/3.636/94.232/94.310seconds; their presence must not be
conflated with render-only losses. Final Client frame queue counts40render
catch-up/16overflow; within the trace30catch-up/16overflow, all overflow within
startup's first5seconds. Final network/decode/render56.90/56.90/56.56fps. The
reported after-FEC0.17% still uses the existing frame/hole semantics, not the
uncommitted packet-based telemetry redesign.

Next proposed correction: make render catch-up distinguish brief keyframe
bursts from persistent lateness, keeping the existing finite surface/queue cap
and stall recovery. Do not simply remove drop limits or impose a blanket
playout delay. This can prevent the extra skipped frame, but cannot erase the
preceding complete-frame arrival gap. Preserve this diagnostic baseline for
both smoothness and latency comparison. No further live testing is needed to
establish that the observed short burst predates decoding.

Raw logs retained outside Git:
`~/.cache/plank-build/work/client-frame-flow-1.0.52.log`, SHA-256
`eca279f8aa63fb0c5ec90f633f75051b4a25785d17d1ef91f7b1bfc6c3f24265`;
`~/.cache/plank-build/work/host-sender-client52.log`, SHA-256
`8eae146a2b0621837024988f344d60c447bf183b421ef9bdf1d285e3197931f0`.
The mode0600 diagnostic transfer copy on wan-test-client was removed after hash-verified
collection; the original Client product log remains untouched.

## September 8: bounded submission batching rejected for deployment

After the user disconnected, clean Mac transport builds tested 16-packet (.54)
and four-packet (.55) batches against the installed .53 source-first baseline.
Only already-ready datagrams are grouped under the Quinn connection lock;
there is no collection timer or change to FEC, MTU, encoder or Client. This
experimental feature remains off by default. Host .53 remains installed.

Final functional gates pass: exact packet boundaries/order-independent byte
sets, oversized/closed/disabled errors, accepted-prefix delivery after partial
failure, source-first recovery, Rust tests and ordinary C ABI loopbacks. Early
test errors came from assuming peer-disabled precedence over local-disabled
and dropping the peer connection before its final response reached the reader;
the fixtures were corrected without altering production behavior.

The deployment blocker is performance, plus one unexplained mixed-media failure:

- .54 completed all 20 large-frame comparison pairs with matching video/audio/
  input data. Two alternating control stress pairs nevertheless increased
  maximum reliable-control RTT from 9.143/11.753 ms to 18.393/27.366 ms.
- .55 repeated five stress runs, each two ordinary and two batch connections.
  Each delivered all 4,096 datagrams and 64 reliable control echoes. Maximum
  control RTT was worse in 9 of 10 paired samples; overall maxima were
  15.602 ms ordinary and 23.813 ms batch. Means/p95 were mixed; these are
  per-connection results, not a pooled percentile or real input-latency test.
- .55 large-frame comparison stopped at candidate 10: video completed with
  exact bytes in 5.063 ms, but the following audio check reported
  `native audio packet or metadata mismatch`. No failed datagram submission
  was recorded. Do not claim its planned 20 pairs passed or attribute the
  audio failure to batching without further evidence. Completed warmed pairs
  generally saved only a fraction of a millisecond versus .53.

The direct fairness fixture uses ordinary Quinn on Mac loopback, not the PLANK
rate controller or WAN. The separate 1,100,123-byte C ABI comparison does use
the PLANK transport configuration, but is not continuous capture/playout.
Neither proves actual user-visible latency. Longer control tails and a failed
mixed-media check do not justify deploying this small video gain.

Retained Mac PLANK_WORK_ROOT evidence:

- `datagram-batch-54-bundles/transport-testfix2.log`, SHA-256
  `d7a169163624a2475ccca5907beaa7e9f6c367881c8de24465803c5e1301a216`.
- `datagram-batch-55-bundles/transport-build.log`, SHA-256
  `d0c211e94cd4a25264bc04e9486382f8f3b4616b618914c4fd28e6855025b958`.
- `batch-54-comparison/` (20 complete pairs), `batch-55-comparison/`
  (stops at `candidate-10.log`), `batch-55-control-repeat/trial-1.log` through
  `trial-5.log`. Earlier fixture-failure logs remain for audit.
- .54 root `99b33c508173d69ec87907c69073f0568afd95a1`, Kymux
  `2fe06c11ee6e5c548bae7e468317d389bc2715f5`; .55 root
  `cec281f1bdba8c6640b94abe525a8613dd4cce44`, Kymux
  `d206363ea05757668065ad3fe26ba6b18cc97793`.

Independent capture-cadence observation from retained live traces: .51 capture
PTS gaps average 17.552 ms (median 16.667, p95 33.333, maximum 50.000); .53 gaps
average 17.477 ms (median/p95 16.667, maximum 50.000). Callback-gap means match,
but maxima are 53.683/73.739 ms. Thus the approximately 57 fps rate is present
in captured sample timestamps before networking, not merely in the Client
counter. Determine whether omitted SCK intervals arise from source updates,
callback scheduling or another capture constraint before selecting a fix.
This is distinct from the measured keyframe delivery burst; it does not prove
all visible stutter has one cause. No capture-policy change made here.

## September 8: capture-cadence investigation, no runtime changes

Reanalyzed the existing complete .51/.53 traces after excluding the first five
seconds by capture callback time. No new capture, process restart, installation,
encoder change or OS setting change. Read-only Mac inventory still reports
Host .53 and a 5120x2160 PLANK Desktop at 60.00 Hz, with Safari/WebKit active.
That current inventory is not proof of browser frame rate during older traces.

At .53, 6,579 measured intervals contain 6,267 one-tick, 303 two-tick and nine
three-tick PTS gaps on the 60 Hz grid. Those are 312 gap events / 321 unobserved
60 Hz slots, not 312 network losses. All 6,580 records reached send stage;
no pre-encode or encoder skips occur in this post-startup portion. Only one
gap immediately follows an encoded keyframe. Capture cadence therefore has
an issue separate from the keyframe delivery burst.

The handler checks `SCFrameStatusComplete` before recording. Idle/incomplete
SCK callbacks are not recorded, so an absent slot is NOT by itself proof that
WindowServer lost a changed frame. Nor do encoder-completion timestamps prove
the exact moment the input IOSurface became reusable.

For .53 one-tick PTS intervals, mean callback interval is 17.193 ms (median
17.146), versus the 16.667 ms source grid. Define *relative callback lag* as
`capture_ns - pts_ns - min(capture_ns - pts_ns)` over this trace section. This
removes the arbitrary clock offset; it is NOT absolute display-to-capture
latency. Its average rises to 16.544 ms on frames immediately preceding a PTS
gap, then falls to 5.951 ms on the next captured frame. The normal-interval
corresponding values are 10.048 and 10.574 ms. Individual sequences show gradual
lag accumulation and a reset at a missing PTS tick. .51 shows the same pattern.

Previous-frame encode latency averages 21.718 ms before .53 gaps, versus
20.986 ms otherwise; callback-to-handler delay is 1.135 versus 0.981 ms.
Thus there is no evidence that a huge encoded-output callback stall precedes
every capture gap. Relative PTS-to-encode-completion exceeds 33.333 ms before
292/312 gaps versus 1,768/6,267 normal intervals. That is useful correlation
with surface-pool pressure, not a direct surface-ownership measurement.

Code audit:

- SCK `minimumFrameInterval=1/60` is a maximum-update-rate request, not a
  promise of 60 complete updates every second.
- SCK `queueDepth=3` supplies the minimum surface pool. Hardware encoding
  receives those IOSurface-backed pixel buffers directly; no CPU image copy.
- Capture delivery, synchronous Opus conversion, encoded-output handling and
  lifecycle/control callbacks share the session serial queue. `_inFlight`
  counts submissions until the output handler runs on that queue; it is not
  SCK's number of available surfaces.
- Network FEC/QUIC work is on the transport worker. `sendSample:` converts the
  compressed payload and enqueues it; its handler time must not be equated
  with the separately traced full network submission time.

Apple explicitly describes the surface-pool exhaustion failure mode, the
memory/latency tradeoff, and a five-surface configuration for 4K60 streaming:
[WWDC22: Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/).
The [queueDepth reference](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth)
confirms the default is three and says not to exceed eight. These are documented
SCK semantics; final macOS 27 behavior still needs qualification.

Recommended next bounded experiment: change only SCK surface-pool depth from
three to five, retaining the three-submission in-flight cap, capture rate,
hardware encoder, timestamps, transport .53 and Client .52. This supplies more
reusable capture surfaces, not an intentional wait to fill a five-frame playout
queue; actual latency must nevertheless be compared, not assumed unchanged.
Keep batching disabled. Compare the same moving workload's PTS gaps, receive/
render cadence, latency and audio/input behavior. If ineffective, revert that
single variable and instrument all SCK frame statuses / delivery and submission
durations before changing threads or the minimum interval. Do not claim that
either surface starvation or source/browser cadence has been proved yet.

## .56 live result: five surfaces did not help; reverted

User reported unchanged stutter and approximately57.6fps. The complete Host
trace spans104.55seconds (6,003frames), with10pre-encode skips,0encoder drops,
2recovery/send drops and0video/audio sender queue evictions. In matched5–100s,
capture FPS changes57.232→57.400; .56 retains245two-tick and1three-tick PTS gaps,
versus249and7in .53. Nine .56 pre-encode skips occur in this interval. Bitrate
was changed during the run, triggering encoder replacements; do not attribute
those skips to pool depth or treat this as identical encoding work.

Client receive/decode/render final rates are57.26/57.26/57.16fps. All three trace
lanes are complete, with5,966receive,5,962decode and23,829render records; no
ambiguous PTS joins. Final queue drops2render/8overflow; source-symbol telemetry
68missing of224,783, plus6video receive/5KyProto/17audio drops. Network was not
perfect, but the sustained FPS shortfall already exists in Host capture.

Restored exact installed .53 after confirming no active session, and reset
source queueDepth to3. Failed .56 app remains recoverable; its version number
must not be reused for another binary. HANDOFF records hashes and log paths.
This test weakens the three-surface-pool hypothesis as the dominant cause.
Next useful isolation is SCK without encoding/transport, counting non-complete
statuses too, before changing callback threading, throttling or queue limits.

## Isolated SCK probe: explicit interval versus native delivery

Built a separate metadata-only signed Probe, no Host runtime/encoder/transport
linked. Existing desktop, three SCK surfaces and the production xf20 full-range
SDR/sRGB capture format. Retained no samples and mapped no pixels. Recorded all
statuses/callback/PTS values in bounded memory, flushed after stop.25seconds
after asynchronous start acknowledgement,35second hard process deadline.

After the .53 restore, the virtual display was gone and the Mac had returned to
1920x1080@60Hz. These are not5120x2160 tests. The first four runs on the existing
desktop had numerous idle frames: explicit1/60 yielded38–40 completefps versus
42–44 with interval0. Total callbacks including idle were49–50 versus57–58/sec.
Do not label those total callback rates as usable video FPS. User confirmed the
Mac was not at LoginWindow; console/session and on-screen owners agreed.

Then a nonactivating, input-transparent panel with a Core Animation moving bar
provided continuously changing content. No CPU animation timer, focus/input
event or Host restart. Four alternating tests, excluding first2seconds:

| Minimum interval | Complete fps | Two-tick PTS gaps | Idle frames |
| --- | ---: | ---: | ---: |
| 1/60 | 56.8085 | 79 | 0 |
| 0 (native) | 59.9984 | 0 | 0 |
| 1/60 | 56.5369 | 85 | 0 |
| 0 (native) | 59.9994 | 0 | 0 |

All rows/counts and monotonic PTS validated; every run exited0. Native maximum
PTS gap16.667ms versus33.333ms for explicit throttling. This reproduces the
~57fps symptom without encoder/networking and removes it by changing only the
SCK interval in the controlled probe. It does not establish the framework's
internal scheduling mechanism, qualify high-refresh displays, prove full-stream
latency, or eliminate separately measured keyframe delivery bursts.

Next proposed production test: native SCK interval0 on our60Hz virtual display,
retaining .53 transport, encoder, Client and both existing bounds. No such Host
change is implemented here. Installed .53 and original Probe restored and
SHA/signature verified; temporary panel/launchd jobs gone. See HANDOFF for
source/build provenance and the build runbook for reproduction modes.

Raw pattern logs in both machines' `PLANK_WORK_ROOT/capture-cadence-bundles`:

- `pattern-1.log`: `08ef72f7204e1217c00c3b459956741458e25342261410257f460c9905c928f7`
- `pattern-2.log`: `b13c3be9e485eacbf40ad405c76d94008bc67f5f393a181f4399232695f21d69`
- `pattern-3.log`: `965f2d55019017501b8d1eb141f39f8253ec41cdb2832e47d5b92a2a1494c84e`
- `pattern-4.log`: `9880df439cd3fca85e9309ec16bc41244622233cd845844b4af9de0ef627acde`

## .57 accepted live result and cleanup

User reports the native-cadence Host solved the observed stutter. Its5–70second
capture interval has3,900sent frames with3,899one-tick PTS gaps:60.000fps, versus
the previous~57fps. Full71.216second run has1pre-encode skip,0encoder drops,
3recovery/send drops and0video/audio sender queue evictions. Client final
network/decode/render59.94/59.94/59.65fps,11render/7overflow drops,1video receive
drop and0audio receive drops. These are summary observations, not a new
glass-to-glass latency measurement or a claim of zero frame loss. HANDOFF records
original log hashes and different summary end times.

The failed batching code and extra Quinn wrapper vendor tree are removed from
current source; historical commits/raw results remain. Kymux cleanup tree is
identical to955d58b, preserving source-first FEC; root transport Cargo manifests,
lockfiles and build runner again match7f8af9e. Installed .57 uses the original
.53 archive, with application pacing disabled and the increased Quinn window
budget retained. Shared Linux application pacing is not dormant and was not
deleted. No new runtime change or installation during cleanup.
