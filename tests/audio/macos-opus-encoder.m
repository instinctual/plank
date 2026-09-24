// SPDX-License-Identifier: GPL-3.0-or-later
// Generated PCM only; exercises the production encoder with no capture/devices.
#import "opus-encoder.h"
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <unistd.h>
#include <fcntl.h>

static unsigned checks;
static unsigned frequencies[2] = {440, 880};
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #x); exit(1); } ++checks; } while (0)
static CMSampleBufferRef sample(unsigned start, unsigned frames, BOOL planar, CMTime pts, BOOL invalid) {
    AudioStreamBasicDescription format = {0};
    format.mFormatID = kAudioFormatLinearPCM; format.mSampleRate = 48000;
    format.mChannelsPerFrame = 2; format.mBitsPerChannel = 32; format.mFramesPerPacket = 1;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
        (planar ? kAudioFormatFlagIsNonInterleaved : 0);
    format.mBytesPerFrame = format.mBytesPerPacket = planar ? 4 : 8;
    CMAudioFormatDescriptionRef description = NULL;
    CHECK(!CMAudioFormatDescriptionCreate(NULL, &format, 0, NULL, 0, NULL, NULL, &description));
    NSMutableData *data = [NSMutableData dataWithLength:frames * 2 * sizeof(float)];
    float *values = data.mutableBytes;
    for (unsigned f = 0; f < frames; ++f) for (unsigned c = 0; c < 2; ++c)
        values[planar ? c * frames + f : f * 2 + c] = 0.25f * sinf(2 * M_PI * frequencies[c] * (start + f) / 48000);
    if (invalid) values[0] = NAN;
    CMBlockBufferRef block = NULL;
    CHECK(!CMBlockBufferCreateWithMemoryBlock(NULL, NULL, data.length, NULL, NULL, 0, data.length, 0, &block));
    CHECK(!CMBlockBufferReplaceDataBytes(data.bytes, block, 0, data.length));
    CMSampleBufferRef result = NULL;
    CHECK(!CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, block, description, frames, pts, NULL, &result));
    CFRelease(block); CFRelease(description);
    return result;
}
static void append32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {value, value >> 8, value >> 16, value >> 24}; [data appendBytes:bytes length:4];
}
int main(int argc, const char **argv) {
    if (argc != 2 && !(argc == 3 && !strcmp(argv[2], "--tone-1000"))) return 2;
    if (argc == 3) frequencies[0] = frequencies[1] = 1000;
    alarm(20);
    @autoreleasepool {
        NSMutableData *reference = nil;
        for (unsigned mode = 0; mode < 6; ++mode) {
            NSMutableData *fixture = [NSMutableData dataWithBytes:"PAO1" length:4];
            append32(fixture, 48000); append32(fixture, 2); append32(fixture, 240);
            __block unsigned packets = 0;
            __block int64_t offset = 0;
            __block BOOL pendingJump = NO;
            __block unsigned markedPackets = 0;
            PLANKMacOpusEncoder *encoder = [[PLANKMacOpusEncoder alloc] initWithOutput:^BOOL(NSData *packet, CMTime pts, BOOL discontinuity) {
                // 10 s source origin minus Apple's independently known 312-frame
                // priming, then exact 5-ms increments. No arrival-time synthesis.
                CHECK(CMTimeCompare(pts, CMTimeMake(480000 - 312 + packets * 240 + offset, 48000)) == 0);
                CHECK(discontinuity == pendingJump);
                if (discontinuity) ++markedPackets;
                pendingJump = NO;
                append32(fixture, (uint32_t)packet.length); [fixture appendData:packet]; ++packets;
                return YES;
            }];
            unsigned supplied = 0, chunk = 0;
            unsigned sizes[] = {1, 127, 511, 32, 240, 1000, 17, 960, 333};
            while (supplied < 96000) {
                // Include the short interleaved blocks observed from the
                // virtual-output tap as well as the earlier capture quantum.
                unsigned frames = mode == 4 ? 180 : mode == 5 ? 512 :
                    mode >= 2 ? sizes[chunk++ % 9] : 960;
                frames = MIN(frames, 96000 - supplied);
                if (mode == 3 && supplied) {
                    // Repeated forward/backward 96-ms jumps, whole-sample
                    // changes and a large 10-second jump. The first two occur
                    // before even one packet exists, exercising pending state.
                    int64_t jump = chunk == 2 ? 4608 : chunk == 3 ? -4608 :
                        chunk == 7 ? 480000 : chunk == 9 ? -480000 :
                        chunk % 11 == 0 ? 1 : chunk % 13 == 0 ? -1 : 0;
                    if (jump) { offset += jump; pendingJump = YES; }
                }
                CMTime pts = CMTimeMake(480000 + supplied + offset, 48000);
                if (mode == 2) {
                    pts = CMTimeConvertScale(pts, 1000000000, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
                    // Reproduce the observed ~one-M4-clock-tick SCK offset.
                    // This must not change packet PTS or grow the tolerance to
                    // mistake representation error for a source-clock jump.
                    if (supplied) pts.value += 41;
                }
                CMSampleBufferRef input = sample(supplied, frames, mode > 0 && mode < 4, pts, NO);
                BOOL encoded = [encoder encodeSample:input];
                if (!encoded) {
                    const AudioStreamBasicDescription *f = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(input));
                    fprintf(stderr, "mode=%u supplied=%u chunk_frames=%u output_packets=%u prime=%u rate=%.0f flags=%u framebytes=%u packetbytes=%u framesperpacket=%u samples=%ld\n", mode, supplied, frames, packets, encoder.primingFrames, f->mSampleRate, (unsigned)f->mFormatFlags, (unsigned)f->mBytesPerFrame, (unsigned)f->mBytesPerPacket, (unsigned)f->mFramesPerPacket, (long)CMSampleBufferGetNumSamples(input));
                }
                CHECK(encoded); CFRelease(input); supplied += frames;
            }
            CHECK(encoder.primingFrames == 312 && packets == 400);
            CHECK(mode == 3 ? markedPackets > 10 : markedPackets == 0);
            [encoder stop]; [encoder stop];
            CHECK(![encoder encodeSample:NULL] && packets == 400); // no EOF flush
            if (!reference) reference = fixture;
            else CHECK([fixture isEqual:reference]);
        }
        // Malformed source and sink failure still latch, even at a re-anchor.
        for (unsigned failure = 0; failure < 6; ++failure) {
            __block unsigned packets = 0;
            PLANKMacOpusEncoder *encoder = [[PLANKMacOpusEncoder alloc] initWithOutput:^BOOL(NSData *packet, CMTime pts, BOOL discontinuity) {
                (void)packet; (void)pts; (void)discontinuity; ++packets; return failure != 5;
            }];
            CMSampleBufferRef first = sample(0, 17, YES, CMTimeMake(10, 1), NO);
            CHECK([encoder encodeSample:first] && packets == 0); CFRelease(first);
            unsigned frames = failure == 4 ? 8193 : 960;
            CMTime time = CMTimeMake(480017 + 4608, 48000);
            CMSampleBufferRef bad = sample(17, frames, failure != 2, time, failure == 3);
            if (failure == 1) CMSampleBufferInvalidate(bad);
            CHECK(![encoder encodeSample:failure == 0 ? NULL : bad]); CFRelease(bad);
            unsigned before = packets;
            CMSampleBufferRef good = sample(17, 960, YES, CMTimeMake(480017, 48000), NO);
            CHECK(![encoder encodeSample:good] && packets == before); CFRelease(good);
        }
        int fd = open(argv[1], O_WRONLY | O_CREAT | O_EXCL, 0600); CHECK(fd >= 0);
        const uint8_t *bytes = reference.bytes; size_t remaining = reference.length;
        while (remaining) { ssize_t done = write(fd, bytes, remaining); CHECK(done > 0); bytes += done; remaining -= done; }
        CHECK(!close(fd));
        printf("macos_opus_encoder=pass checks=%u packets=400 planar_interleaved_uneven_identical=1 interleaved_180_512_identical=1 signed_jumps_byte_identical=1 invalid_stop_latched=1 no_eof_flush=1 priming_frames=312\n", checks);
    }
}
