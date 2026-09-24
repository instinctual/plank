# Microphone forwarding

Linux/macOS Clients can forward microphone input to a compatible macOS Host.
It is not available on Linux Hosts. Host and Client negotiate support; matching
product versions are not required.

In Client **Audio Settings**:

- **Enable microphone:** Manual is the default and starts muted; click the toolbar
  microphone to enable it. Automatic starts the OS-selected recording device
  after an authenticated supported session and any required OS permission.
- **Select PLANK Microphone as host input:** Automatic is the default and temporarily selects the
  virtual input on the Host. Manual leaves the choice to macOS or the application.

Existing saved choices are preserved when upgrading.

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
compatibility are not yet qualified. Audio is stereo, 48 kHz Opus at 192 kbps with
constrained variable bitrate; mono sources retain their source limitations. No extra firewall
port is needed, and normal Host-to-Client sound remains separate. Captured speech
is not written to PLANK logs.

## Candidate test

1. Use headphones and confirm the Client OS input meter responds to speech.
   Connect to the macOS Host with both microphone choices set to Automatic.
2. Confirm the toolbar shows **On**, then check the Host's Sound → Input meter
   for **PLANK Microphone**. Test a recording in an application with its normal
   microphone permission granted.
3. Mute from the toolbar: the Host input should become silent without switching
   to another input. Unmute and confirm speech returns.
4. Disconnect and check that the previous Host input is restored. Repeat with
   Manual activation, then with Manual input selection. A Host input change you
   make yourself during the session should not be undone at disconnect.

Login/logout, takeover, device changes and longer calls remain separate
acceptance checks; a moving input meter alone does not qualify those cases.
