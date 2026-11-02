/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLANK_ENCODING_PROFILES_H
#define PLANK_ENCODING_PROFILES_H

#include <stddef.h>
#include <string.h>

/* Bookmark IDs and wire values are append-only. This catalog describes product
 * policy, not hardware support: every backend must still qualify the exact
 * requested format at runtime. Keep C/Objective-C and C++ consumers identical. */
enum PlankEncodingBackend { PLANK_ENCODER_X264, PLANK_ENCODER_NVENC, PLANK_ENCODER_APPLE };
enum PlankCapture { PLANK_SOURCE_NVFBC, PLANK_SOURCE_X11, PLANK_SOURCE_SCK, PLANK_SOURCE_COUNT };
enum PlankEncodingId {
    PLANK_ENCODING_H264_10_444, PLANK_ENCODING_H264_8_422,
    PLANK_ENCODING_H264_8_444, PLANK_ENCODING_H264_10_422,
    PLANK_ENCODING_NVENC_H264_8_444, PLANK_ENCODING_NVENC_HEVC_8_444,
    PLANK_ENCODING_NVENC_HEVC_10_444, PLANK_ENCODING_APPLE_HEVC_10_420,
    PLANK_ENCODING_APPLE_HEVC_10_444, PLANK_ENCODING_COUNT
};
typedef struct PlankEncodingProfile {
    int id;
    const char *mode, *backend, *codec, *profile, *chroma, *matrix;
    int encoder, bit_depth, video_format, capture_mask, rgb_identity;
    /* Explicit bookmark modes only. Dynamic desktop geometry has its own
     * canvas limits; these must not constrain Match Client's Retina sizes. */
    int explicit_width_limit, explicit_height_limit, dimension_alignment;
    int default_bitrate_kbps;
} PlankEncodingProfile;

#ifdef __cplusplus
#define PLANK_PROFILE_CONST constexpr
#else
#define PLANK_PROFILE_CONST const
#endif
static PLANK_PROFILE_CONST PlankEncodingProfile plank_encoding_profiles[] = {
    {0, "h264-10-444-software", "software-cuda", "h264", "high444", "4:4:4", "identity", PLANK_ENCODER_X264, 10, 0x0008, 3, 1, 0, 0, 1, 80000},
    {1, "h264-8-422-software", "software-cuda", "h264", "high422", "4:2:2", "bt709", PLANK_ENCODER_X264, 8, 0x0002, 1, 0, 0, 0, 1, 80000},
    {2, "h264-8-444-software", "software-cuda", "h264", "high444", "4:4:4", "identity", PLANK_ENCODER_X264, 8, 0x0004, 1, 1, 0, 0, 1, 80000},
    {3, "h264-10-422-software", "software-cuda", "h264", "high422", "4:2:2", "bt709", PLANK_ENCODER_X264, 10, 0x0010, 1, 0, 0, 0, 1, 80000},
    {4, "h264-8-444-nvenc", "nvenc-direct", "h264", "high444", "4:4:4", "identity", PLANK_ENCODER_NVENC, 8, 0x0004, 1, 1, 4096, 2160, 1, 80000},
    {5, "hevc-8-444-nvenc", "nvenc-direct", "hevc", "rext", "4:4:4", "identity", PLANK_ENCODER_NVENC, 8, 0x0400, 1, 1, 0, 0, 1, 50000},
    {6, "hevc-10-444-nvenc", "nvenc-direct", "hevc", "rext", "4:4:4", "identity", PLANK_ENCODER_NVENC, 10, 0x0800, 3, 1, 0, 0, 1, 50000},
    {7, "hevc-10-420-videotoolbox", "videotoolbox", "hevc", "main10", "4:2:0", "bt709", PLANK_ENCODER_APPLE, 10, 0x0200, 4, 0, 5120, 2160, 2, 50000},
    {8, "hevc-10-444-videotoolbox", "videotoolbox", "hevc", "rext", "4:4:4", "bt709", PLANK_ENCODER_APPLE, 10, 0x0800, 4, 0, 5120, 2160, 2, 50000},
};
#undef PLANK_PROFILE_CONST

static inline const PlankEncodingProfile *plank_encoding_profile(int id) {
    return id >= 0 && id < PLANK_ENCODING_COUNT ? &plank_encoding_profiles[id] : NULL;
}
static inline const PlankEncodingProfile *plank_encoding_profile_named(const char *mode) {
    if (!mode) return NULL;
    for (int i = 0; i < PLANK_ENCODING_COUNT; ++i)
        if (strcmp(mode, plank_encoding_profiles[i].mode) == 0) return &plank_encoding_profiles[i];
    return NULL;
}
static inline const char *plank_capture_name(int capture) {
    static const char *const names[] = {"nvfbc", "x11-native10", "screencapturekit"};
    return capture >= 0 && capture < PLANK_SOURCE_COUNT ? names[capture] : NULL;
}
static inline int plank_encoding_supports_capture(const PlankEncodingProfile *profile, int capture) {
    return profile && capture >= 0 && capture < PLANK_SOURCE_COUNT &&
        (profile->capture_mask & (1 << capture)) != 0;
}
static inline int plank_encoding_explicit_dimensions(const PlankEncodingProfile *profile, int width, int height) {
    return profile && width > 0 && height > 0 &&
        (!profile->explicit_width_limit || width <= profile->explicit_width_limit) &&
        (!profile->explicit_height_limit || height <= profile->explicit_height_limit) &&
        width % profile->dimension_alignment == 0 && height % profile->dimension_alignment == 0;
}
#endif
