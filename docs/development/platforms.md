# Platform boundaries

| Product | Platform | Source | Package integration |
| --- | --- | --- | --- |
| Host | Rocky/RHEL Linux, NVIDIA | `apps/host/linux` | `packaging/host/linux` |
| Host | macOS 26.7+, Apple Silicon; built with SDK27+ | `apps/host/macos` | One Host PKG for macOS26.7 and macOS27 |
| Client | Ubuntu Linux | `apps/client` | `packaging/client/linux` |
| Client | macOS 15+, Apple Silicon; built with SDK27+ | `apps/client` | One Client PKG for macOS15 and macOS27 |

Chris (cnoellert) owns 26.7 Host session qualification. The identical signed Host
package must also pass installed macOS27 acceptance; hosted tests run on 27.
macOS qualification is tracked separately from Linux; beta OS results require
revalidation on the final release. See [acceptance criteria](acceptance-criteria.md)
and the [Mac Client integration gates](macos15-integration-review.md). The common
Mac Client package still needs final live qualification on both OS versions;
this minimum-OS policy is not hardware acceptance. Windows Host/Client remain future work. Do not create
empty platform trees or claim support before implementing and validating them.

Root CMake builds qualification tools and tests, not every product. Linux-only
hardware dependencies are optional there; product binaries retain their existing
native build systems. Use [build runbooks](build/) for actual packages.
