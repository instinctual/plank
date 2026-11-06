# Sender window and delayed acknowledgments

The November 2026 investigation concerns outgoing QUIC datagram eviction during
an established stream. Saved evidence showed a roughly 140KiB in-flight window,
negligible send progress for seconds, and a full 1MiB send queue. The cause of
that live ACK-progress stall remains unproven. It is separate from the excluded
Intel Gen11 GPU-hang investigation.

## Controlled comparison

Hosted run [41738601498](https://github.com/instinctual/plank/actions/runs/41738601498),
source `2ae65baf3cc1386f67cc5c28885d40a97ae8fbb9`, used encrypted Quinn loopback
connections with the actual PLANK controller. A test-only wrapper compared
unchanged behavior against 1MiB and 2MiB minimum windows. Both endpoints retained
fixed 1344-byte UDP payload limits, the same 1Gbps controller budget, and the
same 1MiB send queue. No product sockets or live machines were involved.

Each four-second case submitted 60 frame-sized bursts per second at the stated
video rate plus 30% FEC-equivalent bytes. These are synthetic datagrams, not
encoded video or RaptorQ objects. An independent UDP proxy held all encrypted
return traffic temporarily, in order, with no intentional drops. It does not
inspect or selectively delay encrypted ACK frames. A separate receiver test
paused application reads while the QUIC worker continued acknowledging packets.

| Impairment | Baseline sender drops | 1MiB minimum | 2MiB minimum |
| --- | ---: | ---: | ---: |
| 50Mbps, return traffic held 200ms | 474 | 0 | 0 |
| 150Mbps, return traffic held 100ms | 1,024 | 666 | 0 |
| 50Mbps, return traffic held 1,500ms | 9,288 | 8,568 | 7,715 |
| 50Mbps, application reads paused 250ms | 0 | 0 | 0 |

All cases had zero proxy kernel drops, zero QUIC-declared loss and zero clean
warm-up queue evictions. In the short return-hold cases, the 2MiB window delivered
every submitted datagram; maximum receive gaps were 16ms and 19ms, compared
with 102ms and 56ms for the baseline. After recovery, measured tail latency was
2–5ms in every case and every connection received its final datagram without
reconnecting. These are single-run measurements, not WAN latency guarantees.

The application-pause cases still lost 679/697/679 datagrams respectively at the
receiver. A larger sender window cannot fix a receiver that is not reading.
The final fixture separately accounts for transmitted, arrived, consumed and
sender-evicted datagrams and rejects unexplained loopback loss.

## Candidate policy and limits

The candidate adds a 2MiB minimum in-flight window to the shared Host policy.
It retains the existing rate/RTT-derived window above that floor, 100ms RTT cap,
64-packet minimum, encoder targets, FEC, 1Gbps budget and bounded outgoing queue.
There is no protocol change, new configuration key or Client behavior change.
The comparison-only controller is removed after recording the baseline.

Quinn derives its native pacing from window/RTT. The budget reported by PLANK's
controller metrics is diagnostic, not a separate 1Gbps rate limiter. Raising the
window can also increase burst delivery; live receiver/path capacity must still
be qualified. No application datagram pacer is restored.

The retained `run-plank-transport-stalls.sh` gate requires zero datagram loss
during the two brief return holds. The longer hold must actually overflow the
bounded sender queue, and the application pause must overflow the receiver
queue; both must resume with the same connection, receive the final sequence
and leave no persistent tail backlog. It also rejects unintended proxy/wire
loss, clean-phase overflow and failure to maintain the offered schedule.

Current native KyProto/RaptorQ matrices exercise the shared source-first
implementation on each Host builder, including reliable-data backpressure and
cancellation; the separate platform selection has been removed.
They do not prove reconstruction of the much larger burst losses from the long
ACK hold. Installed video/IDR, audio/input continuity and a sustained WAN soak
remain required on a newly authorized qualified test pair. The protected
production pair and excluded Gen11 Client must remain untouched.

The final production-policy fixture passed in hosted run
[41739851250](https://github.com/instinctual/plank/actions/runs/41739851250),
source `60d72591ce78ef0627541022236477ffd3af97ca`. Both short holds delivered all
27,120/81,360 submitted datagrams with zero send/receive discards; receive gaps
were 17/20ms. The long hold discarded 7,715 outgoing datagrams, while the
application-pause case discarded 679 at the receiver. Accounting found no
unexplained wire loss. All four cases resumed without reconnecting with 3–5ms
maximum measured tail latency. Native FEC matrices passed three times for each
submission path; transport state, datagram accounting, reliable pressure and
cancellation checks also passed. This qualifies the isolated candidate tests,
not the original production incident or installed WAN behavior.
