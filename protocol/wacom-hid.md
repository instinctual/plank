# Raw Wacom HID Redirection

## Goal

Mirror the Wacom tablet selected on the client instead of presenting a fixed
PLANK tablet profile. The host must receive the client's HID report
descriptors and USB identity, create one UHID endpoint per HID interface, and
let the stock `hid-wacom` stack interpret reports. Never scale or reinterpret
raw report fields in this path.

## Device Group

The client groups HID interfaces by their common USB device parent. An attach
transaction carries a session-local device ID, generation, bus, vendor,
product, version, country code, name, physical path, serial-presence flag, and
the original descriptor for every interface. Descriptor size is limited to
`HID_MAX_DESCRIPTOR_SIZE`; report payloads are limited to `UHID_DATA_MAX`.
The serial value is sensitive and must remain inside the authenticated,
encrypted session.

The host creates every interface with the same physical group ID. It accepts
the group only when all descriptors validate and every UHID endpoint reaches
`UHID_START`; otherwise it destroys the entire group and selects the normalized
core-pen fallback.

## Wire Framing

Production messages use protocol version 2 and begin with the packed 20-byte
`PLANK_RAW_HID_WIRE_HEADER` from `plank.h`. All integer fields are
little-endian. The header carries magic `PLWH`, message type, interface index,
device generation, transaction ID, and payload length. The client sends the
frame through the native KyProto reliable input endpoint as
`PLANK_TRANSPORT_INPUT_RAW_HID_WACOM`; the Host replies through its reliable
event endpoint as `PLANK_TRANSPORT_EVENT_RAW_HID_WACOM`. Both paths
require the authenticated encrypted connection. Descriptors and reports
are capped at 4096 bytes, a group at 16 interfaces, and stale generations are
rejected.

## Ordered Messages

All lifecycle and control messages are reliable and ordered:

- `tablet-attach` / `tablet-attach-result`
- `tablet-input-report` with interface ID, sequence, and the
  unchanged report bytes
- `tablet-get-report` / `tablet-get-report-result`, correlated by transaction ID
- `tablet-set-report` / `tablet-set-report-result`, correlated by transaction ID
- `tablet-output-report` for host-to-client `UHID_OUTPUT`
- `tablet-open`, `tablet-close`, and `tablet-detach`
- `tablet-suspend`, which stops transport delivery without removing the host
  UHID endpoints

The client answers control requests with `HIDIOCGFEATURE`, `HIDIOCSFEATURE`, or
the corresponding input/output-report ioctl on the original `hidraw` node.
Errors and returned lengths must be preserved. The host must never synthesize a
successful feature reply.

Transport backpressure does not mean acceptance. The sender retains the exact
message and its order on `PLANK_TRANSPORT_TIMEOUT`. Client input retries for at
most two seconds; input/callback ingress and Host feedback queues wait at most
100 ms for capacity. Unrecoverable pressure ends the session and invokes input
cleanup instead of silently losing a tip, button, feature request or attach
acknowledgement. Queues remain bounded. These are failure limits, not delays
added to uncongested input. Consecutive cursor positions may replace one
another; raw tablet reports and lifecycle/control messages may not.

Linux feature-report ioctls run on a separate bounded worker, outside capture
and callback locks. Each job owns a duplicated device descriptor. Focus loss,
reconnect and teardown invalidate queued work and old completions. A running
kernel ioctl cannot be forcibly cancelled; it owns no Client object and cannot
publish a stale reply. The Host completes outstanding kernel GET/SET requests
with `ENOTCONN` when their transport generation retires. New requests received
while suspended receive that error immediately.

The experimental macOS Client uses `IOHIDDeviceGetReport`/`IOHIDDeviceSetReport`
on the corresponding physical interface. It converts Linux UHID report types
to IOKit types and retains numbered report IDs. For unnumbered feature/control
reports, the synthetic Linux zero-ID slot is removed before IOKit and restored
on GET replies. Native failures are returned as Linux errno values; logs record
native status codes without report data or device serials.

## First-generation Intuos Pro fallback

Linux UHID cannot reproduce the USB-interface type required by `hid-wacom` for
the first-generation Intuos Pro S/M/L family. The client therefore recognizes
the complete PTH-x51 USB product family (`056a:0314`, `056a:0315`, and
`056a:0317`) and selects the normalized core-pen path instead of attempting an
unusable raw attachment. That fallback carries absolute position, tip,
pressure, tilt, eraser, and up to three pen buttons. It intentionally does not
represent ExpressKeys, the ring, or touch. Other in-scope Wacom product IDs are
treated as newer descriptor-driven devices and continue through exact raw-HID
forwarding; pre-Intuos-Pro devices are outside the product scope.

## Ownership and Cleanup

Raw access is granted only to the active local session. Once attach succeeds,
the client exclusively grabs every pen, pad, and touch event node belonging to
the USB group so local desktop input cannot occur in parallel. Client focus
loss sends `tablet-suspend`, releases the local grabs, and closes the physical
nodes while the host keeps its UHID endpoints and XInput identities. Focus
return starts a new generation; byte-identical USB identity and descriptors
reactivate fully started retained endpoints without recreating them. An
interrupted initial probe is not treated as a ready tablet; an incomplete
group may be recreated. This is required
because Autodesk Flame caches XInput device IDs.

A physical hot-unplug, HID I/O error, changed USB identity or descriptor, or
explicit final device teardown remains destructive and sends `tablet-detach`.
An ordinary resumable stream disconnect also suspends transport and retains the
same endpoints. Stale reports from an older or suspended generation are
discarded.

On macOS, a dedicated HID run loop exclusively opens every interface with
`kIOHIDOptionsTypeSeizeDevice` before sending the grouped attachment. A partial
open or rejected/timed-out attachment releases the entire group. Report I/O and
device closure stay on that worker; focus loss and reconnect use a release
barrier before the old control channel is stopped. No driver is disabled or
reconfigured. The host remains responsible for tablet coordinates; a passive
Mac cursor view displays the host's reported cursor position. The first-generation
normalized fallback is not implemented on Mac; those device IDs are excluded
from the Mac raw path rather than represented as supported.

## Reconnect Barrier

Before replacing a PLANK control stream, the client suspends raw-HID
delivery and closes its physical tablet handles while the old reliable channel
still exists. The raw-tablet worker remains behind a reconnect barrier during
authentication, host display transitions, and input-stream initialization. It
may start one fresh attachment only after the replacement connection reports
success. This ordering prevents an early valid attachment from being discarded
by reconnect cleanup.

Linux attachment waits at most fifteen seconds for `tablet-attach-result`,
allowing for kernel/USB feature queries. If that reliable acknowledgement is
unavailable, the client closes the local transaction and retries with a new
generation. Fully started Host endpoints are reused when identity and
descriptors match, so acknowledgement recovery does not change those
application-visible XInput device identities. macOS retains its own attachment
deadline and HID-worker lifecycle.

## Acceptance

Compare physical-client and virtual-host nodes for VID/PID/version, interface
count, axis ranges and resolution, pressure, tilt, distance, tool identity,
pad controls, and touch geometry. Exercise feature/output reports, pen and
eraser proximity, ExpressKeys, ring, multitouch, hot-unplug, reconnect, and
abrupt network loss. Flame Tablet Margins and edge gestures must work without
pre-scaling coordinates, preference watchers, or Xorg changes.

Include tip/barrel-button transitions during induced transport backpressure,
focus loss with a feature query in flight, and touch-down followed by lifting
while forwarding is suspended. The existing evdev cleanup clears input-core
contact, but is not proof that every hid-wacom model's private arbitration
cache is reset. That last case still requires real-kernel qualification; do
not fabricate model-specific neutral reports or destroy healthy UHID identities
as a speculative remedy.

## Qualification Bridge

`plank-wacom-raw-bridge` implements this lifecycle as a one-client hardware
probe. Its TCP transport is intentionally rejected as a production boundary:
it is plaintext, has no session authentication, and must run only on an
isolated qualification network. The PTH-660 live test passed descriptor,
input, feature, output, exclusive-grab, and disconnect behavior through this
bridge. Production code must reuse the behavior, limits, and cleanup rules
above inside PLANK's authenticated encrypted native transport.
