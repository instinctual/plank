# macOS configuration

Install Host or Client with its signed PKG. The Client DMG contains the same PKG;
open it and follow Installer rather than dragging an app into Applications.
The Client remains interactive: no service, background helper or autostart entry
is installed. Quit the Client before upgrading, then launch it normally.

Administrator settings are installed as root-owned, mode0644 files in
`/etc/plank` (the macOS system alias for `/private/etc/plank`):

- Host: `host.conf`. `[general] host_name` overrides the discovery name. Omit it
  to use the OS hostname, matching Linux. The Host reads `gethostname()` locally
  at startup, not reverse DNS or the signed-in account. Restart the Host after
  renaming the computer; an unusable OS hostname falls back to `PLANK`.
  The advertised name does not change the workstation UUID or TLS identity.
  `[network] port` sets its TCP/UDP port. Default port28989. The Host always
  listens on all IPv4 interfaces. Restart the Host roles or restart the Mac after
  changing Host configuration. Firewall changes remain administrator-managed.
  `[network] ping_timeout` sets QUIC inactivity tolerance in milliseconds,
  default 10000 and range 200–120000. Invalid values fail startup, not silently
  clamp. Keepalives maintain idle desktops; this is not an input-idle timer or
  video/audio buffering setting. QUIC recovery and the peer's timeout also
  affect closure. Initial handshakes retain a separate 10-second deadline, and
  the Client's Unreachable host timeout/Wait/Disconnect policy is independent.
  `[security] publish_session_user` accepts `true`/`false`, default false. Opting
  in exposes the active desktop's short login name to anyone reaching discovery
  **before authentication**. Locked desktops retain their name; logout and user
  switching retire the old worker's metadata. LoginWindow remains nameless.
  Names must fit the shared 1–64-character ASCII metadata format; an `@realm`
  suffix is omitted and unsupported names are not published. No per-poll account
  lookup, authorization change or automatic takeover is introduced.
- Client: `client.conf`. `[network] port` controls the default bookmark port;
  optional `mdns_discovery` controls discovery policy; `[authentication]
  `remember_username` controls per-bookmark username retention. Restart the app
  after changing policy. User preferences and bookmarks remain per-user settings.

Both templates document all public administrator settings for that product.
These are INI files, not shell scripts. Use whole-line `#` or `;` comments and
unquoted values. Host rejects unknown keys, duplicates, invalid names and invalid
ports/timeouts/booleans rather than silently using a different configuration. Linux Host has its
own platform-specific template; do not copy its capture/encoder keys to macOS.

Upgrades preserve existing configuration, including administrator comments.
The one narrow exception is the old installer's exact generated `[general]`
block containing `host_name = PLANK Mac Host`: it is replaced atomically with
a commented-out override so the OS hostname is used. Other sections, custom
names, identity and TLS files remain unchanged. If that block was edited, it is
preserved byte-for-byte; comment out `host_name` yourself to opt into the default.
An explicitly configured `PLANK Mac Host` outside that generated block remains
a valid custom name. The installer never writes the current hostname into the
file, so later OS hostname changes take effect after restarting the Host.
Fresh reference templates are inside each app's `Contents/Resources`, named
`host.conf.example` and `client.conf.example`. They are documentation, not additional
runtime configuration sources. An unsafe file/link/permission causes installation
to fail without overwriting it; correct the metadata deliberately and retry.

The Host installer converts the previous `host.plist` only once. It preserves a
custom name and port in `host.conf` and the same workstation UUID in
`/Library/Application Support/PLANK/identity.plist`. Existing TLS keys and
certificates in `SignIn` remain unchanged. Its old `PLANK Mac Host` placeholder
becomes an omitted override rather than another hardcoded name. The old plist stays until the replacement
app is installed, then is removed after validating the conversion. Retrying an
interrupted upgrade is safe. Runtime never falls back to the old plist. A missing
UUID beside existing TLS state is an error, not permission to create a new identity.

Host uninstall retains configuration, identity and logs for reinstall. Removing
retained configuration is a separate, deliberate administrator action, especially
when Host and Client share `/etc/plank`.

Run Host uninstall from Terminal:

```bash
sudo "/Applications/PLANK Host.app/Contents/Resources/uninstall.sh"
```

The script requests PLANK Camera removal automatically using the signed Host app
in the active console user's desktop session. Approve the macOS prompt if shown;
there is no separate camera command. If no camera extension is registered, no
desktop session is required. Cancellation, a two-minute request timeout, or an
unverifiable extension state leaves the Host installed. If macOS requires a
restart, restart when ready and rerun the same uninstall command. The script
never restarts the Mac itself or directly deletes macOS-managed extension files.
Once camera removal is verified, it stops Host services and removes the app,
launchd entries, PLANK Output and PLANK Microphone drivers, and package receipt.
Restart afterward to unload the audio drivers from Core Audio.

## Client uninstall

Quit PLANK Client in all user sessions, then run:

```bash
sudo "/Applications/PLANK Client.app/Contents/Resources/uninstall.sh"
```

This removes only `/Applications/PLANK Client.app` and its installer receipt.
The script checks the app's signature and refuses to terminate a running Client.
There are no Client services, drivers or extensions to unload, and no restart
is required. Moving the closed app to Trash also remains a valid way to remove
the application, but leaves its installer receipt.

To also permanently remove Client configuration and **your own** saved data:

```bash
sudo "/Applications/PLANK Client.app/Contents/Resources/uninstall.sh" --purge
```

Run this from your normal account, not a root shell. After you type `DELETE` to
confirm, it removes `/etc/plank/client.conf` and the invoking user's bookmarks,
preferences, trusted-Host records, caches, logs and saved window state. User data
is removed without root privileges. Other users' saved data is not searched or
removed. Clearing trust records makes future connections first-use connections;
back up anything you want to retain before purging.

The normal uninstall preserves all configuration and user data. Both modes leave
Host components, Host settings/logs, shared parent directories and macOS privacy
permissions alone. Neither resets TCC or removes an entire shared PLANK folder.
