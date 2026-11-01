#!/usr/bin/env python3
"""Reject retired SDL APIs/build inputs in the supported desktop Client."""
import pathlib
import re
import sys


def check(source, probe=None):
    app = source / 'app'
    if probe is None:
        probe = pathlib.Path(__file__).resolve().parents[2] / 'probes/qt-session'
    for directory in (app, source / 'tests', probe):
        for path in directory.rglob('*'):
            if path.suffix not in ('.cpp', '.h', '.mm', '.c', '.pro', '.pri'):
                continue
            text = path.read_text()
            # Historical attribution/prose is fine; live API names and links are not.
            text = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/', '', text)
            if re.search(r'\bSDL_[A-Za-z0-9_]+|#\s*include\s*[<"]SDL|\b(?:sdl3|sdl3-ttf)\b|-lSDL', text):
                raise ValueError('Retired SDL dependency in ' + directory.name + '/' + str(path.relative_to(directory)))
    for name in ('streaming/input/input.cpp', 'streaming/planktoolbar.cpp',
                 'streaming/video/ffmpeg-renderers/pacer/pacer.cpp',
                 'streaming/audio/renderers/sdlaud.cpp'):
        if (app / name).exists():
            raise ValueError('Retired session backend remains: ' + name)


if __name__ == '__main__':
    check(pathlib.Path(sys.argv[1]))
    print('client_no_sdl_source_gate=pass')
