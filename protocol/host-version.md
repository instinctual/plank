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

`1` means a user desktop currently owns the console, or a PLANK stream owns
the Host (including admitted stream setup and teardown). This includes local
physical desktop use and an active connection to a sign-in screen. Both Hosts
use the same rule. `0` or an omitted element means the Client must
show `Online`, not `In Session`. Occupancy is a courtesy indicator only; it
does not replace PAM or active-desktop ownership.

A user who leaves their own desktop logged in at the office can still connect
from home as that same user. Existing explicit takeover and different-user
ownership protections are unchanged. An occupied indication is not a lock.

Linux discovery reads a confirmed attachment and local logind observation. The
existing supervisor resolves the account before launching a worker; its bounded
private `SC-SESSION-3` attachment record carries a sanitized advisory name with
the same UID, session and generation. HTTP performs no NSS lookup, and a changed
or missing desktop suppresses the old name. Stream occupancy is an atomic
snapshot, never a call to session cleanup. Both private-channel ends ship in the
same Host package; old private records are rejected, not reinterpreted.

macOS retains the immutable agent desktop bit and a lock-free stream-lease bit.
Discovery selects cached free/occupied XML without waiting for authentication,
account lookup, display preparation or teardown. This does not grant authority
or expose the stream owner's name at LoginWindow.

By default the response includes no account name, UID, or session id. A Linux
Host administrator may opt in with `publish_session_user = true` in
`/etc/plank/host.conf`. While that setting is true and a user desktop is
active, `/serverinfo` may add the login name of that desktop. A directory
login is published as the name before `@`:

```xml
<PlankSessionUser>example-user</PlankSessionUser>
```

The Client then shows `In Session - example-user`. An omitted or rejected
name keeps the label `In Session`. The sign-in screen does not publish a name.
The element is still omitted when the setting is false.

Opting in exposes the name to any peer that can reach the discovery endpoint,
before authentication. Names are 1–64 ASCII letters/digits, dot, underscore or
hyphen. Clients reject other names and ignore names unless occupancy is exactly
`1`. Neither field is persisted in bookmarks; offline rows suppress both. Long
names elide at the right without hiding the status. These optional metadata-v1
fields are not authorization capabilities and require no launch feature bit.
