# Native webcam and microphone media forwarding

September 23, 2026. Research branch `native-media-investigation`, based on root
`af71d2b404486a9846bca464ddd646b5ab9c738a`, synchronized with main
`acb29884bff626c9381169fd94563ec79555984c` (product version 1.1.001;
runtime/package source `a4ea39eb6fd0c098ebe01e6eb516747b84c71800`).
This includes hardware inventory, bounded live capture and synthetic framework probes,
not an implemented product capability or end-to-end hardware qualification.

The operator wants each device's native media output preserved through
transport. Native does not mean uncompressed: an MJPEG camera should send its
MJPEG payload, and a microphone exposing native PCM should send that PCM.

## Finding and proposed boundary

The synthetic Mac probe demonstrates unchanged H.264 delivery and decoded NV12
delivery through one virtual camera, including overlapping consumers in both
startup orders. AVFoundation can decode H.264 input for a pixel consumer while
another consumer receives the original coded payload. Direct Linux capture now
confirms native H.264/MJPEG at 720p and 1080p, and USB monitoring confirms native
32 kHz stereo S16LE microphone payloads. PLANK's underlying transport carries opaque bytes.
Product contracts, live-device/network preservation and third-party application
compatibility still require implementation and qualification.

The proposed contract preserves valid media payload bytes from a qualified
Linux capture boundary to Mac reception, before Host decoding or adaptation.
Client decoding, re-encoding, resampling, channel mixing, scaling and effects
are absent from this path. Framing, encryption, packetization and FEC are
transport operations; reconstructed payloads must match the captured bytes.

This is media forwarding, not forwarding USB transactions or device drivers.
The UVC driver assembles media frames. Its optional metadata interface exposes
selected UVC headers and timing, not a complete USB trace. [UVC metadata][uvc]

Transport hashes alone cannot prove an earlier driver or desktop media stage
preserved physical device output. Record and qualify that earlier boundary as
well. Device-internal processing is part of the source; host-side software
conversion must be identified. Exclude unused allocation memory from payloads.

Byte preservation applies to delivered units. Late or unrecoverable units must
be reported as gaps, not replayed as old live media. Mac presentation may need
silence or an unavailable-camera image after a gap, outside the preserved stream.

## Ubuntu webcam

Use direct V4L2 as the reference. Enumerate capture formats, sizes, intervals
and controls. Distinguish video capture nodes from metadata nodes. V4L2 exposes
separate compressed and software-emulated flags: reject emulated formats for
native qualification. Read back the accepted format instead of assuming the
driver honored the request. [V4L2 format enumeration][v4l-formats]

Preserve FourCC, dimensions, frame interval, color/range metadata and layout.
For each buffer retain sequence, timestamp and timestamp flags, and only the
valid payload. `bytesused` differs from allocation length; multi-plane capture
also needs per-plane offsets/bounds. For uncompressed formats, define handling
of padding so uninitialized memory is never sent. [V4L2 buffers][v4l-buffers]

SDL is a possible implementation route, not automatically a conversion layer.
It enumerates supported native camera modes; an MJPG surface can hold JPEG
bytes directly, with payload length in `pitch`. Requesting an unsupported mode
can trigger transparent conversion. Qualify the installed Ubuntu SDL backend
against direct V4L2. Do not infer H.264 support from MJPG support.
[SDL formats][sdl-formats], [SDL camera opening][sdl-open],
[SDL MJPG surfaces][sdl-surface]

| Device output | Forwarding candidate | Main qualification |
| --- | --- | --- |
| MJPEG | Original JPEG frames, decode on Mac | Frame-size peaks, JPEG variants, decode cost |
| H.264 | Original coded data and configuration | Access-unit boundaries, parameter sets, reordering, keyframe recovery |
| Uncompressed pixels | Valid planes plus exact layout | Sustained bandwidth, padding, stride, color interpretation |
| Other/proprietary | No generic support claim | Accessible payload, framing and supported Mac decoder |

Keep any decoder-specific framing adaptation on the Mac after the preservation
check. Require bounded keyframe recovery for inter-frame codecs. If native
output exceeds network capacity, negotiate another device-native mode or report
the limitation; do not silently introduce transcoding. MJPEG can avoid Client
encoding while still requiring substantial bandwidth.

## Ubuntu microphone

The current Client requests 48 kHz mono float PCM from SDL and encodes 480
samples per Opus packet at a 64 kbps target. That request describes PLANK's
application-side format, not the physical microphone's output. Merely removing
Opus does not establish native capture. [Current capture code][capture-code],
[SDL recording format][sdl-audio]

For a device exposing PCM, ALSA's `hw:` interface is the reference: it talks to
the kernel driver without ALSA plugin conversions. Avoid `default`, `plughw`
and conversion/processing plugins in that reference path. Preserve accepted
rate, channel count/order, sample representation, significant bits, container
width, endianness and packing. Packed 24-bit and 24 bits in a 32-bit container
are different layouts. [ALSA hardware plugin][alsa-hw]

Hardware access may conflict with desktop audio-server ownership. A busy device
is a qualification limitation, not justification to stop PipeWire, change global
configuration or silently capture a converted source. Product integration must
respect user selection, normal device access and desktop audio policy.

PipeWire remains a candidate. Its controls include passthrough port
configuration and disabling resampling, but setting one property on PLANK does
not prove every upstream node avoids gain, mixing or format conversion. Verify
the actual graph and negotiated hardware/stream formats. [PipeWire properties][pw]

If the source supplies compressed audio, identify a supported encoded capture
interface for that driver. ALSA compressed offload supports capture capability
queries, but needs driver support and is not a universal microphone bitstream
API. Bluetooth or proprietary sources that expose only decoded PCM need a
separate investigation. [ALSA compressed capture][alsa-compress]

Select microphone transport format from measured device capabilities. Do not
force every native source through the existing Client's 48 kHz mono float
conversion. Necessary adaptation for the current virtual input belongs on the
Mac, after payload verification.

## PLANK integration findings

Maintained inputs after synchronization (Client runtime unchanged):

| Input | Commit |
| --- | --- |
| Shared Client | `cc511584c41c337569a1efd559a7c3362283d9cc` |
| Kymux | `3f7a9d8618978287186e5d6ce0eaa067743cb06c` |
| Linux Host, unchanged | `5829bf7c335440a8b25c3330643eacb4d914f00a` |

- KyProto's media packet carries `Bytes` plus codec, configuration and timing
  information. Source/sink roles can operate in reverse, as microphone does.
  Reuse the authenticated connection and session cancellation scope.
- Audio and video registration share one endpoint-ID allocator. The microphone
  assumes the first Client endpoint is ID 1. Adding camera registration first
  would break that assumption. Negotiate an explicit map/order; never assign
  ID 1 independently to both media types.
- The microphone envelope currently requires mono 480-sample Opus and a maximum
  1,275-byte codec payload. New native formats need negotiation, Host/Client/FFI
  changes, validation and vectors; arbitrary bytes cannot use the Opus label.
  See the [microphone contract](../../../protocol/microphone.md).
- Underlying receive ceilings are 64 KiB for audio and 64 MiB plus 16 bytes for
  video. They are defensive limits, not proposed camera budgets. Derive smaller
  limits from qualified formats and bound dimensions, plane lengths, sample
  counts, codec configuration and pending memory before allocation.
- The audio FEC sender adds 30 percent repair symbols with a minimum of two.
  Small packets can cost substantially more than 30 percent overhead. Measure
  wire/packet rate including FEC; sample-rate arithmetic is only payload rate.

Define a versioned native-format descriptor containing codec/PCM representation,
layout, clock/timebase and unit-size bounds. Units need activation and format
generations, sequence, capture time, duration/sample count and any separate
decode timestamp. Preserve gaps/discontinuities. Retain mute, session ownership,
bounded cancellation and stale-generation rejection. Camera failure must not
stop otherwise healthy desktop audio/video or microphone delivery.

## Mac consumption and synchronization

Receive native payloads in the session worker. Investigate native compressed
delivery to compatible Mac applications alongside decoded-frame delivery for
applications that require pixels. AVFoundation supports compressed capture on
macOS; an empty `AVCaptureVideoDataOutput.videoSettings` dictionary requests
device-native samples, while `nil` requests default uncompressed output. This
does not prove that a particular physical camera's Mac driver exposes its
H.264 mode. [Capture output][av-output], [Native samples][av-native]

A physical USB connection does not guarantee compressed passthrough to an
application. For example, WebRTC's Apple camera capturer requests a pixel
format and consumes image buffers. That capture path does not pass the camera's
original encoded units to its consumer. [WebRTC capture][webrtc-capture]

Apple supports application-fed sink streams and camera source streams through
Core Media I/O camera extensions. The synthetic probe now demonstrates H.264
samples through AVFoundation to a compatible consumer, as well as decoded pixel
buffers. Physical camera bitstreams and third-party applications remain separate
qualification targets. Avoid promising unchanged H.264 through
third-party applications: transport preservation and application passthrough are
different gates. [Apple camera extensions][apple]

### Automatic output selection

The intended behavior is one selectable PLANK camera with automatic format
negotiation, without a user-facing passthrough/decoded preference. Preserve one
native camera stream across the network. If compressed extension delivery is
qualified, expose its actual codec and supported modes to compatible consumers.
For consumers requiring pixels, decode on the Mac and provide a qualified pixel
format. Neither output requires a PLANK video encoder.

Core Media I/O exposes a stream's supported formats and active format index.
Its formats become AVFoundation device formats. The measurements below establish
synthetic H.264 delivery and mixed consumers, with a shared source format.
An application's output pixel format is distinct from the device's active
format: AVFoundation performed the decode in the measured H.264-to-NV12 case.
Do not add a duplicate decoder to that path in PLANK.
[Stream formats][cmio-formats], [Active format][cmio-active],
[Apple camera extensions][apple]

Extend the synthetic compressed, pixel, switching and mixed-consumer tests to
real input and target applications. The extension has a stream-level active
format; do not assume each
consumer can select a different source format concurrently. Start decoding only
when the qualified delivery path needs it, share decoded frames where possible,
and stop decoding when it is no longer needed. H.264 decoder startup or recovery
must use current parameter sets and a usable random-access point, without
replaying an old backlog. Preserve timestamps and signal discontinuities across
changes. Only advertise output modes that pass their delivery tests; a rejected
compressed mode must not be replaced with a newly encoded stream labeled native.

Candidate decoder paths are VideoToolbox for supported H.264 and a qualified
JPEG decoder for MJPEG. Hardware acceleration and physical-device decode remain
unqualified. Signing, activation and permissions pass for the standalone probe;
product installation, upgrades and third-party applications remain gates.

The existing virtual microphone is fixed at 48 kHz mono float; its producer
adjusts samples to track the Mac clock. Initially it could remain the output
format with adaptation on the Mac. That preserves payloads up to Host ingestion,
not necessarily all samples/channels at final application input. Stereo or
multichannel native presentation requires a driver-contract change.
[Driver][driver-code], [Producer][producer-code]

Correlate camera and microphone capture times to a common Client monotonic
timeline and Host presentation. An integrated camera/microphone does not prove
the APIs expose a common clock. Passthrough removes Client codec work, not
device buffering, network jitter, decoding, presentation delay or clock drift.

## Probe sequence and acceptance

1. **Query-only inventory:** identify target and devices; enumerate V4L2 formats,
   intervals and controls; inspect ALSA capture devices and USB audio streaming
   descriptors. Record versions, access and busy state. No streaming/recording.
2. **Select native modes:** read back accepted formats and establish the
   no-conversion capture boundary. Select microphone format from hardware facts.
3. **Bounded preservation probe:** on identified authorized targets, capture an
   approved test scene/sound and hash each valid payload immediately after
   capture and before Mac adaptation. Compare generation, sequence, length and
   digest for recovered units; report lost units separately. Network equality
   and native-capture provenance are distinct checks.
4. **Mac application probe:** test native compressed samples and decoded pixels
   separately, then automatic negotiation, switching and simultaneous mixed
   consumers. Verify original encoded units at the compressed consumer and
   dimensions/color at the pixel consumer; instrument where decoding occurs.
   Adapt audio and verify sample layout, channels and timing. Prove
   camera-extension installation and application consumption independently.
5. **Concurrent qualification:** desktop plus reverse camera/audio; controlled
   loss, unplug, mute, reconnect, takeover and long calls. Measure Client CPU,
   peak/sustained wire rate, latency, queue age, gaps, keyframe recovery and lip
   sync/drift. Beta Mac results require final-release revalidation.

Query-only examples once the target and capture node are selected:

```sh
v4l2-ctl --list-devices
v4l2-ctl --device "${PLANK_CAMERA_DEVICE:?select a capture node}" --list-formats-ext
v4l2-ctl --device "$PLANK_CAMERA_DEVICE" --list-ctrls-menus
arecord --list-devices
```

Also inspect the selected USB audio card's `/proc/asound/cardN/streamN` and
capture `hw_params`, where present. These are descriptor/configuration evidence,
not media captures. Do not run an `arecord` recording merely to query formats
on an active workstation. Missing tools/access remain explicit limitations.
Raw inventory, addresses and private media belong outside Git in protected
private notes/evidence; this document does not install tools or record media.

## Current decision

Query-only inventory of the operator-selected Ubuntu Client is complete.
Deployment identity and raw output are retained privately. The pilot UVC camera
advertises H.264 and MJPEG at 1280x720 and 1920x1080 up to 30 fps; both carry
the compressed flag and neither carries the emulated flag. It also advertises
YUYV, limited to 10 fps at 720p and 5 fps at 1080p. These are enumerated modes,
not proof of successful stream startup or sustained delivery.

The associated USB audio capture descriptors report `S16_LE`, two channels,
16 significant bits, and 16/24/32 kHz native modes. An already-running capture
was at 32 kHz; this investigation did not start or alter it. That native mode
has a calculated payload rate of 1.024 Mbps before protocol/FEC overhead. It
differs from PLANK's current 48 kHz mono float capture request. Preserving it
requires avoiding Client rate/channel conversion as well as bypassing Opus.

The SSH account could read audio descriptors but lacked direct camera-node
access. A bounded read-only V4L2 enumeration used administrator authorization;
it issued only capability/format/size/interval queries. No tools were installed,
device settings changed, streams started or media recorded. This privileged
inventory is not a design for privileged product capture. The desktop-user
access path remains a separate qualification gate. The initial SSH-user query
did not establish the desktop graph; later queries as the active graphical
user identified the selected devices, formats and PLANK routes.

Investigate one qualified native camera mode and one native microphone mode
with unchanged payloads to Mac ingestion. Keep the existing Opus contract
separate; native mode must never silently fall back to transcoding. Desktop
video profile policy remains unchanged.

After the operator selected a Bluetooth headset for both input and output,
read-only queries of the active graphical user's PipeWire graph established
both effective/configured defaults and the existing PLANK links. The headset's
internal input and output nodes were running with codec `msbc`, profile
`headset-head-unit`, and exposed `S16LE`, 16 kHz, mono PCM. The corresponding
USB microphone capture was stopped. This was an observation of existing streams;
no recording, profile switch, route change or new stream was requested.

In headset mode the graph exposes decoded PCM, not mSBC frames: both `Format`
and `EnumFormat` on the internal nodes report raw audio. PLANK's existing input
stream receives 48 kHz mono float, and its playback stream supplies 48 kHz
stereo float to the selected sink. The desktop-facing stereo sink is an
adapter and does not establish stereo Bluetooth delivery; in this mode the
internal Bluetooth output is 16 kHz mono. WirePlumber documents mSBC as a wideband
headset codec and the distinction between headset and A2DP playback modes.
[Bluetooth configuration][wp-bluetooth], [Profile policy][wp-settings]

This establishes a concrete additional native-input case: preserving this
headset's original microphone media means transporting mSBC before PipeWire
decodes it. Forwarding the exposed 16 kHz PCM, even without Opus, does not meet
that original-codec requirement. A supported integration at the Bluetooth/SCO
receive boundary and a qualified Host mSBC decoder must be investigated.
Ordinary PipeWire recording format negotiation on the observed nodes is not
an encoded-mSBC capture API. Do not seize the active Bluetooth transport or
patch a running desktop service to obtain a sample. The probe must also preserve
normal headset playback and profile transitions. Installed versions and raw
graph identities are retained privately.

The operator then selected playback-only mode. The latest graph shows the
headphones in `a2dp-sink-sbc_xq`, codec `sbc_xq`, with an internal 48 kHz stereo
S16LE sink. The headset microphone remains represented by a suspended source,
with no PLANK recording link. The effective/configured input is now the USB
camera microphone at 32 kHz stereo S16LE, linked to PLANK's 48 kHz mono float
input stream. PLANK playback remains 48 kHz stereo float, linked to the
headphones. This confirms the active input changed as well as playback format;
native-mode negotiation must follow the actual source and its generation.
The latest card enumeration advertises SBC and SBC-XQ playback profiles and
CVSD/mSBC headset profiles; no broader device codec support is inferred.

API/code review, pilot descriptors and the bounded captures below support the
approach. H.264 passthrough is a concrete first camera candidate, with native
MJPEG also observed. The currently selected USB microphone delivers native PCM; the
Bluetooth headset microphone has an earlier compressed mSBC boundary when
selected in headset mode. Sustained delivery, keyframe control, physical-input
Mac decode compatibility and PLANK network byte-preservation remain unverified.
A bounded capture-to-receiver probe is next; it must avoid taking
over an active recording or conferencing session.

## Follow-up measurements

### Live native camera and microphone payloads

The operator explicitly authorized activating the physical webcam, and observed
its indicator lights during the bounded test. A preflight found video idle and
the microphone already owned by the desktop audio server. No existing reader
was displaced. Direct V4L2 mmap capture requested four native modes, read back
the accepted format and interval, and collected 90 buffers per mode. There was
no Client video encoder, decoder or libv4l conversion layer in this capture.

| Native mode | Delivered payload | Measured result |
| --- | --- | --- |
| H.264 1280x720, requested 30 fps | 90 Annex B access units with SPS/PPS, IDR and subsequent non-IDR slices | 29.63 fps over buffer timestamps; no error-flagged buffers; one startup sequence gap |
| H.264 1920x1080, requested 30 fps | 90 Annex B access units with SPS/PPS, IDR and subsequent non-IDR slices | 29.67 fps; no error-flagged buffers; one startup sequence gap |
| MJPEG 1280x720, requested 30 fps | 90 complete JPEG frames, matching dimensions, 8-bit precision | 29.99 fps; no sequence gaps or error-flagged buffers |
| MJPEG 1920x1080, requested 30 fps | 90 complete JPEG frames, matching dimensions, 8-bit precision | 29.99 fps; no sequence gaps or error-flagged buffers |

The H.264 SPS describes Baseline profile, level 4.0, 8-bit 4:2:0 and the requested
dimensions. Each captured access unit contains four slices. These webcam formats
are independent of PLANK's desktop video profile policy. Both H.264 runs skip
V4L2 sequence 1 immediately after sequence 0, producing a first timestamp gap of
about 68–72 ms. Their encoded slice frame numbers remain continuous, including
wraparound. This does not establish a lost coded picture; the startup timing
discontinuity remains a qualification finding. The strict no-sequence-gap
criterion therefore fails for H.264 even though native payload delivery and
header parsing succeed. Actual image decode, color and sustained delivery are
not established by parsing alone. [V4L2 compressed formats][v4l-compressed]

For audio, the USB Audio streaming descriptors specify PCM (`wFormatTag=1`),
Type I, two channels, two-byte samples and 16 significant bits. The selected
alternate setting specifies 32 kHz. A three-second `usbmon` observation inspected
only that camera's audio IN endpoint, before desktop audio processing. It
received **3,000 successful isochronous completions, each carrying 128 bytes**:
384,000 payload bytes, or 96,000 interleaved stereo sample frames. Both channels
contained varying, nonzero samples. There were no packet errors, truncated
payloads or dropped monitor events. Thus the observed USB media payload is
S16LE stereo PCM at 32 kHz: **1.024 Mbps before transport overhead**.

This is the kernel's USB completion boundary, not an electrical bus analyzer.
It confirms actual arriving payloads without opening or replacing the busy ALSA
capture stream. `usbmon` is a diagnostic reference, not the proposed product
capture API. A supported native capture path coexisting with desktop audio still
needs implementation and sample-preservation comparison. No audio recording was
saved; only counts, statistics and hashes were retained. [USB monitoring][usbmon]

Afterward, video was closed and the original video format/frame interval were
restored. The microphone retained its original process owner, native parameters
and running state. The temporary USB monitor module was unloaded. Bounded video
samples and raw evidence remain in the private audit directory, outside Git.
No package was installed and no PLANK network preservation or Mac application
test used these physical-device captures yet.

### Camera recovery controls

The pilot camera's standard V4L2 control list did not expose codec controls.
Its USB descriptors do expose the UVC H.264 extension unit. Read-only
`UVCIOC_CTRL_QUERY` calls found GET/SET support for these selectors:

| H.264 extension selector | Purpose | Reported control length |
| --- | --- | --- |
| 1 | Video configuration probe | 46 bytes |
| 9 | Picture type request | 4 bytes |
| 12 | Frame-rate configuration | 6 bytes |
| 14 | Bitrate layers | 10 bytes |

The H.264 extension definition includes requests for IDR pictures with parameter
sets. This provides a concrete candidate for camera-generated recovery frames
and bitrate changes without a Client encoder. GET_INFO/GET_LEN are capability
queries: no SET, capture, reset or control mapping was performed. Actual request
acceptance, latency, recovery after loss and parameter-set handling remain gates.
Resolve the extension unit from its descriptor/GUID; do not hardcode an observed
unit number into product code. [Linux UVC controls][uvc-controls],
[GStreamer's UVC H.264 definitions][uvc-h264]

### Microphone capture boundary

The selected USB microphone's hardware-facing PipeWire format was S16LE,
32 kHz, stereo. Its adapter `PortConfig` was **dsp**, with F32P ports for the two
channels. `EnumPortConfig` advertised none/dsp/convert, without a passthrough
mode. This confirms a conversion boundary upstream of PLANK's current stream.
The default graph rate was 48 kHz; that default alone does not establish every
node's instantaneous processing rate. Device activity also changed between
read-only observations. A later ALSA capability probe declined to open `hw:`
because the capture device was busy; no audio-server ownership was displaced.

Requesting S16LE/32 kHz at PLANK's PipeWire stream would not prove original
hardware PCM was preserved: upstream conversion may already have occurred.
`PW_STREAM_FLAG_NO_CONVERT` controls that stream's conversion, not the entire
graph. Qualify a supported earlier capture boundary with ordinary desktop audio
coexistence, using direct ALSA hardware capture as the reference when idle.
Do not reconfigure the user's global graph to make the result pass.
[PipeWire stream flags][pw-stream], [PipeWire properties][pw]

### Synthetic macOS camera probe

On the authorized Apple Silicon development Mac, macOS27/SDK27, the standalone
probe compiles with warnings as errors and an explicit 27.0 deployment target.
It creates a 320x240 synthetic H.264 fixture. `CMIOExtensionStreamFormat`
construction accepts avc1, NV12/420v, BGRA and JPEG descriptions. VideoToolbox
decodes the fixture to a correctly sized NV12 buffer. Generic secure keyed
archiving fails for all four descriptions, including uncompressed formats;
that diagnostic does not establish compressed extension IPC support or rejection.

The separate extension/consumer probe also compiles. Its single synthetic
camera advertises H.264 and NV12, sends copies of the original coded fixture in
H.264 mode, and lazily decodes that fixture for NV12 mode. The consumer can
request device-native samples or pixels and reports delivered formats, frame
counts and encoded-payload hashes. These are test programs, with no physical
camera, microphone, network or production Host integration.

Developer ID signing, the matching provisioning profile, notarization, stapling,
Gatekeeper assessment and operator-approved activation passed. AVFoundation
enumerated H.264 and NV12 on the exact synthetic device. Camera consent was
granted normally. The consumer pins an explicitly selected source format by
holding the configuration lock through capture; automatic cases leave that
lock unused. On macOS, releasing the lock before session startup allowed
AVFoundation to replace H.264 with NV12. Apple's configuration-lock semantics
explain this behavior. [Device formats][av-formats], [Configuration lock][av-lock]

| Consumer request | Measured result |
| --- | --- |
| Native output, H.264 source pinned | 30 avc1 samples; hash equals extension source; no extension decode |
| NV12 output, H.264 source pinned | 30 NV12 buffers; source stays avc1; no extension decode, establishing framework-side decoding |
| NV12 output, NV12 source pinned | 30 NV12 buffers; extension decodes its fixture once |
| NV12 output, automatic source | 30 NV12 buffers; AVFoundation selects NV12 source |
| Native output, automatic source | NV12 source and 30 image buffers; fails the probe's H.264-output criterion |
| H.264 consumer first, automatic pixel consumer second | 180 unchanged coded samples and 90 NV12 buffers; 2.91 seconds of callback overlap; source stays avc1 and extension decode count stays unchanged |
| Automatic pixel consumer first, H.264 consumer second | 180 NV12 buffers and 90 unchanged coded samples; 2.97 seconds overlap; source changes from NV12 to avc1 while the pixel reader remains active |

The compressed runs matched the source's recorded SHA-256, rather than merely
matching their own preceding frames. Reopening and switching formats completed.
The reverse-order pixel reader spanned 7.28 seconds for 180 frames, versus
5.97 seconds at nominal 30 fps. These results do not qualify seamless switching,
sustained rate, maximum gaps, decoded color or hardware decoding. The H.264 input
is one repeated synthetic keyframe; no network or physical camera is involved.

This supports automatic output adaptation with a stable compressed source where
applications permit it. Advertising H.264 alongside NV12 does not make every
application select compressed input. Empty output settings preserve the selected
source representation; they do not force H.264. Retain a qualified NV12 source
path for consumers that select it, and investigate the transition delay.

See [the probe procedure](native-camera-probe.md) for build inputs, output
interpretation and the application-delivery matrix. Synthetic decode
success does not qualify a physical camera's bitstream, color, sustained rate,
network preservation or audio synchronization.

[uvc]: https://docs.kernel.org/userspace-api/media/v4l/metafmt-uvc.html
[v4l-compressed]: https://docs.kernel.org/userspace-api/media/v4l/pixfmt-compressed.html
[usbmon]: https://docs.kernel.org/usb/usbmon.html
[v4l-formats]: https://docs.kernel.org/userspace-api/media/v4l/vidioc-enum-fmt.html
[v4l-buffers]: https://docs.kernel.org/userspace-api/media/v4l/buffer.html
[sdl-formats]: https://wiki.libsdl.org/SDL3/SDL_GetCameraSupportedFormats
[sdl-open]: https://wiki.libsdl.org/SDL3/SDL_OpenCamera
[sdl-surface]: https://wiki.libsdl.org/SDL3/SDL_Surface
[sdl-audio]: https://wiki.libsdl.org/SDL3/SDL_OpenAudioDeviceStream
[alsa-hw]: https://www.alsa-project.org/alsa-doc/alsa-lib/pcm_plugins.html
[pw]: https://docs.pipewire.org/page_man_pipewire-props_7.html
[pw-stream]: https://docs.pipewire.org/group__pw__stream.html
[uvc-controls]: https://docs.kernel.org/userspace-api/media/drivers/uvcvideo.html
[uvc-h264]: https://github.com/GStreamer/gstreamer/blob/main/subprojects/gst-plugins-bad/sys/uvch264/uvc_h264.h
[alsa-compress]: https://docs.kernel.org/sound/designs/compress-offload.html
[apple]: https://developer.apple.com/videos/play/wwdc2022/10022/
[av-output]: https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput
[av-native]: https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/videosettings
[cmio-formats]: https://developer.apple.com/documentation/coremediaio/cmioextensionstreamsource/formats
[cmio-active]: https://developer.apple.com/documentation/coremediaio/cmioextensionproperty/streamactiveformatindex
[av-formats]: https://developer.apple.com/documentation/avfoundation/capture-device-formats
[av-lock]: https://developer.apple.com/documentation/avfoundation/avcapturedevice/lockforconfiguration()
[webrtc-capture]: https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/capturer/RTCCameraVideoCapturer.m
[wp-bluetooth]: https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/bluetooth.html
[wp-settings]: https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/settings.html
[capture-code]: ../../../apps/client/app/streaming/audio/microphone.cpp
[driver-code]: ../../../apps/host/macos/audio-device/microphone-driver.c
[producer-code]: ../../../apps/host/macos/audio-device/microphone-producer.m
