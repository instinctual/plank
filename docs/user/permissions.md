# Permissions before connecting

Open the installed **PLANK Client** before connecting, and open **PLANK Host**
on the Mac before its first remote session. Permission approval belongs to the
signed app and the current macOS user. Installing a package is not permission
approval, and PLANK does not modify the system privacy database.

| Product | Permission | When PLANK requests it |
| --- | --- | --- |
| macOS Client | Accessibility for system keyboard shortcuts | Ordinary app launch when shortcut capture is enabled; also when enabling it in Settings outside a session. |
| macOS Client | Microphone | Ordinary app launch, before the bookmark window becomes available. This only requests permission; it does not open a microphone or forward audio. |
| macOS Client | Input Monitoring for raw Wacom forwarding | Ordinary app launch with a supported USB Wacom attached. It reads device metadata without opening or seizing the tablet. |
| macOS Host | Screen Recording, Accessibility and event posting | Opening PLANK Host's setup app. Background workers use non-prompting permission checks. |
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
If a Wacom is attached for the first time after launch, reopen the Client with
it attached to request Input Monitoring before streaming. Denied permissions
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
