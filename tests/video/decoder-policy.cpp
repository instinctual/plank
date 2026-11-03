#include "video/decoderpolicy.h"
#include "plank_encoding_profiles.h"

#include <cassert>
#include <cstring>
#include <iostream>

int main()
{
    // Every selectable profile, including NVENC H.264 and both Apple HEVC
    // profiles, follows codec policy rather than the Host encoder backend.
    for (int index = 0; index < PLANK_ENCODING_COUNT; ++index) {
        const auto* profile = plank_encoding_profile(index);
        assert(profile);
        assert(plankSoftwareDecodingAllowed(profile->video_format) ==
               (std::strcmp(profile->codec, "h264") == 0));
    }
    assert(plankSoftwareDecodingAllowed(VIDEO_FORMAT_H264));
    assert(!plankSoftwareDecodingAllowed(VIDEO_FORMAT_H265));
    assert(!plankSoftwareDecodingAllowed(0));
    assert(!plankSoftwareDecodingAllowed(VIDEO_FORMAT_H264 | VIDEO_FORMAT_H265));
    std::cout << "client_decoder_codec_policy=pass\n";
}
