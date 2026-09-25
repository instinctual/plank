# macOS audio tap

Current desktop capture is restricted to PLANK Output with `CATapUnmuted`,
preserving the non-root process allowlist and verified system-alert membership.
Physical outputs play locally. See [PLANK Output](../development/plans/macos-output-device.plan).
ScreenCaptureKit continues to capture desktop video, with its audio output
disabled. Its [stream configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)
has no playback-output device selector in the macOS27 SDK; microphone device
selection is a separate input capability. The Core Audio
[device/stream tap](https://developer.apple.com/documentation/coreaudio/catapdescription/init%28processes%3Adeviceuid%3Astream%3A%29)
restricts capture to audio destined for PLANK Output. This requires separate
audio lifecycle and buffering, but preserves the distinction between local and
remote playback. ScreenCaptureKit itself does not route audio to speakers.
The root LoginWindow worker retains its separate ScreenCaptureKit audio path;
the desktop process tap is never broadened to a global root tap.

The private capture aggregate explicitly uses PLANK Output as its main audio
device and clock. Its only hardware-style subdevice is that virtual null sink;
its only input is the process-scoped stereo tap. Preparation verifies the
selected clock and fails if it differs. The IO callback clears the aggregate's
virtual output buffers. Physical speakers and microphone devices are not members
of this aggregate. This replaces the earlier tap-only aggregate's implicit clock
selection; live recurrence testing of this clock change remains required.

Both virtual audio drivers advertise a 16384-frame zero-timestamp period.
SDK27's `AudioServerPlugIn.h` requires at least10923; the previous480-frame
period violated that contract. This clock interval is separate from HAL IO
buffer size and from the5ms playback/10ms microphone packets. Microphone IPC
still copies480-frame blocks; HAL reads remain bounded by the8192-frame history.
Deterministic driver tests check the SDK minimum, boundary interpolation and
clock generations. Installed distortion recovery still requires a live test.

Capture diagnostics retain HAL sample position, host time and callback time with
each bounded ring entry. The consumer logs timing gaps at exponentially spaced
counts, distinguishing source sample gaps, clock changes and delivery delay.
There is no logging in the HAL callback and no recorded media payload.

The earlier suppression investigation and qualification below describe the
preceding implementation, whose global output scope is superseded.

## Historical local-suppression investigation

Work branch: `macos-audio-tap`, based on main `35ed81f`.

The operator wants the Mac's audio to play through the remote Client, without
simultaneously playing from the Mac's speakers. ScreenCaptureKit does not expose
a local-playback suppression setting. Its `excludesCurrentProcessAudio` setting
only excludes the capturing application's output from the recording.

Apple's public Core Audio process-tap API exposes `CATapMutedWhenTapped`:
local playback is suppressed while a client reads the tap, not by changing the
hardware volume or the user's selected output device. See
[Apple's tap guide](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
and [mute behavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior).
The macOS 27 SDK headers confirm these APIs. This is a proposed audio-only change;
ScreenCaptureKit video, VideoToolbox, transport, Opus and the Client remain intact.

## Qualification before integration

1. Build a separate, signed `PLANK Audio Tap Probe` on the dedicated Mac. Use a
   private stereo tap and private aggregate input. Record only counters/format/
   timing/RMS, never audio samples. Do not replace the installed Host.
2. Establish the separate system-audio TCC grant through the native prompt.
   No permission reset, synthetic approval, microphone access or default-device
   change. Check actual sample rate, chunking and timestamp continuity.
3. Prove local suppression and restoration after stop, failure and process death.
   Callback data alone cannot prove that physical speakers are silent; operator
   confirmation is a gate unless a trustworthy independent output test is found.
4. Integrate only after feasibility. Keep HAL callback work bounded and avoid
   allocation, encoding/network calls or a synchronous hop to the session owner
   that could deadlock during teardown. Preserve sample clock and A/V timing.
5. Qualify silence, active audio, output-device changes, disconnect/reconnect,
   logout/login, permission denial, new audio processes and owner isolation.
   A global probe tap is not approval to capture another user's audio in product.
6. Build a branch-qualified Host candidate and test through the existing Client,
   including an A/V soak. Do not silently retain simultaneous speaker playback
   as a successful fallback if the intended capture path fails.

## Current state

Standalone probe source `32ecdd7` compiled in a clean Mac worktree with macOS
SDK/deployment 27 and warnings-as-errors. Signing from SSH failed with
`errSecInternalComponent`, even after the operator unlocked the login keychain.
The same `codesign` operation succeeded in the desktop's Aqua launchd session.
Thus SSH signing access was the confirmed problem at that point; the earlier
claim that the keychain itself was locked was too strong. No signing identity,
key ACL or partition policy changes. The temporary signing job was removed.

The operator approved the separate system-audio capture permission. Initial
executable SHA256
`06cafe6ab240e209103e72792442f50639154ea830d4380c94620faa413c7b74`
passed silence and an audible signal test: 48000 Hz, stereo interleaved Float32,
flags9, 8 bytes/frame, 512-frame blocks, zero sample/host clock gaps. Maximum
callback age ~10.8 ms. This is capture callback age, not glass-to-glass latency.

Latest probe source `8b59b7e` passes the real QuickTime loop through unchanged
production `PLANKMacOpusEncoder`. The HAL callback copies PCM into a fixed
16-slot ring; the main-queue consumer builds CoreMedia buffers and encodes.
No recording is saved and no Client/transport is involved. The source timestamp
is Core Audio's actual host time, not a manufactured continuous timestamp.
Three ten-second runs, including two fresh restarts, passed: 2007–2018 Opus
packets/run, zero encoder failures, zero ring overflows, zero sample/host clock
gaps, nonzero captured signal. Maximum callback age across runs ~10.9 ms.
All IO stop/destroy, aggregate destroy and tap destroy calls returned success.
Source at `root-audio-tap-probe-3`, app at `audio-tap-probe-3` under the Mac work
root; executable SHA256
`277e158106e4eb8baf0e9368d8f0c64ffb3114164e538e141e6d249e726e350c`.
Build/signing ran in a one-shot Aqua job that has been removed.

Operator-observed held test: source `40018c8` adds `--hold` and graceful
SIGTERM/SIGINT cleanup. Signed executable SHA256
`de2a9e79825237db6171693eaeddbb03ca11ffb58034634cd5842c0401950cb8`.
The operator listened at the physical Mac, reported that sound no longer seemed
to come from its speaker, then requested stop. After exact PID/command validation,
SIGTERM stopped only the probe. The operator confirmed speaker audio returned.
The ~229-second run produced45802 Opus packets, zero encoder failures, overflows
or timestamp gaps; maximum callback age10.957ms. All stop/destroy calls succeeded.
This passes manual normal-stop suppression/restoration, not crash recovery.

The initial probe did not change production code or the installed Host. All
probes have exited. It is distinct from the integrated candidate below.

Product scope must be explicit: SDK27 defines a global tap as *all processes*
and `privateTap` only as visibility to its creator. Neither documents same-user
isolation. Do not infer an authorization boundary from `privateTap` or add a
global root tap to the sign-in worker.

## Integrated candidate 1.0.69-macos-audio-tap

Source `9669c97` is built and installed on the dedicated Mac. Native desktop
capture selects only HAL process objects whose PID resolves through the kernel
to the current non-root real and effective UID. It excludes the Host itself,
rechecks HAL PID identity, and refreshes membership on process-list changes.
Bundle-ID restoration is disabled. No application-name allowlists or polling
loop. The trusted graphical role enables this only for desktop agents; the
root sign-in agent retains SCK audio, as agreed with the operator.

A private aggregate containing only the tap requests48kHz. This does not set
the hardware output's sample rate, volume or default device. Its exact stereo
Float32 format is verified. Unexpected format changes fail capture rather than
reinterpret samples. A bounded16-slot ring transfers input to the serial session
queue. Timestamp validation, Opus encoding and network delivery remain unchanged.
HAL lifecycle calls run on a dedicated control queue, never synchronously on
the session/UI queue. Stop discards buffered audio and completes only after
listener removal and IO/aggregate/tap destruction. A teardown error retires the
worker instead of pretending local playback was safely restored.

The candidate passes SDK/target27 warnings-as-errors, strict Apple signing,
the100000-block concurrent ring test and policy negatives, development-mac ASan/UBSan,
3646 existing Opus checks, frame timing/recovery and development-installer tests.
Its actual tap/Opus component passes live QuickTime capture, appearance/removal
of an additional audio process, and immediate cancellation before startup:
2016 packets in the live run, zero in the cancelled run, no failures.

Installed app/discovery hashes and artifact are in HANDOFF. Await the operator's
real PLANK connection: remote sound, physical speaker suppression, disconnect
restoration, then A/V sync and login/logout tests. The Host may need its own
system-audio TCC approval; Probe consent is not copied. Process-death speaker
restoration and live cross-account isolation remain separate untested gates.

Candidate `1.0.70-macos-audio-tap` (source `3151559`) retains exactly this audio
implementation and adds the shared Client artwork as the native Host app icon.
It is installed on development-mac; signature, resource, version and discovery checks pass.
The operator requested merging into main before release packaging. Component
passes and the earlier manual tap test do not substitute for the integrated
session acceptance gates above.
