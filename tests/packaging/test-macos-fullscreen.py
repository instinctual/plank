#!/usr/bin/env python3
"""Native/Qt fullscreen geometry and wiring; not installed notch acceptance."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
root = Path(sys.argv.pop(1)).resolve()
client = root / 'apps/client'

class NativeFullscreenTests(unittest.TestCase):
    def test_single_qt_session_owner(self):
        session = (client / 'app/streaming/session.cpp').read_text()
        self.assertIn('new QtSessionRuntime(this)', session)
        self.assertNotIn('execInternal', session)
        shell = (client / 'app/streaming/qt/metalsessionshell.mm').read_text()
        self.assertIn('showFullScreen();', shell)
        self.assertIn('showNormal();', shell)
        runtime = (client / 'app/streaming/qt/sessionruntime.cpp').read_text()
        self.assertIn('MacDisplays::currentModeForBounds', runtime)
        self.assertIn('display.nativeSize = display.macBackingSize', runtime)
        info = plistlib.loads((client / 'app/Info.plist').read_bytes())
        self.assertIs(info['NSPrefersDisplaySafeAreaCompatibilityMode'], False)

    def test_authentication_and_session_share_native_display_geometry(self):
        for name in ('app/backend/computermanager.cpp', 'app/streaming/qt/sessionruntime.cpp'):
            code = (client / name).read_text()
            self.assertIn('MacDisplays::currentMode', code)
        display = (client / 'app/streaming/macdisplays.mm').read_text()
        self.assertIn('std::ceil(selected.safeAreaInsets.top)', display)
        self.assertIn('MacDisplayGeometry::insetTop', display)
        self.assertNotIn('screen.visibleFrame', display)

    def test_geometry_executable(self):
        code = r'''
#include "macdisplaygeometry.h"
#include <cassert>
#include <initializer_list>
int main() {
    for (int count : {1, 2, 3}) assert(MacDisplayGeometry::useNativeFullscreen(count));
    for (int count : {-1, 0}) assert(!MacDisplayGeometry::useNativeFullscreen(count));
    assert(MacDisplayGeometry::nativeFullscreenTopInset(0, 15) == 0);
    assert(MacDisplayGeometry::nativeFullscreenTopInset(32, 15) == 37);
    assert(MacDisplayGeometry::nativeFullscreenTopInset(38, 15) == 43);
    assert(MacDisplayGeometry::nativeFullscreenTopInset(38, 26) == 38);
    int measuredHeight = 1329, measuredPixels = 2658;
    assert(MacDisplayGeometry::insetTop(2056, measuredHeight, 4112, measuredPixels,
        MacDisplayGeometry::nativeFullscreenTopInset(38, 15)));
    assert(measuredHeight == 1286 && measuredPixels == 2572);
    for (int scale : {1, 2}) {
        for (int top : {0, 24, 34, 38}) {
            int h = 1200, pixels = h * scale;
            assert(MacDisplayGeometry::insetTop(1900, h, 1900 * scale, pixels, top));
            assert(h == 1200 - top && pixels == h * scale);
        }
    }
    int h = 1107, pixels = 2214;
    assert(MacDisplayGeometry::insetTop(1710, h, 3420, pixels, 34));
    assert(h == 1073 && pixels == 2146);
    for (int top : {-1, 1200, 1201}) {
        h = 1200; pixels = 2400;
        assert(!MacDisplayGeometry::insetTop(1920, h, 3840, pixels, top));
        assert(h == 1200 && pixels == 2400);
    }
    h = 1200; pixels = 2400;
    assert(!MacDisplayGeometry::insetTop(0, h, 0, pixels, 0));
    assert(!MacDisplayGeometry::insetTop(1920, h, 3000, pixels, 34));
    assert(!MacDisplayGeometry::insetTop(1920, h, 1920, pixels, 34));
    assert(!MacDisplayGeometry::insetTop(1920, h, 5760, pixels, 34));
}
'''
        with tempfile.TemporaryDirectory(prefix='plank-fullscreen-') as tmp:
            source = Path(tmp) / 'geometry.cpp'
            source.write_text(code)
            binary = Path(tmp) / 'geometry'
            subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-I', str(client / 'app/streaming'), str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


unittest.main()
