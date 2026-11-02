/* Exercise the shared C/Objective-C catalog, also compiled as C++. */
#include "plank_encoding_profiles.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>

int main(void) {
    assert(PLANK_ENCODING_COUNT == 9);
    assert(!plank_encoding_profile(-1) && !plank_encoding_profile(INT_MAX));
    assert(!plank_encoding_profile_named(NULL) && !plank_encoding_profile_named("hevc-8-420"));
    assert(!plank_capture_name(-1) && !plank_capture_name(PLANK_SOURCE_COUNT));
    const int formats[] = {0x8, 0x2, 0x4, 0x10, 0x4, 0x400, 0x800, 0x200, 0x800};
    const int captures[] = {3, 1, 1, 1, 1, 1, 3, 4, 4};
    for (int id = 0; id < PLANK_ENCODING_COUNT; ++id) {
        const PlankEncodingProfile* p = plank_encoding_profile(id);
        assert(p->id == id && plank_encoding_profile_named(p->mode) == p);
        assert(p->video_format == formats[id]);
        for (int source = -1; source <= PLANK_SOURCE_COUNT; ++source)
            assert(!!plank_encoding_supports_capture(p, source) ==
                (source >= 0 && source < PLANK_SOURCE_COUNT && (captures[id] & (1 << source)) != 0));
        assert(!plank_encoding_explicit_dimensions(p, 0, 2160));
        assert(plank_encoding_explicit_dimensions(p, 3840, 2160));
        assert(plank_encoding_explicit_dimensions(p, 5120, 2160) == (id != 4));
        if (p->encoder == PLANK_ENCODER_APPLE) {
            assert(!p->rgb_identity && p->bit_depth == 10 && !strcmp(p->matrix, "bt709"));
            assert(!plank_encoding_explicit_dimensions(p, 1919, 1080));
        } else if (!strcmp(p->chroma, "4:4:4")) {
            assert(p->rgb_identity && !strcmp(p->matrix, "identity"));
        }
    }
    puts("encoding catalog: stable IDs/tuples, exact format, capture masks, dimensions and color policy pass");
}
