#!/usr/bin/env python3
"""Native fullscreen geometry and wiring; not live notch acceptance."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

root = Path(sys.argv.pop(1)).resolve()
client = root / 'apps/client'
session = (client / 'app/streaming/session.cpp').read_text()


class NativeFullscreenTests(unittest.TestCase):
    def preprocess_platform(self, source, darwin):
        return subprocess.check_output(
            ['c++', '-E', '-P', '-x', 'c++', *(['-DQ_OS_DARWIN'] if darwin else []), '-'],
            input=source, text=True)

    def test_capture_policy_preserves_non_mac_behavior(self):
        main = (client / 'app/main.cpp').read_text()
        hint = main.index('SDL_SetHint(SDL_HINT_MOUSE_AUTO_CAPTURE, "1")')
        start = main.rfind('#ifdef Q_OS_DARWIN', 0, hint)
        end = main.index('#endif', hint) + len('#endif')
        for darwin, value in ((True, '1'), (False, '0')):
            compiled = self.preprocess_platform(main[start:end], darwin)
            self.assertIn(f'SDL_SetHint(SDL_HINT_MOUSE_AUTO_CAPTURE, "{value}")', compiled)
            self.assertEqual(compiled.count('SDL_HINT_MOUSE_AUTO_CAPTURE'), 1)

    def test_secondary_spaces_exit_is_mac_only(self):
        source = (client / 'app/streaming/plankpresentation.cpp').read_text()
        function = source.split('bool PlankPresentation::setSecondaryFullscreen', 1)[1].split(
            'QRect PlankPresentation::videoRect', 1)[0]
        mac = self.preprocess_platform(function, True)
        linux = self.preprocess_platform(function, False)
        self.assertLess(mac.index('SDL_SyncWindow'), mac.index('SDL_HideWindow'))
        self.assertNotIn('SDL_SyncWindow', linux)
        self.assertIn('if (!fullscreen) return SDL_HideWindow(window)', linux)
        self.assertLess(linux.index('SDL_ShowWindow'), linux.index('SDL_SetWindowFullscreen'))

    def test_native_spaces_without_sdl_override(self):
        self.assertIn('MacDisplayGeometry::useNativeFullscreen(macDisplayCount) ? \"1\" : \"0\"', session)
        self.assertLess(session.index('SDL_SetHint(SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES'), session.index('if (!SDL_InitSubSystem(SDL_INIT_VIDEO))'))
        self.assertIn('MacWindow::activeDisplayCount()', session)
        self.assertIn('m_ClientDisplays.size() != macDisplayCount', session)
        self.assertNotIn('PLANK_MAC_FULLSCREEN_FULL_DISPLAY', session)
        self.assertFalse((root / 'scripts/build/prepare-macos-sdl.sh').exists())
        self.assertFalse((client / 'app/deploy/macos/sdl-patches/0001-cocoa-opt-in-full-display-content-size.patch').exists())
        info = plistlib.loads((client / 'app/Info.plist').read_bytes())
        self.assertIs(info['NSPrefersDisplaySafeAreaCompatibilityMode'], False)

    def test_authentication_and_reconnect_share_viewport(self):
        manager = (client / 'app/backend/computermanager.cpp').read_text()
        self.assertIn('m_Prefs->windowMode != StreamingPreferences::WM_WINDOWED', manager)
        self.assertIn('&currentMode, &matchedBounds, m_IsFullScreen &&', session)
        self.assertIn('MacDisplayGeometry::useNativeFullscreen(displayCount)', session)
        self.assertIn('MacDisplayGeometry::useNativeFullscreen(count)', manager)
        self.assertEqual(session.count('display.macMatchedBounds.isValid() ? display.macMatchedBounds'), 2)
        utils = (client / 'app/streaming/streamutils.cpp').read_text()
        self.assertIn('getMacCurrentDisplayMode(selected, mode, matchedBounds, fullscreen)', utils)
        self.assertIn('MacDisplayGeometry::insetTop', utils)
        mac = (client / 'app/streaming/macwindow.mm').read_text()
        self.assertIn('std::ceil(screen.safeAreaInsets.top)', mac)
        self.assertNotIn('screen.visibleFrame', mac)

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

    def test_focus_loss_keeps_release_and_toolbar_cleanup(self):
        focus = session.rsplit('case SDL_EVENT_WINDOW_FOCUS_LOST:', 1)[1].split('case SDL_EVENT_WINDOW_FOCUS_GAINED:', 1)[0]
        self.assertIn('m_InputHandler->notifyFocusLost()', focus)
        self.assertIn('m_PlankToolbar->notifyFocusLost()', focus)
        source = (client / 'app/streaming/input/input.cpp').read_text()
        lost = source.split('void SdlInputHandler::notifyFocusLost()', 1)[1].split('void SdlInputHandler::notifyFocusGained()', 1)[0]
        self.assertIn('raiseAllKeys()', lost)
        self.assertIn('activateCompositorCursor()', lost)

    def test_fullscreen_events_refresh_controls_and_log_geometry(self):
        self.assertIn('case SDL_EVENT_WINDOW_ENTER_FULLSCREEN:', session)
        self.assertIn('case SDL_EVENT_WINDOW_LEAVE_FULLSCREEN:', session)
        self.assertIn('MacWindow::logGeometry(eventWindow)', session)
        mac = (client / 'app/streaming/macwindow.mm').read_text()
        self.assertIn('SDL_GetWindowSizeInPixels', mac)

    def test_toolbar_uses_window_position_without_notch_offset(self):
        toolbar = (client / 'app/streaming/planktoolbar.cpp').read_text()
        layout = toolbar.split('void PlankToolbar::notifyWindowChanged()', 1)[1].split(
            '\nvoid PlankToolbar::', 1)[0]
        self.assertIn('std::max(0, (m_WindowWidth - m_Width) / 2)', layout)
        self.assertIn('PlankToolbarLogic::logicalLeftFromPosition(', layout)
        self.assertEqual(self.preprocess_platform(layout, True),
                         self.preprocess_platform(layout, False))
        for filename in ('planktoolbar.cpp', 'planktoolbarlogic.h', 'macwindow.h', 'macwindow.mm'):
            source = (client / 'app/streaming' / filename).read_text()
            self.assertNotIn('unobscuredToolbarLeft', source)
            self.assertNotIn('auxiliaryTopLeftArea', source)
            self.assertNotIn('auxiliaryTopRightArea', source)


unittest.main()
