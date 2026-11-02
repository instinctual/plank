// Hardware-only SHM upload qualification. Uses the production registration owner;
// no X server, screen contents, display configuration, encoder or service changes.
#include "src/platform/linux/cuda_host_registration.h"
#include <cstdio>
#define FFNV_LOG_FUNC(ctx, msg, ...) std::fprintf(stderr, msg, ##__VA_ARGS__)
#define FFNV_DEBUG_LOG_FUNC(ctx, msg, ...) do {} while (0)
#include <ffnvcodec/dynlink_loader.h>
#include <sys/shm.h>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
void check(CUresult result) {
    if (result != CUDA_SUCCESS) throw std::runtime_error("CUDA status " + std::to_string(int(result)));
}
void report(CUresult result, const char* message) { std::fprintf(stderr, "%s%d\n", message, int(result)); }
struct Frame {
    CudaFunctions* driver;
    int segment = -1;
    void* data = reinterpret_cast<void*>(-1);
    CUdeviceptr device = 0;
    CUstream stream = nullptr;
    std::unique_ptr<cuda::host_memory_registration_t> registration;
    ~Frame() {
        if (stream) driver->cuStreamSynchronize(stream);
        registration.reset();
        if (stream) driver->cuStreamDestroy(stream);
        if (device) driver->cuMemFree(device);
        if (data != reinterpret_cast<void*>(-1)) shmdt(data);
        if (segment >= 0) shmctl(segment, IPC_RMID, nullptr);
    }
};
void run(CudaFunctions* driver, const cuda::host_registration_api_t& api, unsigned width) {
    constexpr unsigned height = 2160;
    const std::size_t size = std::size_t(width) * height * 4;
    std::atomic<std::size_t> budget {0};
    Frame frame {driver};
    frame.segment = shmget(IPC_PRIVATE, size, IPC_CREAT | 0600);
    if (frame.segment < 0) throw std::runtime_error("shmget failed");
    frame.data = shmat(frame.segment, nullptr, 0);
    if (frame.data == reinterpret_cast<void*>(-1)) throw std::runtime_error("shmat failed");
    shmid_ds info {};
    if (shmctl(frame.segment, IPC_STAT, &info) || (info.shm_perm.mode & 0777) != 0600) throw std::runtime_error("unsafe SHM mode");
    if (shmctl(frame.segment, IPC_RMID, nullptr)) throw std::runtime_error("SHM retirement failed");
    frame.segment = -1;
    auto* pixels = static_cast<uint32_t*>(frame.data);
    for (std::size_t i = 0; i < size / 4; ++i) pixels[i] = uint32_t(i * 2654435761U);
    std::size_t pitch = 0;
    check(driver->cuMemAllocPitch(&frame.device, &pitch, width * 4, height, 16));
    check(driver->cuStreamCreate(&frame.stream, 0));
    CUDA_MEMCPY2D upload {};
    upload.srcMemoryType = CU_MEMORYTYPE_HOST; upload.srcHost = frame.data; upload.srcPitch = width * 4;
    upload.dstMemoryType = CU_MEMORYTYPE_DEVICE; upload.dstDevice = frame.device; upload.dstPitch = pitch;
    upload.WidthInBytes = width * 4; upload.Height = height;
    for (bool pin : {false, true}) {
        if (pin) {
            frame.registration = cuda::host_memory_registration_t::make(api, frame.data, size, budget, 256U * 1024U * 1024U);
            if (!frame.registration) throw std::runtime_error("SHM CUDA registration unavailable on qualification GPU");
        }
        std::vector<double> timings;
        for (unsigned i = 0; i < 110; ++i) {
            const auto started = std::chrono::steady_clock::now();
            check(driver->cuMemcpy2DAsync(&upload, frame.stream));
            check(driver->cuStreamSynchronize(frame.stream));
            if (i >= 10) timings.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count());
        }
        std::vector<uint32_t> copied(size / 4);
        CUDA_MEMCPY2D download {};
        download.srcMemoryType = CU_MEMORYTYPE_DEVICE; download.srcDevice = frame.device; download.srcPitch = pitch;
        download.dstMemoryType = CU_MEMORYTYPE_HOST; download.dstHost = copied.data(); download.dstPitch = width * 4;
        download.WidthInBytes = width * 4; download.Height = height;
        check(driver->cuMemcpy2D(&download));
        if (std::memcmp(copied.data(), frame.data, size)) throw std::runtime_error("SHM upload changed pixel bits");
        std::sort(timings.begin(), timings.end());
        std::cout << width << "x" << height << " pinned=" << pin << " frames=" << timings.size()
                  << " median_ms=" << timings[50] << " p95_ms=" << timings[95] << " pixel_match=exact\n";
    }
    frame.registration.reset();
    if (budget != 0) throw std::runtime_error("pin budget not released");
}
}
int main() {
    CudaFunctions* driver = nullptr;
    if (cuda_load_functions(&driver, nullptr) || driver->cuInit(0) != CUDA_SUCCESS) return 77;
    void* library = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    cuda::host_registration_api_t api {driver->cuDeviceGet, driver->cuDevicePrimaryCtxRetain,
        driver->cuDevicePrimaryCtxRelease, driver->cuCtxPushCurrent, driver->cuCtxPopCurrent, nullptr, nullptr, report};
    api.register_memory = reinterpret_cast<decltype(api.register_memory)>(dlsym(library, "cuMemHostRegister_v2"));
    api.unregister_memory = reinterpret_cast<decltype(api.unregister_memory)>(dlsym(library, "cuMemHostUnregister"));
    if (!api.register_memory || !api.unregister_memory) return 77;
    CUdevice device = 0; CUcontext context = nullptr;
    try {
        check(driver->cuDeviceGet(&device, 0)); check(driver->cuDevicePrimaryCtxRetain(&context, device));
        check(driver->cuCtxPushCurrent(context));
        for (const unsigned width : {3840, 5120}) run(driver, api, width);
        CUcontext popped = nullptr; check(driver->cuCtxPopCurrent(&popped));
        check(driver->cuDevicePrimaryCtxRelease(device));
    } catch (const std::exception& e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
    dlclose(library); cuda_free_functions(&driver);
}
