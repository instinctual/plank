# Tangent panel protocol, version 1

Ubuntu Clients forward Tangent Element panels to Rocky Linux Hosts. TangentHub
interprets the controls and drives the displays and lamps. Each attached panel
keeps its own USB identity and slot.

| Panel | USB vendor and product |
| --- | --- |
| Element Mf and KnobX1 Mf emulator | `04d8:fa1a` |
| Element Tk | `04d8:fa1c` |
| Element Kb | `04d8:fa1e` |
| Element Bt | `04d8:fa1f` |

HTTPS serverinfo advertises `PlankTangentVersion=1` when the Host process can
open its virtual USB controller. After authentication, a Client that owns the
local panel lease requests `"tangent":{"version":1,"element_series":true}`.
The Host confirms both fields when available. If either peer omits the extension,
the session supports Mf only. Version zero or an omitted capability disables
forwarding. The record format and endpoint number stay at their original values.

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
follow. Up to 1024 descriptor bytes and the measured 27-byte Element HID report
are accepted. The configurations must expose the qualified interrupt endpoints
(15-byte input and 64-byte output); enumeration responses must match that same announcement.
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

At the Host, each panel can forward up to 32 USB submissions and reserve one
cancellation per forwarded submission. Up to 64 additional submissions wait in
arrival order. Active and waiting payloads each have a 32 KiB limit. Completion
automatically releases the next eligible submissions. The Host can always read
an unlink, even when all outstanding interrupt reads are idle. If both windows
are exhausted, the local USB caller receives ENOSPC for that unissued submission.
A queued cancellation never touches the physical device. A running libusb read
observes cancellation between its bounded USB calls. Each produces one completion.

Ready and Detach have empty bodies. Failed carries a fixed16-bit reason:
1 signals a temporarily unavailable attachment, 2 signals a device I/O failure,
and 3 identifies an unsupported profile. Each direction queues at most128 records/64KiB.
Queue pressure applies backpressure; a permanently blocked optional sender is
retired rather than dropping/replaying control increments or blocking desktop input.

A local USB or VHCI fault retires only the affected generation. The Client retries
temporary claim, worker and Host attachment failures after 1, 2, 4, 8, 16 and then
30 seconds while the device stays connected. A stable attachment clears the delay.
An unsupported descriptor is held until unplug. Invalid bus framing or a transport
that cannot deliver a generation barrier can still retire the entire panel lane.

The Client's logical session owns a protected local file lock across QUIC
recovery. It is independent of focus. Its libusb claims and the Host's VHCI
socketpairs are released on session cleanup. The Host never accepts a peer-supplied
sysfs path or port number. Closing its exact socket disconnects that virtual device.

Wire vectors, limits, descriptor mutations, cancellation races and stopped-reader
wakes are tested in `protocol/plank-transport/src/tangent*.rs`. The real C ABI
loopback tests the encrypted lane alongside video/audio/input/control. These
checks do not establish installed-device, hotplug or multi-panel acceptance.
