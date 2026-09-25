#!/usr/bin/env python3
"""Assembly guards complement the native INI, timeout and discovery tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "apps/host/macos"


class HostSettings(unittest.TestCase):
    def test_configuration_reaches_transport_without_changing_setup_deadline(self):
        main = (HOST / "session/host-main.m").read_text()
        runtime = (HOST / "session/host-runtime.m").read_text()
        preview = (HOST / "media/preview-session.m").read_text()
        self.assertIn('idleTimeoutMilliseconds:[config[@"PingTimeoutMs"] unsignedIntValue]', main)
        self.assertIn("plank_macos_valid_ping_timeout(idleTimeoutMilliseconds)", runtime)
        self.assertIn("_idleTimeoutMs = idleTimeoutMilliseconds;", runtime)
        self.assertIn("config.idle_timeout_ms = _idleTimeoutMs;", runtime)
        self.assertIn("config.keep_alive_interval_ms = plank_macos_keep_alive_interval(_idleTimeoutMs);", runtime)
        self.assertIn("configuration.handshake_timeout_ms = 10000;", preview)

    def test_public_name_requires_opt_in_and_existing_desktop_provisioning(self):
        main = (HOST / "session/host-main.m").read_text()
        self.assertIn("NSString *desktopAccountName = nil;", main)
        self.assertIn('sessionUser:[config[@"PublishSessionUser"] boolValue] ? desktopAccountName : nil', main)
        desktop = main.split("if (phase == PLANKMacScopeDesktop) {", 1)[1].split("} else {", 1)[0]
        self.assertIn("PLANKMacPrepareDesktop(&directory, &publicConfiguration, &desktopAccountName)", desktop)
        provision = (HOST / "session/desktop-provisioning.m").read_text()
        self.assertEqual(provision.count("getpwuid("), 1)
        self.assertIn("account->pw_uid != getuid()", provision)
        self.assertIn("account->pw_name", provision)
        self.assertIn("*accountName = nil;", provision)

    def test_discovery_remains_cached_and_resolver_free(self):
        source = (HOST / "control/https-auth-server.m").read_text()
        public = source.split("if (information && !authorization.length)", 1)[1].split("} else if", 1)[0]
        self.assertIn("_occupiedServerInformationXML : owner->_serverInformationXML", public)
        for forbidden in ("_authQueue", "getpwuid", "SCDynamicStore", "snapshot", "XMLForControlPort"):
            self.assertNotIn(forbidden, public)
        information = (HOST / "control/server-information.m").read_text()
        for forbidden in ("getpwuid", "getpwnam", "NSUserName", "SCDynamicStore", "NSProcessInfo"):
            self.assertNotIn(forbidden, information)
        self.assertIn("_sessionUser = occupied ? publicSessionUser(sessionUser) : nil;", information)

    def test_reference_defaults_and_new_keys_are_documented(self):
        template = (ROOT / "packaging/host/macos/config/plank-host.conf").read_text()
        for value in ("ping_timeout = 10000", "publish_session_user = false", "BEFORE authentication",
                      "200 through 120000", "Unreachable host timeout", "LoginWindow"):
            self.assertIn(value, template)

    def test_hostname_reference_uses_an_optional_override(self):
        template = (ROOT / "packaging/host/macos/config/plank-host.conf").read_text()
        self.assertIn("# host_name = workstation-name", template)
        self.assertIn("gethostname()", template)
        self.assertIn("fall back to PLANK", template)
        self.assertNotIn("\nhost_name =", template)
        parser = (HOST / "session/host-configuration.m").read_text()
        self.assertIn('values[@"general.host_name"] ?: systemHostName()', parser)
        self.assertNotIn('"PLANK Mac Host"', parser)
        for forbidden in ("getaddrinfo", "getnameinfo", "NSHost", "NSUserName"):
            self.assertNotIn(forbidden, parser)


if __name__ == "__main__":
    unittest.main()
