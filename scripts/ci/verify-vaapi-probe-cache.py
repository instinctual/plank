#!/usr/bin/env python3
"""A diagnostic links the shipped libraries, never a newly bootstrapped FFmpeg.

Unlike a product build, this intentionally selects an explicit existing cache
even when the hosted compiler image changes. Validate its original receipt and
patched sources. The resulting artifact records library hashes, which must be
matched to the installed Client before the hardware test. Product cache rules
are unchanged; this path never saves a cache or produces a package.
"""
import os
from pathlib import Path
import runpy

root = Path(os.environ['PLANK_SOURCE_ROOT'])
deps = Path(os.environ['PLANK_DEP_ROOT'])
cache = runpy.run_path(str(root / 'scripts/ci/cache-dependencies.py'))
requested = os.environ['REQUIRED_FFMPEG_CACHE']
matched = os.environ['CACHE_MATCHED_FFMPEG']
if not cache['key_valid'](requested, 'linux-client', 'ffmpeg') or matched != requested:
    raise ValueError('The explicitly selected diagnostic FFmpeg cache was not restored')
cache['verify_receipt'](root, deps, 'linux-client', 'ffmpeg', requested)
cache['check_prepared'](root, deps, 'linux-client', 'ffmpeg')
print('vaapi_probe_retained_library_gate=pass')
