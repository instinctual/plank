#!/usr/bin/env python3
"""Check the actual private SDL library without opening devices or a display."""
import ctypes
from pathlib import Path
import sys

library = ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
if library.SDL_GetVersion() != 3_004_018:
    raise SystemExit('Client SDL version is not the qualified 3.4.18')
for kind, required in (('Audio', {'pipewire'}), ('Video', {'wayland', 'x11'})):
    count = getattr(library, 'SDL_GetNum' + kind + 'Drivers')
    driver = getattr(library, 'SDL_Get' + kind + 'Driver')
    driver.argtypes = [ctypes.c_int]
    driver.restype = ctypes.c_char_p
    available = {driver(i).decode('ascii') for i in range(count())}
    if not required <= available:
        raise SystemExit('Client SDL is missing required ' + kind.lower() + ' drivers: ' +
                         ', '.join(sorted(required - available)))
print('client_sdl_runtime_drivers=pass (no hardware session)')
