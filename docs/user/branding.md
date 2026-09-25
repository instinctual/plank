# PLANK Product Identity

PLANK is the product name shown to end users and administrators. Upstream
Moonlight and Sunshine names remain only where required for source provenance,
license notices, and accurate historical documentation.

## Canonical identities

- Product display name: `PLANK`
- Client display name: `PLANK Client`
- Client application ID: `la.instinctual.Plank.Client`
- Client desktop entry: `la.instinctual.Plank.Client.desktop`
- Client executable and package: `plank-client`
- Host display name: `PLANK Host`
- Host application ID: `la.instinctual.Plank.Host`
- Host executable, package, and service: `plank-host`

The Linux host has no desktop, D-Bus, Flatpak, or AppStream surface. Its canonical
application ID is retained as systemd unit metadata so package and service
inspection distinguish it from a co-installed client. Any future graphical
host application or D-Bus API must use the same canonical host ID.

## Clean-break boundaries

The client uses `Instinctual`, `instinctual.la`, and `PLANK` for its Qt
organization, domain, and application settings namespace. The project has no
deployed legacy clients, so no Moonlight settings migration or compatibility
fallback is carried. Development machines may retain an unused upstream
settings file on disk; new builds neither read nor modify it.

## Artwork

The canonical PLANK artwork set is stored in `branding/assets/`:

- `plank-logo.png` is the original transparent artwork and the Linux Client icon.
- `plank-logo.pxd` is the original artwork's editable source project.
- `plank-host-macos.png` is the approved macOS Host icon: the figure stands
  directly in the desert landscape.
- `plank-client-macos.png` is the approved macOS Client icon: a monitor frames
  the figure and landscape. Neither icon uses an added role badge.
- The retired StationConnect wordmark sources remain available in Git history;
  they are intentionally absent from the active PLANK asset set.

The client submodule carries the required Linux runtime copy at
`apps/client/app/res/plank-logo.png`; the application
embeds it and the Debian package installs it in the hicolor icon theme. Keep
that copy byte-for-byte identical to `branding/assets/plank-logo.png`. The
inherited Sunshine artwork remains temporary until approved host artwork and
usage rules are available. Do not create unrelated visual variants
independently in each fork; keep one approved source asset set and derive
platform formats from it.

## macOS icon packaging

The two macOS PNGs are the operator-approved second concept pair, generated
using the image-generation tool from the original artwork. They are retained
unchanged at 1254×1254; the PXD is not their editable source. The original PNG,
PXD and Linux icon are deliberately unchanged.

The design brief was to integrate the distinction into the main composition:
Host as the figure in an open landscape; Client as a view through a monitor.
Keep the original raised-arm figure, desert, sun and warm orange palette; no
corner badges, alternate-color borders, lettering or secondary pictograms.

`scripts/package/macos-app-icon.m` derives the standard 16–1024 pixel ICNS
representations with Apple's Core Graphics and `iconutil`, without adding
padding, another mask or a nested circle. Host and Client select their own
source PNG. The Client base build creates the icon before development or
distribution packaging, so unsigned, development and signed builds agree.
Both Qt and SDL preserve the bundled icon on macOS. App resources are generated
before signing; do not replace icons inside an already signed/installed app.

`tests/packaging/test-macos-app-icons.py` protects the approved source hashes,
product selection and native ICNS generation/roundtrip. macOS controls the
final Dock/Finder rendering and its icon cache; installed visual acceptance
is separate from asset and packaging tests.
