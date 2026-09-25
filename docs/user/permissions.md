# Permissions before connecting

Both macOS installers automatically open the installed app's permission setup
for the active desktop user. Complete the macOS approval steps there before
connecting; no manual app launch is needed after an interactive install.
Client installer setup does not open bookmarks, poll hosts or start a session.
Closing it exits the setup-only Client instance. It does not create a login item,
background service or automatic connection.

The signed application requests access, not the root installer. Installation is
not permission approval: macOS controls each grant, and PLANK does not modify
the privacy database. Some authorization is machine-wide; other consent belongs
to the user. Another account may still need setup.

At LoginWindow, with no usable desktop, or if setup cannot be opened, the
installer reports that permission setup remains pending. Log in and open
**PLANK Host** or **PLANK Client** to finish. Installation does not wait forever
for consent, fail merely because an optional feature is declined, or start a
persistent helper to retry. If the Client is already running during an upgrade,
the installer defers setup instead of putting permission dialogs over a possible
stream; quit and reopen the Client to finish. Normal Client launch retains permission checks for
new users, revoked access and newly attached supported USB Wacom tablets.

## Reviewing status

Opening **PLANK Host** displays a single setup window, with aligned feature,
status and action columns. Desktop permissions and optional audio/camera
components are separate. Each explanatory sentence has its own line.
The window initially centers in the usable desktop, clear of the menu bar and
Dock. Moving it yourself is preserved when returning from System Settings.
Refresh and Close are at the lower right. The installer-launched Client setup
uses the same native macOS appearance and feature/status/action layout; the
main Client window retains its existing style.

- **✓ Allowed** means the OS permission query succeeded.
- **! Required** identifies missing desktop access.
- **✓ Loaded** means the optional audio device is present in Core Audio, not
  that a microphone is forwarding or application audio is playing.
- Camera status distinguishes enabled, disabled, approval pending, removal
  pending and a failed status check. Setup still reconciles an already-enabled
  camera extension after an upgrade; first activation remains an explicit action.
- System audio has no permission-status indicator: starting the empty consent
  tap cannot prove that audio-recording permission was granted. Its setup-time
  consent request and **Open Audio Privacy Settings** action remain available.

Statuses are read-only labels, not permission-granting checkboxes.
Use the row's **Open Settings** or **Enable Camera** action when needed.
Status refreshes when returning from System Settings; **Refresh** checks again
without continuously polling. If an installed audio component is not loaded,
restart the Mac when convenient. This window does not start a remote session.

On **PLANK Client for macOS**, open **Configuration → Input Settings → Review
permissions** for Accessibility, Microphone and Input Monitoring status. Input
Monitoring is only requested with a supported USB Wacom attached. There is no
extra all-ready popup at launch. Permission actions are blocked during a stream;
normal launcher-time consent requests still happen before connecting.

The Client panel is macOS-only. Linux settings and permission handling are unchanged.

## Request timing

| Product | Permission | When PLANK requests it |
| --- | --- | --- |
| macOS Client | Accessibility for system keyboard shortcuts | Installer-launched setup and ordinary app launch when shortcut capture is enabled; also when enabling it in Settings outside a session. |
| macOS Client | Microphone | Installer-launched setup and ordinary app launch, before bookmarks are available. This only requests permission; it does not open a microphone or forward audio. |
| macOS Client | Input Monitoring for raw Wacom forwarding | Installer-launched setup and ordinary app launch with a supported USB Wacom attached. It reads device metadata without opening or seizing the tablet. |
| macOS Host | Screen Recording, Accessibility and event posting | Installer-launched Host setup, or opening PLANK Host later. Background workers use non-prompting permission checks. |
| macOS Host | System-audio recording | During Host setup, after screen/input approval. An empty, private process tap exercises macOS consent without capturing application audio, muting speakers or changing output routing. |
| macOS Host | PLANK Camera extension activation | Explicit Host setup, or replacing an already-enabled extension there. Never triggered by a remote camera request. |

Granting permission does not enable optional microphone or camera forwarding.
The existing preferences and toolbar controls still determine that behavior.
The macOS Client does not implement camera capture yet and does not request
camera permission for that unavailable feature.

Denied microphone permission does not prevent the Client launcher or video
session from working. Microphone forwarding is unavailable until permission is
granted. Session creation, reconnect and toolbar toggles never call the
microphone/Input Monitoring request APIs. Command-line autoconnect also does
not request these permissions: provision them through the ordinary launcher.
If a Wacom is attached for the first time after launch, use **Refresh** in the
permissions panel, then **Open Settings** for Input Monitoring before streaming,
or reopen the Client with it attached. Denied permissions
must be changed in System Settings; PLANK does not repeatedly prompt.

## OS-controlled prompts

macOS can require renewed approval for a new account, changed signing identity,
permission revocation or an OS privacy-policy change. Host setup should be
completed for each user. A user who has never opened setup may still encounter
the OS's first-use system-audio prompt when a tap starts. PLANK cannot promise
that a previous user's approval transfers or that a successful tap start proves
consent. The read-only Host `--check-permissions` diagnostic intentionally reports
audio permission as `not-checked`, rather than starting capture to inspect it.

Apple documents system-audio consent at the first start of a recording aggregate
containing a tap; there is no separate consent request in that workflow.
See [Apple's Core Audio tap guide](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

Local Network prompts are triggered by macOS when the app uses the network.
Client bookmark discovery/polling normally begins in the launcher, before the
fullscreen session. PLANK does not send artificial discovery traffic or bypass
an administrator's discovery policy to force a prompt earlier.

On Linux, input-device access is provisioned by package/administrator policy,
not a Client privacy dialog. A Wayland compositor may ask about inhibiting
system shortcuts for the **actual stream window**. That window-specific prompt
cannot be faithfully moved to the launcher; compositor policy controls it.
PLANK authentication and session takeover dialogs are not OS permissions and
remain part of connecting.
