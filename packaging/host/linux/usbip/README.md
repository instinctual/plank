# Bundled Linux USB/IP controller

TangentHub uses libusb to discover USB devices. The Linux Host needs the standard
USB/IP VHCI controller to present a Client panel as USB. Rocky 9.7 does not ship
that controller even though its kernel configuration selects it.

The operator selected shipping the actual driver in the ordinary PLANK Host RPM.
The pinned ELRepo 9.7 build passed the initial installed module/KnobX1/TangentHub
qualification. Both its binary and corresponding source RPM signatures were
verified against ELRepo's independently published signing-key fingerprint before
recording [these immutable inputs](inputs.json).

The build-time staging script compresses the module without changing its signed
contents. This also protects its embedded signature from RPM's normal ELF
stripping. A finished-package check verifies the decompressed bytes. It includes
the **complete corresponding source RPM**, containing
the source archive, build spec, Makefile, patch and GPLv2 license, in the product
documentation. No source offer, external repository enablement or download at
installation time is needed to obtain those sources. The public ELRepo source
and binary archives are small, checksum-pinned build inputs and must be cached.

The module is GPLv2, from the Linux USB/IP project and ELRepo. Its copyright and
license notices are preserved in the corresponding source archive. PLANK's
application license does not replace the module's license. The original RPM's
scriptlets are never executed during extraction or product installation.

The module targets the recorded Rocky 9.7 kernel ABI. Kernel symbol/version
checks remain enabled. Never force-load it, update the Host kernel/NVIDIA driver
to satisfy it, or silently substitute a module built for another EL minor.
Secure Boot-enabled installation is not yet qualified. Module availability and
load failures must disable panel forwarding with a useful diagnostic, rather
than preventing ordinary PLANK sessions.

The product packaging owns the module and corresponding source/license
files, refreshes only its module links at upgrade/removal, and preserves unrelated
USB/IP users. Installing a driver does not authorize opening arbitrary USB
devices or running an unauthenticated USB/IP listener.

For implementation and acceptance status, see
`docs/development/plans/tangent-panel-forwarding.plan` in the PLANK source tree.
