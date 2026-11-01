# Clipboard sync v1

Status: Mac Client ↔ Linux X11 Host and Mac Client ↔ Mac Host support, including
the 512 KiB hardening, are operator-accepted and merged. Large/interrupted
transfer and lifecycle stress qualification remain separate from broad acceptance.

## Scope

Bidirectional UTF-8 plain text clipboard during an authenticated stream:

| Copy on | Paste on | Shortcut |
|---|---|---|
| Mac | Linux / Flame | `Ctrl+V` in the remote session |
| Linux / Flame | Mac | `Cmd+V` on macOS |
| Mac Client | Mac Host desktop | `Cmd+V` in the remote session |
| Mac Host desktop | Mac Client | `Cmd+V` in a local application |

Images, files, HTML, RTF, Flame-internal formats, and clipboard transfer across
disconnect are outside v1.

## Negotiation

`ClipboardSyncFeature` is launch feature bit `0x400000`.

- Only the macOS Client includes the bit in `plankFeatureFlags`, and only when
  offered by the Host. Linux Clients do not implement clipboard synchronization
  and must not negotiate it or cause the Host to read/transmit clipboard data.
- The Host accepts clipboard traffic only when the authenticated session
  negotiated the bit.
- If absent, no automatic synchronization occurs. The inherited text-injection
  key combination remains available.
- Mac launch schema 3 requires a boolean `clipboard` opt-in. Its `services`
  reply explicitly enables or disables clipboard for that stream. Only the
  authenticated desktop user's worker enables it; the root LoginWindow worker
  returns false. Linux Clients request false, even when discovery advertises
  the Host capability. There is no login-screen clipboard or cross-user lease.

## Transport

`PLANK_CLIPBOARD_WIRE_HEADER` is retained in both common-C header branches.
`plank_clipboard_wire.h` in the native transport include directory provides
platform-independent framing and UTF-8 validation; static assertions prevent
the maintained C header size/limit from drifting.
All header fields use little-endian byte order.

| Lane / type | Direction |
|---|---|
| PLE1 event `PLANK_TRANSPORT_EVENT_CLIPBOARD_OFFER` (5) | Host → client |
| Input `PLANK_TRANSPORT_INPUT_CLIPBOARD_OFFER` (9) | Client → Host |

Each chunk carries `generation`, `totalSize`, `chunkOffset`, `chunkSize`, and
`FIRST` / `LAST` flags. MIME is implicit UTF-8 plain text.

Receivers must:

- require the payload length to equal `sizeof(header) + chunkSize`;
- reject zero-length chunks, unknown flags, nonzero reserved fields, and
  generation zero;
- accept only ordered, contiguous chunks from one generation;
- reject text over 512 KiB (524288 UTF-8 bytes, not characters);
- reject malformed UTF-8, overlong encodings, surrogate code points, values
  above U+10FFFF, and embedded NUL;
- keep inbound and outbound generation counters independent;
- reset generation and partial assembly state for each authenticated session;
- ignore completed generations older than the last applied generation from the
  same sender.

See `tests/protocol/clipboard-sync-v1.json`.

## Client behavior

The macOS Client reads and writes `NSPasteboard` only on the Qt GUI thread.
Its session timer polls every 100 ms while the stream has input focus. A copy made in another
Mac application is sent after focus returns to the stream. Host offers are
retained in a bounded pending value and carry a session epoch so offers
from an earlier connection cannot apply after reconnect.

The client deduplicates repeated Host text only while it still owns that
pasteboard change count; a newer local copy is not suppressed by matching text.
It never compares Host
generations against its independent outbound generation. Failed transport
sends retain the exact unsent chunk and generation for the next poll; newer
local copies supersede unfinished offers. Oversize or embedded-NUL copies are
not truncated, transmitted or reported as successful. One copy is bounded to
65 input chunks. The Qt session timer applies pending Host text on the GUI
thread; transport callbacks never access the pasteboard or queue per-chunk GUI
payloads. Malformed Host offers terminate the affected session.

## Host behavior

The Linux X11 Host watches `CLIPBOARD`, publishes client text as owner of
`CLIPBOARD` and `PRIMARY`, and answers `SelectionRequest` for UTF-8/plain-text
targets. It records each locally forwarded value to prevent repeated offers.
Validated Client offers cross a bounded latest-value inbox; the dedicated
clipboard thread performs all selection reads and writes over a dedicated XCB
connection. New conversions are limited to one per 250 ms. During an active
conversion, X11 events wake the worker immediately, so deletion-acknowledged
INCR chunks do not each incur a 250 ms sleep. Transfers retain the five-second
total deadline and 512 KiB size bound. Waiting is bounded to 250 ms for client
offers and shutdown; if several client offers arrive meanwhile, the newest wins.

Session teardown releases any synthetic selection ownership, destroys the X11
window, and closes the display after clipboard workers stop.

Host outgoing delivery retains one in-flight offer plus the latest local
replacement, sends at most two event chunks per control turn and resumes after
transient native queue pressure. It does not restart a generation or disconnect
video merely because that queue is full.

The Mac Host uses NSPasteboard on the main queue of the existing authorized
desktop worker. At most one AppKit operation is queued; transport and capture
never wait for it. Native permission policy remains in force (no TCC writes or
permission bypass). Scope revocation blocks queued access and transmission.
Teardown clears remotely written text only if its pasteboard change count is
still owned; a later local copy, even of identical text, survives disconnect.
All transfer/assembly state belongs to that one authenticated stream.

## Security and diagnostics

- Traffic is accepted only from the authenticated stream owner.
- Mac → Host automatic sync requires stream input focus.
- Payload contents never enter logs; size and generation may.
- Malformed frames terminate the affected authenticated session.
