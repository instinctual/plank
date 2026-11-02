#!/usr/bin/env python3
"""Guard the no-video-frame reconnect presentation path (source checks)."""
import pathlib
import sys
import unittest

source = pathlib.Path(sys.argv.pop(1))
session = (source / "app/streaming/session.cpp").read_text()
runtime = (source / "app/streaming/qt/sessionruntime.cpp").read_text()
http = (source / "app/backend/nvhttp.cpp").read_text()


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class ReconnectPresentation(unittest.TestCase):
    def test_qt_wait_notice_does_not_pause_recovery(self):
        runtime = (source / "app/streaming/qt/sessionruntime.cpp").read_text()
        begin = between(runtime, "void QtSessionRuntime::beginRecovery", "void QtSessionRuntime::setInputEnabled")
        self.assertIn("PLANK_UNREACHABLE_DISCONNECT", begin)
        self.assertIn("m_ReconnectPolicy.allowUntil(m_ReconnectNoticeDeadline)", begin)
        self.assertIn("m_ReconnectPolicy.allowContinuously()", begin)
        tick = runtime.split("void QtSessionRuntime::tick()", 1)[1]
        self.assertIn("m_ReconnectNoticeDeadline = 0;", tick)
        self.assertIn("setWaiting(true)", tick)
        self.assertNotIn("m_ReconnectPolicy", tick)
        ready = between(runtime, "void QtSessionRuntime::setStreaming", "void QtSessionRuntime::updateGeometry")
        self.assertIn("m_ReconnectNoticeDeadline = 0;", ready)
        self.assertIn("setWaiting(false)", ready)
        self.assertLess(ready.index("updateGeometry()"), ready.index("setInputEnabled(m_InputGrabbed)"))
        stop = between(runtime, "void QtSessionRuntime::stop()", "bool QtSessionRuntime::resetDecoder")
        self.assertIn("m_ReconnectPolicy.allowUntil(0)", stop)
        self.assertIn("cancelConnectionStart()", stop)
        cancel = between(session, "void Session::cancelConnectionStart()", "void Session::setPlankReconnectStatus")
        self.assertIn("m_Lifecycle.stop()", cancel)
        surface = (source / "app/streaming/qt/SessionSurface.qml").read_text()
        self.assertNotIn("Keep Waiting", surface)
        self.assertNotIn("keepWaiting", runtime)
        self.assertIn('objectName: "recoveryDisconnectButton"', surface)

    def test_retry_gate_covers_all_http_entry_points(self):
        for signature in ("QJsonObject NvHTTP::postPlankJson", "QJsonObject NvHTTP::requestPinnedMacJson",
                          "NvHTTP::openConnection(QUrl"):
            body = http.split(signature, 1)[1].split("{", 1)[1]
            self.assertTrue(body.lstrip().startswith("waitForRequestPermission("))
        gate = between(session, "bool Session::waitForPlankReconnectRequest", "bool Session::runPlankReconnect")
        self.assertIn("m_Lifecycle.stopping()", gate)
        self.assertIn("m_ReconnectPolicy.allowsRequest(PlankClock::milliseconds())", gate)

    def test_readiness_retry_retains_authorization(self):
        retry = between(session, "bool Session::runPlankReconnect", "bool Session::finishPlankReconnect")
        self.assertEqual(retry.count("http.authenticate("), 1)
        self.assertIn("if (token.isEmpty())", retry)
        failure = retry.split("stopPlankTransportDataPlane();", 1)[1]
        self.assertNotIn("sessionToken.clear()", failure)
        self.assertIn("terminalStatus(error.getStatusCode(), authenticating)", retry)
        self.assertIn("SslHandshakeFailedError", retry)

    def test_control_queries_have_only_operation_parameters(self):
        request = between(http, "NvHTTP::openConnection(QUrl", "QNetworkRequest request(url);")
        self.assertIn("url.setQuery(arguments);", request)
        self.assertNotIn("uniqueid", request)
        self.assertNotIn("uuid", request)
        self.assertIn('request.setRawHeader("Authorization", "Bearer " + m_SessionToken.toUtf8());', http)

    def test_probe_is_credential_free_and_pinned(self):
        probe = between(http, "bool NvHTTP::probeWorkerReplacement", "QString NvHTTP::authenticate")
        self.assertIn("if (!m_SessionToken.isEmpty()) return false", probe)
        self.assertIn('m_BaseUrlHttps, "serverinfo", nullptr', probe)
        self.assertIn("1000, NvLogLevel::NVLL_NONE", probe)
        self.assertIn("peerCertificate().digest(QCryptographicHash::Sha256)", probe)
        self.assertIn("PlankHostRecovery::replacementConfirmed", probe)
        self.assertIn('PlankHostRecovery::videoSilent(now, s.m_LastPlankVideoReceived.load())', runtime)
        self.assertIn('http.probeWorkerReplacement(s.m_PlankWorkerInstance, s.m_PlankHostCertificateSha256)', runtime)

    def test_duplicate_reconnect_requests_do_not_quit(self):
        callback = between(session, "void Session::clConnectionTerminated", "void Session::clLogMessage")
        self.assertIn("m_Lifecycle.requestRecovery()", callback)
        self.assertIn("m_Lifecycle.recoveryPending()", callback)

    def test_terminal_receive_failure_notifies_without_input(self):
        receive = between(session, "void Session::plankTransportDataReceiveLoop()",
                          "const uint32_t magic =")
        self.assertIn("if (result == PLANK_TRANSPORT_TIMEOUT) {\n            continue;", receive)
        failure = between(receive, "if (result != PLANK_TRANSPORT_OK) {",
                          "if (packetSize < sizeof(uint32_t))")
        self.assertIn("if (!m_PlankTransportReceiversStopping.load()) {", failure)
        self.assertIn("clConnectionTerminated(result);\n            }\n            return;", failure)
        # Exactly one receiver reports shared endpoint closure. Otherwise media
        # closure could race ahead of a queued takeover reason in control data.
        media = between(session, "void Session::plankTransportVideoReceiveLoop()",
                        "void Session::plankTransportDataReceiveLoop()")
        self.assertNotIn("clConnectionTerminated(", media)
        start = between(session, "void Session::startPlankTransportMediaReceivers()",
                        "void Session::stopPlankTransportMediaReceivers()")
        self.assertIn("m_PlankTransportDataThread = std::thread", start)

    def test_initial_status_is_neutral(self):
        begin = between(session, "bool Session::beginPlankReconnect", "bool Session::runPlankReconnect")
        self.assertIn('"Waiting for workstation...", false', begin)
        self.assertNotIn('"Connection interrupted', begin)

    def test_status_is_published_before_decoder_suspension(self):
        begin = between(session, "bool Session::beginPlankReconnect", "bool Session::runPlankReconnect")
        self.assertLess(begin.index("setPlankReconnectStatus("), begin.index("suspendForReconnect()"))
        self.assertNotIn("updateOverlayText", begin)



unittest.main()
