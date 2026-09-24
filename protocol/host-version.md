# PLANK Host Version Discovery

The client discovers the installed PLANK Host release during its
normal bookmark availability poll. The host adds this element to both HTTP and
authenticated HTTPS `/serverinfo` responses:

```xml
<PlankHostMetadataVersion>1</PlankHostMetadataVersion>
<PlankHostVersion>0.1.0-0.104</PlankHostVersion>
```

Metadata schema version 1 defines the host-version element. Its value is the
exact package release embedded in the host binary at build time. This metadata
is informational and does not replace the GameStream-compatible `appversion`,
protocol feature flags, or explicit topology version.

When a bookmark is online, the main client row displays the value immediately
to the right of `Online`. An absent or empty element is tolerated and leaves
the version portion blank. A client also ignores the release element when the
metadata schema version is absent. Offline rows do not display a stale cached
value.

Unauthenticated HTTPS `/serverinfo` also includes a nameless occupancy bit:

```xml
<PlankOccupied>0</PlankOccupied>
```

`1` means a user desktop currently owns the console, or a live PLANK stream is
active. On Linux that is `confirmed_desktop_stage() == "user"` or a live
session count. On macOS the LoginWindow agent advertises `0` and the Aqua
desktop agent advertises `1`. `0` or an omitted element means the Client must
show `Online`, not `In Session`. Occupancy is a courtesy indicator only; it
does not replace PAM or active-desktop ownership.

By default the response includes no account name, UID, or session id. A Linux
Host administrator may opt in with `publish_session_user = true` in
`/etc/plank/host.conf`. While that setting is true and a user desktop is
active, `/serverinfo` may add the login name of that desktop. A directory
login is published as the name before `@`:

```xml
<PlankSessionUser>Ernie.Armitage</PlankSessionUser>
```

The Client then shows `In Session - Ernie.Armitage`. An omitted or rejected
name keeps the label `In Session`. The sign-in screen does not publish a name.
The element is still omitted when the setting is false.
