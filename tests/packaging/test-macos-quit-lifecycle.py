#!/usr/bin/env python3
"""Source wiring guards; native Qt/AppKit suites test runtime behavior on CI."""
import pathlib
import sys
import unittest

ROOT = pathlib.Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[2]
CLIENT = ROOT / "apps/client"


class QuitLifecycle(unittest.TestCase):
    def test_bridge_is_removed(self):
        self.assertFalse((CLIENT / "app/macquitbridge.h").exists())
        application = (CLIENT / "app/macapplication.h").read_text()
        self.assertNotIn("SDL_", application)
        self.assertNotIn("installEventFilter", application)
        self.assertIn("event->ignore()", application)
        self.assertIn("emit exitRequested()", application)

    def test_cleanup_owns_exit(self):
        session = (CLIENT / "app/streaming/session.cpp").read_text()
        registration = session.split("void Session::exec(QWindow* qtWindow)", 1)[1].split("m_QtWindow = qtWindow", 1)[0]
        self.assertIn("#ifdef Q_OS_MACOS", registration)
        self.assertIn("&Session::readyForDeletion", registration)
        self.assertNotIn("&Session::sessionFinished", registration)
        self.assertIn("Qt::QueuedConnection", registration)
        self.assertIn("application->endSession()", registration)
        self.assertIn("cancelConnectionStart()", registration)
        cancellation = session.split("void Session::cancelConnectionStart()", 1)[1].split("\n}", 1)[0]
        self.assertIn("m_Lifecycle.stop()", cancellation)

    def test_native_suites_are_mandatory(self):
        build = (ROOT / "scripts/build/build-macos-client.sh").read_text()
        self.assertIn("desktopstage macquitshortcut macapplication", build)
        main = (CLIENT / "app/main.cpp").read_text()
        self.assertIn("#ifdef Q_OS_MACOS\n    MacApplication app(argc, argv);\n#else\n    QGuiApplication app(argc, argv);", main)


if __name__ == "__main__":
    unittest.main()
