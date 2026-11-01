# Local Cursor Protocol

For Linux Hosts, PLANK presents the host pointer as a compositor-owned cursor
on the client. The host cursor is never composited into negotiated PLANK
video frames. This gives the streamed desktop and the native toolbar one local
pointer and removes any remote/local cursor handoff at the toolbar boundary.

The host advertises `LI_FF_LOCAL_CURSOR` (`0x40`) and the client advertises
`ML_FF_LOCAL_CURSOR` (`0x10`). Both bits mean support for the complete
PLANK cursor protocol: shape, hotspot, and host-authoritative tablet
position. Both are mandatory. A missing bit is a connection error; there is no
embedded-video cursor fallback, compatibility mode, configuration switch, or
migration path.

The macOS Host has a distinct, explicitly negotiated embedded
cursor contract; see `docs/architecture/macos-input.md`. It does not advertise these local
cursor bits. This platform choice does not relax either Linux requirement or
permit a missing Linux cursor capability to select an embedded fallback.

Cursor images travel on the encrypted, reliable control stream as message
`0x5507`. Each payload begins with `PLANK_CURSOR_WIRE_HEADER` from
`plank.h`. All integer fields are little-endian. Pixels use
premultiplied 32-bit ARGB8888 values in row-major order. The header carries the
exact XFixes cursor serial as `generation`, image dimensions, hotspot,
visibility, total image size, and the offset and size of the current chunk.

The first and final packets of an image set `PLANK_CURSOR_FLAG_FIRST_CHUNK` and
`PLANK_CURSOR_FLAG_LAST_CHUNK`. Chunks for one generation are reliable and
ordered, but the client still validates offsets and discards an incomplete or
superseded generation. Dimensions are limited to 512 by 512 and each control
chunk to 48 KiB. These limits permit large custom Flame cursors without
overflowing the 16-bit encrypted-control payload length.

The host sends its authoritative cursor hotspot position as message `0x5508`.
Each payload is one `PLANK_CURSOR_POSITION_WIRE_MESSAGE`. Position packets use
the encrypted control channel without retransmission and carry a monotonically
increasing sequence number, so delayed or reordered samples are discarded.
Coordinates are encoded-frame pixels after the host capture canvas has been
aspect-fit into the negotiated video frame. This accounts for host capture
letterboxing before the client maps the position through its presentation
letterboxing.

The host obtains the exact cursor bitmap, hotspot, and root position from XFixes, including
custom and animated application cursors. It sends an initial image after the
control peer is ready and sends a replacement whenever the X cursor serial
changes. A fully transparent cursor is sent with visibility cleared. Cursor
hotspots on transparent Xorg placeholder images are normalized into the image
bounds because they have no visible semantic meaning. For ordinary mouse input,
the Client OS cursor remains authoritative. For raw-HID Wacom input,
the client displays the latest host-authoritative position in an
input-transparent Qt scene item. This preserves the host Wacom driver's
pressure and Tablet Margins mapping. The next physical mouse motion restores
the OS cursor.

Qt owns the session surfaces and their native lifetime. Cursor image, position
and visibility changes update the Qt scene independently of new decoded video;
there is no separate application-owned Wayland cursor subsurface or anchor.
The session's current crop, scaling and output geometry maps the Host hotspot
and cursor image into the correct local scene.

The client assembles and validates a complete generation before replacing both
the OS cursor image and the input-transparent Wacom cursor item. Transport
callbacks publish validated updates; Qt applies cursor images and positions on
the GUI thread. While the pointer belongs to the toolbar or reconnect controls,
the Client uses its local arrow cursor.
No path warps or synthesizes local pointer motion. Buttons, wheel events, and
motion over the toolbar remain exclusively local and never reach the host.
