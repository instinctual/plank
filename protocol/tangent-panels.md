# Tangent panel protocol, version 1

This optional Linux capability preserves TangentHub's USB protocol; it does not
translate panel controls into application shortcuts. Initial qualification is
Element Mf/KnobX1. Other models require explicit descriptor and hardware gates.

HTTPS serverinfo advertises `PlankTangentVersion=1` when the Host process can
open its virtual USB controller. That is an availability hint, not authorization.
After authentication, the Client includes `"tangent":{"version":1}` in PLS1
launch only when it owns the local panel lease. A successful Host response repeats
version1, or version0 if unavailable. Omission leaves the capability disabled.
Old peers and macOS peers do not create a panel endpoint or open USB devices.

The Host creates reliable KyProto data endpoint **8**, after video0, audio2,
input4 and session data6. There is no additional TCP/UDP listener. A panel error
closes only this capability. Ordinary input and media retain their own queues.
Local C ABI14 adds entry points without changing existing structure layouts.

Each data packet contains one complete record. All multibyte record and USB/IP
header values are big endian; the USB control setup block retains USB's little
endian values.

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII `PTNG` |
| 4 | 1 | Version1 |
| 5 | 1 | Attach1, Ready2, Transfer3, Detach4, Failed5 |
| 6 | 1 | Device slot0–7 |
| 7 | 1 | Reserved, zero |
| 8 | 8 | Nonzero attachment generation |
| 16 | bounded | Type-specific body |

The Client announces Attach and monotonically increases generations when reusing
a slot. Ready precedes Host USB requests. Detach is an ordered barrier: finish
local completions before sending it, then retire the slot. Requests already in
flight for a retired generation cannot affect its replacement. Reconnecting QUIC
creates a new generation domain and does not replay queued reports.

Attach contains a 12-byte manifest header: USB device ID32, speed16 (2/full-speed),
reserved16 (zero), USB-descriptor length16 and HID-report length16. The descriptors
follow. At most1024 descriptor bytes and the exact qualified27-byte Mf HID report
are accepted. Device/configuration/interface/endpoint descriptors must match the
qualified Mf shape; enumeration responses must match that same announcement.
USB string descriptors are bounded and forwarded only for normal enumeration;
serial strings and control/input payloads are never logged or stored in bookmarks.

Transfer contains one48-byte USB/IP header and its direction-dependent payload,
at most4096 bytes. Framing uses the outstanding request, not a response-supplied
direction. Per-device accounting permits at most128 outstanding requests and64KiB
of requested payload. Unknown, duplicated, oversized or inconsistent responses
are rejected before reaching VHCI. Only qualified control and interrupt operations
are accepted; vendor/firmware programming and unrelated USB classes are denied.
Cancellation produces RET_UNLINK in place of the original completion and uses an
internal ticket to distinguish a reused USB sequence number.

Ready and Detach have empty bodies. Failed carries a fixed16-bit reason:
1 means attachment unavailable;2 means virtual USB I/O failed. It never contains
peer-supplied diagnostic text. Each direction queues at most128 records/64KiB.
Queue pressure applies backpressure; a permanently blocked optional sender is
retired rather than dropping/replaying control increments or blocking desktop input.

The Client's logical session owns a protected local file lock across QUIC
recovery. It is independent of focus. Its libusb claims and the Host's VHCI
socketpairs are released on session cleanup. The Host never accepts a peer-supplied
sysfs path or port number. Closing its exact socket disconnects that virtual device.

Wire vectors, limits, descriptor mutations, cancellation races and stopped-reader
wakes are tested in `protocol/plank-transport/src/tangent*.rs`. The real C ABI
loopback tests the encrypted lane alongside video/audio/input/control. These
checks do not establish installed-device, hotplug or multi-panel acceptance.
