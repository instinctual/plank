// Read-only capture timing against the existing depth-30 desktop. Never saves
// pixels, changes display configuration or creates a compositor keepalive.
#include "src/platform/linux/x11_capture_batch.h"
#include <X11/Xlib.h>
#include <X11/extensions/Xcomposite.h>
#include <sys/shm.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
struct Capture {
    Display* display = nullptr;
    Window root = 0, overlay = 0;
    xcb_connection_t* connection = nullptr;
    int segment = -1;
    void* pixels = reinterpret_cast<void*>(-1);
    xcb_shm_seg_t id = 0;
    bool attached = false;
    ~Capture() {
        if (attached) { xcb_shm_detach(connection, id); xcb_flush(connection); }
        if (connection) xcb_disconnect(connection);
        if (overlay) XCompositeReleaseOverlayWindow(display, root);
        if (display) XCloseDisplay(display);
        if (pixels != reinterpret_cast<void*>(-1)) shmdt(pixels);
        if (segment >= 0) shmctl(segment, IPC_RMID, nullptr);
    }
};
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
}
int main() {
    try {
        Capture capture;
        capture.display = XOpenDisplay(nullptr); require(capture.display, "no authorized X display");
        capture.root = DefaultRootWindow(capture.display);
        capture.overlay = XCompositeGetOverlayWindow(capture.display, capture.root);
        XWindowAttributes root {}, overlay {};
        require(XGetWindowAttributes(capture.display, capture.root, &root) &&
                XGetWindowAttributes(capture.display, capture.overlay, &overlay), "no overlay geometry");
        require(root.depth == 30 && overlay.depth == 30 && root.width == overlay.width && root.height == overlay.height,
                "not a matching depth-30 compositor");
        require(root.visual->red_mask == 0x3ff && root.visual->green_mask == 0xffc00 && root.visual->blue_mask == 0x3ff00000,
                "not the qualified RGB10 visual");
        const auto bytes = std::size_t(root.width) * root.height * 4;
        require(bytes && bytes <= 256U * 1024 * 1024, "capture size outside probe limit");
        capture.connection = xcb_connect(nullptr, nullptr);
        require(!xcb_connection_has_error(capture.connection), "XCB connect failed");
        capture.segment = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0600); require(capture.segment >= 0, "shmget failed");
        struct stat authority {};
        const auto* xauth = std::getenv("XAUTHORITY");
        require(xauth && !stat(xauth, &authority), "no authenticated X server account");
        shmid_ds permissions {};
        require(!shmctl(capture.segment, IPC_STAT, &permissions), "SHM permissions unavailable");
        permissions.shm_perm.uid = authority.st_uid; permissions.shm_perm.gid = authority.st_gid;
        permissions.shm_perm.mode = 0600;
        require(!shmctl(capture.segment, IPC_SET, &permissions), "could not grant only X server account access");
        capture.pixels = shmat(capture.segment, nullptr, 0);
        require(capture.pixels != reinterpret_cast<void*>(-1), "SHM map failed");
        capture.id = xcb_generate_id(capture.connection);
        auto* error = xcb_request_check(capture.connection,
            xcb_shm_attach_checked(capture.connection, capture.id, capture.segment, false));
        const bool attached = error == nullptr; std::free(error); require(attached, "X server SHM attachment rejected");
        capture.attached = true;
        require(!shmctl(capture.segment, IPC_RMID, nullptr), "SHM retirement failed"); capture.segment = -1;
        const platf::x11::capture_api_t api {xcb_get_geometry, xcb_get_geometry_reply, xcb_shm_get_image, xcb_shm_get_image_reply, xcb_change_window_attributes_checked, xcb_request_check, xcb_poll_for_event};
        platf::x11::capture_geometry_t cache;
        require(cache.subscribe(api, capture.connection, capture.root, capture.overlay), "geometry subscription failed");
        std::vector<double> baseline, batched, cached;
        for (int round = 0; round < 40; ++round) for (int i = 0; i < 3; ++i) {
            const int batch = (i + round) % 3;
            std::this_thread::sleep_for(std::chrono::milliseconds(16));
            const auto start = std::chrono::steady_clock::now();
            if (batch == 2) {
                require(cache.snapshot(api, capture.connection, capture.root, capture.overlay, 0, 0,
                    root.width, root.height, root.width, root.height, capture.id).valid, "cached reply validation failed");
            } else if (batch) {
                require(platf::x11::capture_batch(api, capture.connection, capture.root, capture.overlay, 0, 0,
                    root.width, root.height, root.width, root.height, capture.id).valid, "batched reply validation failed");
            } else {
                XWindowAttributes r {}, o {};
                require(XGetWindowAttributes(capture.display, capture.root, &r) &&
                    XGetWindowAttributes(capture.display, capture.overlay, &o), "geometry query failed");
                require(r.width == root.width && o.width == root.width && r.height == root.height && o.height == root.height,
                    "topology changed during probe");
                const auto cookie = xcb_shm_get_image(capture.connection, capture.overlay, 0, 0, root.width, root.height,
                    ~0U, XCB_IMAGE_FORMAT_Z_PIXMAP, capture.id, 0);
                auto* reply = xcb_shm_get_image_reply(capture.connection, cookie, &error);
                const bool valid = !error && reply && reply->depth == 30 && reply->size == bytes;
                std::free(error); error = nullptr; std::free(reply); require(valid, "baseline reply validation failed");
            }
            if (round >= 10) (batch == 2 ? cached : batch ? batched : baseline).push_back(
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
        }
        for (auto* values : {&baseline, &batched, &cached}) std::sort(values->begin(), values->end());
        std::cout << "depth30_geometry_and_shm=pass pixels_saved=0 size=" << root.width << 'x' << root.height
                  << " frames_per_case=" << baseline.size() << " original_median_ms=" << baseline[15]
                  << " batched_median_ms=" << batched[15] << " cached_median_ms=" << cached[15] << '\n';
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
