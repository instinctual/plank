// SPDX-License-Identifier: GPL-3.0-or-later
#include "microphonecaptureclock.h"
#include "microphonecapturequeue.h"
#include <limits>
#include <cassert>
#include <cstdio>
int main() {
    // Buffer stayed queued for 30 ms before our callback: use its cycle time,
    // and subtract the graph's 20 ms capture latency plus 10 ms resampling.
    assert(plankMicrophoneCaptureTime(1000000000, 960, 1, 48000, 480, 1030000000) == 970000000);
    assert(plankMicrophoneCaptureTime(1000000000, 960, 1, 48000, 480, 1090000000) == 970000000);
    assert(plankMicrophoneCaptureTime(1000000000, -10, 1, 48000, 0, 1000000000) == 1000000000);
    assert(!plankMicrophoneCaptureTime(0, 0, 1, 48000, 0, 1000000000));
    assert(!plankMicrophoneCaptureTime(1000000001, 0, 1, 48000, 0, 1000000000));
    assert(!plankMicrophoneCaptureTime(1000000000, 0, 1, 48000, 0, 1200000000));
    assert(!plankMicrophoneCaptureTime(1000000000, 0, 0, 48000, 0, 1000000000));
    assert(!plankMicrophoneCaptureTime(1000000000, 0, 1, 0, 0, 1000000000));
    assert(!plankMicrophoneCaptureTime(1000000000, INT64_MAX, 1, 48000, 0, 1000000000));
    assert(!plankMicrophoneCaptureTime(1000000000, 0, 1, 48000, UINT64_MAX, 1000000000));
    // Exercise the production packetizer with graph quanta that split packets.
    PlankMicrophoneCaptureQueue queue;
    float input[2880 * 2];
    for (unsigned i = 0; i < 2880; i++) { input[i * 2] = 0.25f; input[i * 2 + 1] = -0.75f; }
    PlankMicrophoneCaptureQueue::Packet packet;
    assert(queue.append(input, 240, 1000000000, 1040000000));
    assert(!queue.take(packet, 1040000000));
    assert(queue.append(input, 240, 1005000000, 1045000000));
    assert(queue.take(packet, 1045000000));
    assert(packet.sampleTime == 0 && packet.captureTimeNs == 1000000000);
    for (unsigned i = 0; i < 480; i++) assert(packet.samples[i * 2] == 0.25f && packet.samples[i * 2 + 1] == -0.75f);
    assert(!queue.take(packet, 1045000000));
    assert(queue.append(input, 240, 1010000000, 1050000000));
    // A source discontinuity discards the unfinished packet and keeps a gap in
    // sequence numbers, allowing both codecs to reset before the next packet.
    assert(queue.append(input, 480, 1040000000, 1080000000));
    assert(queue.take(packet, 1080000000));
    assert(packet.sampleTime == 960 && packet.captureTimeNs == 1040000000);
    assert(queue.append(input, 480, 1050000000, 1090000000));
    assert(!queue.take(packet, 1190000000)); // exactly 100 ms old
    assert(queue.append(input, 240, 1060000000, 1190000000));
    assert(!queue.take(packet, 1290000000)); // stale partial discarded too
    assert(queue.append(input, 480, 1065000000, 1290000000));
    assert(queue.take(packet, 1290000000) && packet.captureTimeNs == 1065000000);
    assert(queue.append(input, 2880, 1075000000, 1290000000));
    assert(queue.append(input, 480, 1135000000, 1290000000));
    unsigned count = 0;
    while (queue.take(packet, 1290000000)) count++;
    assert(count == 6); // overflow always keeps bounded newest packets
    input[1] = std::numeric_limits<float>::quiet_NaN();
    assert(!queue.append(input, 480, 1145000000, 1290000000));
    assert(!queue.take(packet, 1290000000));
    puts("Client microphone queue: split packets, stereo, source gaps, expiry and bounds passed");
    puts("Client microphone clock: cycle timestamp, capture/resampler delay, late callback and invalid timing passed");
}
