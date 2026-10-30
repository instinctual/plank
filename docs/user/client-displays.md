# Ubuntu Client displays

**Client Displays** in each bookmark chooses where the remote session appears
when fullscreen. It is independent of **Host Display Layout** and **Scaling**.

New bookmarks default to **Native (1:1 pixels)** scaling. Saved bookmarks keep
their selected scaling mode; **Scaled-Span** remains available.

- **Current monitor** uses the monitor containing the sign-in window. This is
  the default for new bookmarks.
- A **named monitor** always selects that connected display. Connector names
  distinguish two identical monitor models.
- **Span both monitors** uses two displays arranged side by side in the local
  desktop settings. Existing bookmarks retain this behavior until edited.

For two simultaneous sessions, select a different named monitor in each
bookmark and use fullscreen. Each session fills its own display without a
window title bar. The pointer can cross between monitors; click the desired
session to give it keyboard and tablet focus.

When **Host Display Layout** is **Match Client**, the requested Host layout
uses only the selected Client display or displays. Other Host layouts keep
their chosen resolution. Fullscreen removes window decorations; an aspect
ratio difference between the remote desktop and local display can still leave
black borders. Use matching dimensions for an exact fit.

The arrow beside the toolbar fullscreen button offers **Fullscreen on this
monitor** and **Span both monitors**. These choices affect the current session
only. They keep the Host resolution and bookmark unchanged. A session may be
scaled or letterboxed after changing its local display area. Reconnect after
editing the bookmark to request a different Host layout.

If a saved monitor is disconnected, PLANK uses the current monitor and shows
a notice. If spanning is unavailable, it also falls back to one monitor.
Disconnecting a monitor actively used by a session ends that session; reconnect
with the new layout. A monitor added during a session is available after
reconnecting. The macOS Client's display behavior is unchanged.
