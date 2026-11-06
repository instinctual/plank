# Client Internet indicator

The main window shows **Internet: Checking**, **Internet: Reachable**, or
**Internet: No response**. This is separate from the Online/Offline status of
each bookmarked Host. A failure never prevents a connection or interrupts a
session. **Internet: Unavailable** means the configuration or the local ping
utility could not perform the check.

The toolbar uses larger, semibold text and a matching status dot: green for
Reachable, red for No response, amber for Unavailable, and gray for Checking.
The text and hover explanation remain available regardless of color; No response
means the ping targets did not reply, not proof that all Internet access is down.

Click the indicator (or focus it and press Enter or Space) to open **Internet
Connectivity**. While the dialog is open, every configured IPv4 address is
checked concurrently about once per second, including addresses skipped by the
background check. Each row
shows the address, colored status and actual ICMP round-trip time in whole
milliseconds; replies faster than one millisecond show **<1 ms**. A dash means
no timing is available, including a successful reply whose timing output could
not be read.

Results update automatically without a Refresh button. Previous results stay
visible while the next round runs. The configured timeout still applies; a slow round finishes before the
next starts. **Close** or Escape ends live mode and resumes the normal background
interval. Live results also update the main Internet indicator. There is one
scheduler, so background and live rounds never overlap; cancelled processes
finish before a mode switch or rapid reopening starts fresh checks.

By default, showing the main window sends one ICMP echo to Google's public resolver.
If it does not reply within one second, it tries Cloudflare's, then Quad9's.
The exact addresses are in the [configuration template](../../packaging/client/config/plank-client.conf).
The first reply ends the round. While the main window remains visible, every
15 seconds it starts again at the first address. Checks
are asynchronous and never overlap. A round longer than the configured interval
finishes before the next round starts. Only state transitions are logged.

Hiding, minimizing or closing the main window stops all Internet-check timers
and cancels outstanding pings, including live-dialog checks. Showing it again
checks immediately. A streaming window alone never restarts these Internet
checks. Session recovery, QUIC health checks and the stream Toolbar's RTT
measurement continue independently.

The last result stays visible between rounds. Network-change notifications
request a fresh check of a visible main window, with a short debounce.
Resume/focus checks refresh stale results only while that window is visible;
periodic checks still run if native network notifications are unavailable.
The indicator is hidden when disabled.

Configure both Ubuntu and macOS Clients in the administrator-owned
`/etc/plank/client.conf`, then restart the Client:

```ini
[network]
internet_check_enabled = true
# internet_check_hosts: retain the template's public defaults, or set your own list.
internet_check_interval_seconds = 15
internet_check_timeout_ms = 1000
```

Use 1–8 numeric unicast IPv4 addresses. IPv6 addresses and DNS names are rejected.
The interval accepts 5–3600 seconds and each timeout accepts 100–10000 ms.
Invalid configuration does not silently send probes to the public defaults.
Omitted keys use the defaults above. During installation or upgrade, both
packages add missing connectivity keys and their comments under `[network]`.
Existing values, comments and unrelated settings are preserved. Repeated
installation does not duplicate keys. Ubuntu retains its normal package-manager
keep/replace behavior for customized configuration; choosing to keep a file
still adds the missing connectivity keys. Unsafe/symlinked files are not rewritten.

The check sends only small ping packets, with no account details or Host names.
It does not measure bandwidth or verify DNS, VPN access, captive-portal login,
or PLANK service availability. A network may block ICMP while other traffic
works. Hover over the indicator for the result's explanation.

Ubuntu uses the packaged `iputils-ping` dependency and a Python 3 installer helper
at `/usr/libexec/plank-client-update-policy`. The helper runs only during package
configuration and is removed with the package. The complete example is installed
at `/usr/share/doc/plank-client/client.conf.example`.
macOS uses its existing native installer configuration helper and system ping
utilities. PLANK itself gains no new privileges, services or capabilities.
Only fixed executable paths and separately supplied arguments are used;
configuration cannot specify a program or shell command.

Component tests cover ordered fallback, timer deadlines, responsive UI,
periodic recovery, cancellation, disabled/invalid policy, unavailable tools,
no-route versus permission failures, and actual IPv4 loopback pings on
both supported build platforms. Summary checks also cover concurrent targets,
timing formats, bounded output, utility errors, cancellation/reopening, retained
results, slow rounds without overlap and hidden-window stop/resume. Hosted QML
checks exercise the production visibility binding, hide/minimize/restore,
indicator text, sizing, automatic dialog updates, mouse/keyboard interaction,
eight-target layout and screenshots.
Installed UI/network acceptance remains
separate from those build checks.
