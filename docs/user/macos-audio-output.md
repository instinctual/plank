# macOS remote audio output

During a remote desktop session, **PLANK Output** appears as the Mac Host's
selected playback device in System Settings → Sound → Output. Sound plays on
the Client's selected speakers or headphones. PLANK Output has no local speaker
or loopback microphone.

PLANK selects this device after remote audio starts. Its initial volume and mute
follow the previous output; adjustments during the session affect remote
playback without changing the physical output's controls. Client playback volume
also affects the final listening level. Applications with their own output menu
can select PLANK Output explicitly.

Disconnecting restores the previous playback and sound-effect devices unless
you changed those selections yourself. If an original device was unplugged,
PLANK uses an available built-in output. A device you selected manually before
connecting remains your selection afterward. PLANK Output is silent without an
active remote audio session.

Install the updated Host and restart when convenient to load its audio devices.
The installer lets you defer restarting. If PLANK Output is unavailable, the Host
retains its existing remote audio capture, and macOS may continue displaying the
physical output's name. This Host feature uses the existing desktop audio
connection and does not require another Client update.

Client microphone forwarding is separate; see [microphone forwarding](microphone.md).
