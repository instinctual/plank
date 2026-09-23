# Microphone forwarding

The `microphone-forwarding` candidate adds Linux/macOS Client microphone input
to a macOS Host. It is not available on Linux Hosts. Install matching candidates;
do not mix them with pre-RaptorQ-2 packages.

In Client **Audio Settings**, both choices default to Automatic:

- **Enable microphone:** Automatic starts the OS-selected recording device
  after an authenticated supported session and any required OS permission.
  Manual starts muted; click the toolbar microphone to enable it.
- **Select PLANK Microphone as host input:** Automatic temporarily selects the
  virtual input on the Host. Manual leaves the choice to macOS or the application.

The toolbar microphone shows On, Off, Wait or N/A. Hover over it for an
explanation. Muting stops Client recording and supplies silence on the Host;
it does not switch to a physical Host microphone. Disconnect stops forwarding.
The user's mute choice survives the session's automatic reconnection.

Applications with their own input selector may need **PLANK Microphone** selected
explicitly. On disconnect, automatic selection restores the prior available
device only if PLANK is still the default; a later manual selection is preserved.

macOS Clients use the normal Microphone permission prompt. If access was denied,
enable PLANK Client under System Settings → Privacy & Security → Microphone and
reconnect. The Host package installs the virtual input driver. If it is not
listed after installation, restart the Host when convenient; the installer does
not interrupt active system audio to force a reload.

Start testing with headphones. Echo cancellation and conferencing-application
compatibility are not yet qualified. Audio is mono, 48 kHz Opus; no extra firewall
port is needed, and normal Host-to-Client sound remains separate. Captured speech
is not written to PLANK logs.
