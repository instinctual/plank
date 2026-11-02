# Desktop cleanup inventory

Scope: the approved `host-cleanup` pass over both desktop Clients and both Hosts.
This records production callers and build ownership, rather than treating old
names as evidence that code is unused. It is not a claim that every upstream
source in a pinned dependency is part of the shipped executable.

| Area | Removed | Retained and why |
| --- | --- | --- |
| Client connection | Common-C AES-CBC/GCM/OpenSSL/MbedTLS helpers, socket helpers and duplicate name/local-address resolution | `protocol/plank-transport` owns QUIC/TLS; Qt HTTPS owns authentication/trust; common-C still owns media queues, input serialization and callback lifecycle |
| Client presentation | Old EGL/D3D shader assets and ModeSeven font | `streaming/qt` owns the EGL/Metal renderers; `vt_renderer.metal` is loaded by the current Metal resource bundle; Qt shader code is shared with the pixel-value fixture |
| Client packaging | WiX, AntiHooking, DMG/source-archive/Windows dependency tools, inherited prebuilt paths, Qt5 and embedded startup branches | Root `scripts/build` and `scripts/package` own Ubuntu DEB and Mac PKG; native platform APIs, private FFmpeg and Qt stay |
| Client launch | Controller launch parameters, GFE-only status translation, old Mac version-string/schema adapters | Current bookmark choices, profile-specific decoding and schema7 feature negotiation stay |
| Linux display | No-op `display_device` wrapper, libdisplaydevice submodule, dead settings and call sites | `session/host_supervisor.cpp`, topology and display leases own actual physical/virtual layout and restoration |
| Linux capture/encode | Disabled Wayland/KWin/portal/PipeWire sources and protocol submodules, VA-API/Vulkan helpers/options | NvFBC, native X11, DRM/EGL/CUDA interop, x264 and direct NVENC are active; source/capture precision policy is unchanged |
| Host dependency preparation | Implicit prepared-binary downloads and unused SVT-AV1/AMF/VA-API/Vulkan build/link prerequisites | Exact pinned FFmpeg, CBS patches, x264 and CUDA headers stay; Client Vulkan decoding and upstream Loader repair tests are separate |
| Mac launch protocol | External schemas4–6 and automatic release-number compatibility fallback | Schema7 and independently negotiated audio/input/clipboard/microphone/camera features stay; incompatible peers fail explicitly |
| Mac installation | Custom executable Requirements page | Standard Installer plus authorized FileVault preinstall guard; no automatic encryption change |

The earlier pass also removed the Linux fork's superseded macOS backend,
unreferenced GameStream crypto, unused encoder registrations and old upstream
packaging. Native Mac capture/VideoToolbox/audio/input remain in `apps/host/macos`.

## Validation boundary

Focused local tests cover the retained common-C lifecycle/input/queue behavior,
actual Qt packed-color GLSL, selected dependency patches and build/source policy.
All four hosted product builds are required for this pass. HANDOFF records their
current results and exact artifacts; installed GPU, audio, input and display
acceptance is separate.

Inherited public type/file names still occur in active code. Platform-neutral
queue/thread adapters and pinned third-party sources are not removed solely
because they originated upstream. The subsequent approved
[`code-simplification` pass](../plans/code-simplification.plan) removes the Linux
fork's unsupported Windows platform sources, tools, dependencies and settings.
No Windows product support is claimed.
Historical release/protocol records and license attribution remain in Git.
