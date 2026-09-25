#!/usr/bin/env python3
"""Permission call-site gates; native fake-API tests cover consent lifecycles."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
CLIENT = ROOT / "apps/client/app"
HOST = ROOT / "apps/host/macos"


class ClientPermissions(unittest.TestCase):
    def test_client_launcher_resolves_microphone_before_bookmarks(self):
        main = (CLIENT / "main.cpp").read_text()
        launch = main.split("// Resolve optional microphone consent", 1)[1]
        self.assertIn("GlobalCommandLineParser::NormalStartRequested", launch)
        self.assertIn("QTimer::singleShot(0, &engine", launch)
        for call in ("requestKeyboardPermission();", "MacRawWacomInput::requestPermissionIfNeeded();",
                     "plankMacRequestMicrophonePermission("):
            self.assertLess(launch.index(call), launch.index("context->load("))
        self.assertIn("QPointer<QQmlApplicationEngine>", launch)
        self.assertIn("Qt::QueuedConnection", launch)
        self.assertIn("Load immediately on Linux and for non-prompting CLI", launch)

    def test_session_microphone_is_query_only(self):
        source = (CLIENT / "streaming/audio/microphone.cpp").read_text()
        self.assertIn("plankMacMicrophonePermission()", source)
        self.assertNotIn("RequestMicrophonePermission", source)
        self.assertNotIn("plankMacMicrophonePermission(true)", source)
        helper = (CLIENT / "streaming/audio/macmicrophonepermission.mm").read_text()
        query, request = helper.split("void plankMacRequestMicrophonePermission", 1)
        self.assertNotIn("requestAccessForMediaType", query)
        self.assertIn("if (plankMacMicrophonePermission() != 0)", request)
        self.assertIn("dispatch_get_main_queue()", request)
        self.assertNotIn("AVCaptureSession", helper)

    def test_wacom_launch_only_and_attached_usb_only(self):
        source = (CLIENT / "streaming/input/macrawwacom.cpp").read_text()
        startup, runtime = source.split("class MacRawWacomInput::Impl", 1)
        self.assertIn("kIOHIDAccessTypeUnknown", startup)
        self.assertIn("IOServiceGetMatchingServices", startup)
        self.assertIn('CFEqual(transport, CFSTR("USB"))', startup)
        self.assertIn("PlankWacomTransport::ExactRawHid", startup)
        self.assertIn("if (attached) IOHIDRequestAccess", startup)
        self.assertNotIn("IOHIDDeviceOpen", startup)
        self.assertNotIn("IOHIDRequestAccess", runtime)
        self.assertIn("kIOHIDAccessTypeGranted", runtime)

    def test_no_unimplemented_camera_permission(self):
        camera = (CLIENT / "streaming/camera/camera.cpp").read_text()
        self.assertNotIn("requestAccessForMediaType", camera)


class HostPermissions(unittest.TestCase):
    def test_host_setup_not_diagnostic_or_worker(self):
        source = (HOST / "session/host-main.m").read_text()
        check = source.split("static int checkPermissions(void)", 1)[1].split("// Read only", 1)[0]
        self.assertNotIn("Request", check)
        self.assertNotIn("finishPermissionSetup", check)
        self.assertIn('@"audio_tap_permission": @"not-checked"', check)
        workers = source.split("static int machine(", 1)[1].split("int main(", 1)[0]
        self.assertNotIn("finishPermissionSetup", workers)
        self.assertNotIn("PLANKMacAudioConsent", workers)
        gui = source.split('!strcmp(argv[1], "--request-permissions")', 1)[1].split(
            'if (argc == 3 && !strcmp(argv[1], "--machine"))', 1)[0]
        self.assertEqual(gui.count("finishPermissionSetup(app);"), 2)
        self.assertIn("CGRequestScreenCaptureAccess()", gui)
        self.assertIn("CGRequestPostEventAccess()", gui)
        self.assertIn("AXIsProcessTrustedWithOptions", gui)

    def test_host_consent_is_not_audio_forwarding_or_output_routing(self):
        source = (HOST / "session/audio-consent.m").read_text()
        self.assertIn("initStereoMixdownOfProcesses:@[]", source)
        self.assertIn("description.exclusive = NO", source)
        self.assertIn("description.muteBehavior = CATapUnmuted", source)
        self.assertIn("description.privateTap = YES", source)
        self.assertIn("description.processRestoreEnabled = NO", source)
        self.assertIn("geteuid() == 0", source)
        for forbidden in ("ExcludingProcesses", "AudioObjectSetPropertyData", "AudioObjectGetPropertyData",
                          "SubDeviceListKey", "CATapMuted", "input->", "CGRequest", "tccutil"):
            self.assertNotIn(forbidden, source)
        for cleanup in ("AudioDeviceStop", "AudioDeviceDestroyIOProcID",
                        "AudioHardwareDestroyAggregateDevice", "AudioHardwareDestroyProcessTap"):
            self.assertIn(cleanup, source)

    def test_camera_extension_approval_is_host_setup_only(self):
        main = (HOST / "session/host-main.m").read_text()
        self.assertIn('"--enable-camera"', main)
        runtime = (HOST / "session/host-runtime.m").read_text()
        self.assertNotIn("PLANKMacRequestCameraExtension", runtime)
        self.assertNotIn("OSSystemExtensionRequest", runtime)

    def test_native_permission_tests_are_build_gates(self):
        for product, fixture in (("host", "tests/auth/macos-audio-consent.m"),
                                 ("client", "tests/audio/macos-microphone-permission.mm")):
            build = (ROOT / f"scripts/build/build-macos-{product}.sh").read_text()
            self.assertIn(fixture, build)
            self.assertIn("test-startup-permissions.py", build)


if __name__ == "__main__":
    unittest.main()
