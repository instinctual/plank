// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>
#include "../audio-device/microphone-format.h"

// RFC 6716 TOC validation before native decoder entry: exactly 480 samples,
// stereo, <=1275 bytes. No duration/allocation controlled by the incoming packet.
static inline bool PLANKMicOpusPacketValid(const uint8_t *data, size_t size) {
    if (!data || !size || size > 1275 || !(data[0] & 4)) return false;
    unsigned frames = data[0] & 3;
    frames = frames == 0 ? 1 : frames < 3 ? 2 : size >= 2 ? data[1] & 63 : 0;
    unsigned samples;
    if (data[0] & 128) samples = 120u << ((data[0] >> 3) & 3);
    else if ((data[0] & 96) == 96) samples = data[0] & 8 ? 960 : 480;
    else { unsigned n = (data[0] >> 3) & 3; samples = n == 3 ? 2880 : 480u << n; }
    return frames && frames * samples == 480;
}
typedef struct {
    const uint8_t *data;
    UInt32 size;
    bool supplied;
    AudioStreamPacketDescription description;
} PLANKMicOpusInput;
static inline OSStatus PLANKMicOpusProvide(AudioConverterRef converter, UInt32 *packets,
    AudioBufferList *data, AudioStreamPacketDescription **description, void *context) {
    (void)converter;
    PLANKMicOpusInput *input = context;
    data->mNumberBuffers = 1;
    if (input->supplied) { *packets = 0; return -7777; }
    input->supplied = true; *packets = 1;
    data->mBuffers[0] = (AudioBuffer){PLANKMicChannels, input->size, (void *)input->data};
    input->description = (AudioStreamPacketDescription){0, 480, input->size};
    if (description) *description = &input->description;
    return noErr;
}
typedef struct { AudioConverterRef converter; bool priming; } PLANKMicDecoder;
static inline bool PLANKMicDecoderCreate(PLANKMicDecoder *decoder) {
    if (!decoder) return false;
    memset(decoder, 0, sizeof(*decoder));
    AudioStreamBasicDescription input = {0}, output = {0};
    input.mSampleRate = 48000; input.mFormatID = kAudioFormatOpus;
    input.mFramesPerPacket = 480; input.mChannelsPerFrame = PLANKMicChannels;
    output.mSampleRate = 48000; output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    output.mFramesPerPacket = 1; output.mChannelsPerFrame = PLANKMicChannels; output.mBitsPerChannel = 32;
    output.mBytesPerFrame = output.mBytesPerPacket = PLANKMicChannels * sizeof(float);
    decoder->priming = true;
    return AudioConverterNew(&input, &output, &decoder->converter) == noErr;
}
static inline bool PLANKMicDecoderReset(PLANKMicDecoder *decoder) {
    if (!decoder || !decoder->converter) return false;
    decoder->priming = true;
    return AudioConverterReset(decoder->converter) == noErr;
}
static inline void PLANKMicDecoderDestroy(PLANKMicDecoder *decoder) {
    if (decoder && decoder->converter) { AudioConverterDispose(decoder->converter); decoder->converter = NULL; }
}
static inline bool PLANKMicDecode(PLANKMicDecoder *decoder, const uint8_t *data, size_t size,
                                  float samples[PLANKMicPacketFrames * PLANKMicChannels]) {
    if (!decoder || !decoder->converter || !samples || !PLANKMicOpusPacketValid(data, size)) return false;
    PLANKMicOpusInput input = {data, (UInt32)size, false, {0}};
    AudioBufferList output = {0}; output.mNumberBuffers = 1;
    output.mBuffers[0] = (AudioBuffer){PLANKMicChannels, 480 * PLANKMicChannels * sizeof(float), samples};
    UInt32 frames = 480;
    OSStatus status = AudioConverterFillComplexBuffer(decoder->converter, PLANKMicOpusProvide, &input, &frames, &output, NULL);
    if ((status && status != -7777) || !input.supplied || !frames || frames > 480 ||
        (!decoder->priming && frames != 480) || output.mBuffers[0].mDataByteSize != frames*PLANKMicChannels*sizeof(float)) return false;
    // Apple's packet decoder withholds its initial lookahead. Preserve the fixed
    // live timeline with startup silence instead of asking for another packet
    // (which would add a packet of latency). Only the first decode may be short.
    if (frames < 480) {
        memmove(samples + (480 - frames)*PLANKMicChannels, samples, frames*PLANKMicChannels*sizeof(float));
        memset(samples, 0, (480-frames)*PLANKMicChannels*sizeof(float));
    }
    decoder->priming = false;
    for (unsigned i = 0; i < 480 * PLANKMicChannels; i++) if (!isfinite(samples[i])) return false;
    return true;
}
