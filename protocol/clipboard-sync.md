# Clipboard sync (draft)

Status: **implemented (v1 text)** — feature flag `0x400000`, host event type 5,
client input type 9.

## Goal

Bidirectional **UTF-8 plain text** clipboard between the Mac client and the
Linux host for the duration of an authenticated stream. Normal copy/paste
shortcuts must work without hidden Moonlight combos.

Operator workflows (v1):

| Copy on | Paste on | Expected shortcut |
|---|---|---|
| Mac (local or synced) | Linux / Flame | `Ctrl+V` in the remote session |
| Linux / Flame | Mac | `Cmd+V` on macOS |

Clipboard sync keeps each side's pasteboard current; paste uses the native
modifier on the side where you paste. Do not rely on `Cmd+V` inside the remote
session for Mac→host paste — Command maps to Linux Super, not Control.

## Non-goals (v1)

- Images, files, HTML, RTF, Flame-internal formats.
- Clipboard across disconnect, login, or between different hosts.
- Administrator-configurable enable (future `host.conf` knob).

## Negotiation

Add a protocol feature bit on `/launch` (`NvOutputTopology::ClipboardSyncFeature`
`0x400000`):

- Client sends `plankFeatureFlags` with `ClipboardSyncFeature`.
- Host echoes acceptance in the launch response. If absent, behavior matches
  today's product: no sync; optional legacy text inject only.

## Wire format

Chunked UTF-8 offers use `PLANK_CLIPBOARD_WIRE_HEADER` in `moonlight-common-c/src/plank.h`.

| Lane | Type | Direction |
|---|---|---|
| PLE1 event `PLANK_TRANSPORT_EVENT_CLIPBOARD_OFFER` (5) | Host → client |
| Input `PLANK_TRANSPORT_INPUT_CLIPBOARD_OFFER` (9) | Client → host |

Each chunk carries `generation`, `totalSize`, `chunkOffset`, `chunkSize`, and
`FIRST`/`LAST` flags. MIME is implicit UTF-8 plain text.

Rules:

- Maximum payload **1 MiB** UTF-8 after validation.
- Monotonic `generation` per sender; ignore offers older than the last applied
  generation from that side.
- Do not log payload contents in client or host diagnostics; log size and
  generation only.
- Rate limit: at most one offer per second per direction unless generation
  changes (debounce pasteboard churn).

## Client (macOS)

While streaming and feature negotiated:

1. Observe `NSPasteboard` general pasteboard changes → send `clipboard_offer`.
2. On host `clipboard_offer` → replace general pasteboard string (plain text).
3. `Cmd+V` with stream focused: paste from local pasteboard (synced or local).
4. On disconnect: stop observers; do not leave host text on pasteboard.

Replace reliance on `Ctrl+Option+Shift+V` (`KeyComboPasteText`) for normal
workflows once sync is active. Retain the combo as a fallback when negotiation
fails.

## Host (Linux/X11)

While media session active:

1. Observe `CLIPBOARD` selection changes on the session `DISPLAY`.
2. On change → send `clipboard_offer` with UTF-8 text.
3. On client offer → set `CLIPBOARD` and `PRIMARY` (when applicable) for the
   session, using the same toolkit path Flame expects.

Session cleanup must not leave synthetic selections after disconnect.

## Security

- Offers accepted only from the authenticated stream owner.
- Reject binary-looking payloads that fail UTF-8 validation.
- No automatic sync when the client window lacks input focus (Mac → host path).

## Tests

- Protocol vectors under `tests/protocol/clipboard-sync-v1.json` (TBD).
- Client unit tests: generation ordering, size limit, MIME gate.
- Host unit tests: UTF-8 validation, reject over limit.
- Live gate on dxs-flame-06: round-trip sentence Mac ↔ gnome-terminal ↔ Mac.
