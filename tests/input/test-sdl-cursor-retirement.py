#!/usr/bin/env python3
"""Compile the actual SDL retirement function with deterministic seat fixtures.

No compositor, device, installed SDL override or production test hooks. This
proves which surface the pinned source touches, not the caller of a field crash.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

PREFIX = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#include <wayland-util.h>
typedef struct { int images_per_frame; struct { void* buffer; } images[1]; } Images;
typedef struct SDL_CursorData {
    bool is_system_cursor; int num_frames; void* frame_durations_ms;
    union { Images custom; struct { struct wl_list cursor_buffer_cache; } system; } cursor_data;
} SDL_CursorData;
typedef struct { struct wl_list node; } Wayland_CachedSystemCursor;
typedef struct { SDL_CursorData* current_cursor; void* surface; unsigned stopped; } CursorState;
typedef struct { struct wl_list link; CursorState cursor_state; } SDL_WaylandPenTool;
typedef struct {
    struct wl_list link;
    struct { CursorState cursor_state; } pointer;
    struct { struct wl_list tool_list; } tablet;
} SDL_WaylandSeat;
typedef struct { struct wl_list seat_list; } SDL_VideoData;
typedef struct { SDL_VideoData* internal; } SDL_VideoDevice;
static SDL_VideoData video;
static SDL_VideoDevice device = { &video };
static void* detached[8];
static unsigned count;
static SDL_VideoDevice* SDL_GetVideoDevice(void) { return &device; }
static void Wayland_CursorStateDestroyFrameCallback(CursorState* state) { ++state->stopped; }
static void wl_surface_attach(void* surface, void* buffer, int x, int y) {
    assert(surface && !buffer && !x && !y && count < 8);
    detached[count++] = surface;
}
static void wl_buffer_destroy(void* buffer) { (void)buffer; }
#define SDL_free free
'''

SUFFIX = r'''
int main(void) {
    for (int pointerPresent = 0; pointerPresent <= 1; ++pointerPresent) {
      for (int pointerUsesCursor = 0; pointerUsesCursor <= 1; ++pointerUsesCursor) {
       for (int system = 0; system <= 1; ++system) {
        int pointerSurface, tabletSurface;
        SDL_CursorData cursor = {0}, other = {0};
        cursor.is_system_cursor = system;
        if (system) wl_list_init(&cursor.cursor_data.system.cursor_buffer_cache);
        SDL_WaylandSeat seat = {0};
        SDL_WaylandPenTool tool = {0}, unrelated = {0};
        wl_list_init(&video.seat_list);
        wl_list_insert(&video.seat_list, &seat.link);
        wl_list_init(&seat.tablet.tool_list);
        wl_list_insert(&seat.tablet.tool_list, &tool.link);
        wl_list_insert(&seat.tablet.tool_list, &unrelated.link);
        seat.pointer.cursor_state.surface = pointerPresent ? &pointerSurface : NULL;
        seat.pointer.cursor_state.current_cursor = pointerUsesCursor ? &cursor : &other;
        tool.cursor_state.surface = &tabletSurface;
        tool.cursor_state.current_cursor = &cursor;
        unrelated.cursor_state.current_cursor = &other;
        count = 0;
        Wayland_FreeCursorData(&cursor);
        assert(tool.cursor_state.current_cursor == NULL && tool.cursor_state.stopped == 1);
        assert(unrelated.cursor_state.current_cursor == &other && !unrelated.cursor_state.stopped);
        assert(seat.pointer.cursor_state.current_cursor == (pointerUsesCursor ? NULL : &other));
        assert(count == (system ? 0u : 1u + (pointerPresent && pointerUsesCursor)));
        if (!system) assert(detached[count - 1] == &tabletSurface);
       }
      }
    }
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    source = (args.source / 'src/video/wayland/SDL_waylandmouse.c').read_text()
    start = source.index('static void Wayland_FreeCursorData(SDL_CursorData *d)')
    end = source.index('\nstatic void Wayland_FreeCursor(', start)
    with tempfile.TemporaryDirectory(prefix='plank-sdl-retirement-') as tmp:
        fixture = Path(tmp) / 'test.c'
        fixture.write_text(PREFIX + source[start:end] + SUFFIX)
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True).split()
        binary = Path(tmp) / 'test'
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        str(fixture), '-o', str(binary), *flags], check=True)
        subprocess.run([str(binary)], check=True, timeout=10)
    print('SDL production cursor retirement: 8 independent mouse/tablet cases passed')


if __name__ == '__main__':
    main()
