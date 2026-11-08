// Hardware-only capture-pool comparison with real SHM and CUDA registration.
// Synthetic RGB10 pixels only: no X connection, desktop capture, session,
// display changes, encoder or installed service. Idle intervals use wall time.
#include "src/capture_image_pool.h"
#include "src/platform/linux/cuda_host_registration.h"
#include <cstdio>
#define FFNV_LOG_FUNC(ctx, msg, ...) do { (void)(ctx); std::fprintf(stderr, msg, ##__VA_ARGS__); } while (0)
#define FFNV_DEBUG_LOG_FUNC(ctx, msg, ...) do { (void)(ctx); } while (0)
#include <ffnvcodec/dynlink_loader.h>
#include <sys/shm.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
constexpr std::size_t pin_limit = 256U * 1024U * 1024U;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void check(CUresult status) { if (status != CUDA_SUCCESS) throw std::runtime_error("CUDA status " + std::to_string(int(status))); }
void report(CUresult status, const char* message) { std::fprintf(stderr, "%s%d\n", message, int(status)); }

struct Image {
    bool capture_pool_preferred = false;
    int segment = -1;
    void* data = reinterpret_cast<void*>(-1);
    std::unique_ptr<cuda::host_memory_registration_t> registration;
    ~Image() {
        registration.reset();
        if (data != reinterpret_cast<void*>(-1)) shmdt(data);
        if (segment >= 0) shmctl(segment, IPC_RMID, nullptr);
    }
};
using Pool = video::capture_image_pool_t<Image>;

struct Upload {
    CudaFunctions* driver;
    CUstream stream = nullptr;
    CUdeviceptr device = 0;
    std::size_t pitch = 0;
    ~Upload() {
        if (stream) driver->cuStreamSynchronize(stream);
        if (device) driver->cuMemFree(device);
        if (stream) driver->cuStreamDestroy(stream);
    }
    void verify(const Image& image, unsigned width, unsigned height, std::vector<std::uint32_t>& copied) {
        struct Drain {
            CudaFunctions* driver;
            CUstream stream;
            bool complete = false;
            ~Drain() { if (!complete) driver->cuStreamSynchronize(stream); }
        } drain {driver, stream};
        CUDA_MEMCPY2D copy {};
        copy.srcMemoryType = CU_MEMORYTYPE_HOST; copy.srcHost = image.data; copy.srcPitch = width * 4;
        copy.dstMemoryType = CU_MEMORYTYPE_DEVICE; copy.dstDevice = device; copy.dstPitch = pitch;
        copy.WidthInBytes = width * 4; copy.Height = height;
        check(driver->cuMemcpy2DAsync(&copy, stream));
        // Drain before any consumer can return the SHM image to the pool.
        check(driver->cuStreamSynchronize(stream));
        drain.complete = true;
        CUDA_MEMCPY2D readback {};
        readback.srcMemoryType = CU_MEMORYTYPE_DEVICE; readback.srcDevice = device; readback.srcPitch = pitch;
        readback.dstMemoryType = CU_MEMORYTYPE_HOST; readback.dstHost = copied.data(); readback.dstPitch = width * 4;
        readback.WidthInBytes = width * 4; readback.Height = height;
        check(driver->cuMemcpy2D(&readback));
        require(!std::memcmp(image.data, copied.data(), std::size_t(width) * height * 4), "RGB10 upload changed pixel bits");
    }
};

std::shared_ptr<Image> allocate(const cuda::host_registration_api_t& api, std::atomic<std::size_t>& budget, std::size_t bytes) {
    auto image = std::make_shared<Image>();
    image->segment = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0600);
    require(image->segment >= 0, "shmget failed");
    image->data = shmat(image->segment, nullptr, 0);
    require(image->data != reinterpret_cast<void*>(-1), "shmat failed");
    shmid_ds info {};
    require(!shmctl(image->segment, IPC_STAT, &info) && (info.shm_perm.mode & 0777) == 0600, "unsafe SHM mode");
    require(!shmctl(image->segment, IPC_RMID, nullptr), "SHM retirement failed");
    image->segment = -1;
    image->registration = cuda::host_memory_registration_t::make(api, image->data, bytes, budget, pin_limit);
    require(bool(image->registration), "CUDA registration unavailable on qualification GPU");
    image->capture_pool_preferred = true;
    require(budget <= pin_limit, "pin budget exceeded");
    return image;
}

void run(CudaFunctions* driver, const cuda::host_registration_api_t& api, unsigned width, bool retain) {
    constexpr unsigned height = 2160;
    constexpr unsigned cycles = 4;
    const auto bytes = std::size_t(width) * height * 4;
    const auto count = Pool::retention_for_bytes(bytes, pin_limit);
    require(count >= 2, "frame too large for reuse comparison");
    std::atomic<std::size_t> budget {0};
    Upload upload {driver};
    check(driver->cuStreamCreate(&upload.stream, CU_STREAM_NON_BLOCKING));
    check(driver->cuMemAllocPitch(&upload.device, &upload.pitch, width * 4, height, 16));
    std::vector<std::uint32_t> copied(bytes / 4);
    std::vector<double> warm_acquire;
    std::uint64_t allocations = 0, retirements = 0;
    {
        Pool pool(retain ? count : 0);
        for (unsigned cycle = 0; cycle < cycles; ++cycle) {
            if (cycle) std::this_thread::sleep_for(std::chrono::seconds(4));
            std::vector<std::shared_ptr<Image>> consumers;
            for (std::size_t i = 0; i < count; ++i) {
                const auto started = std::chrono::steady_clock::now();
                auto image = pool.acquire([&] { return allocate(api, budget, bytes); });
                const auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
                require(bool(image), "pool failed within capacity");
                if (cycle) warm_acquire.push_back(elapsed);
                auto* pixels = static_cast<std::uint32_t*>(image->data);
                for (std::size_t pixel = 0; pixel < copied.size(); ++pixel) {
                    const auto value = pixel + cycle + i;
                    pixels[pixel] = (value & 1023U) | (((value * 3) & 1023U) << 10) | (((value * 7) & 1023U) << 20);
                }
                upload.verify(*image, width, height, copied);
                consumers.push_back(std::move(image));
                std::this_thread::sleep_for(std::chrono::milliseconds(16));
            }
        }
        allocations = pool.allocation_count;
        retirements = pool.retired_count;
        require(allocations == (retain ? count : count + (cycles - 1) * (count - 1)), "unexpected allocation history");
        pool.clear();
        require(budget == 0, "pin budget leaked after pool clear");
    }
    std::sort(warm_acquire.begin(), warm_acquire.end());
    const auto percentile = [&](double fraction) { return warm_acquire[std::size_t(std::ceil(warm_acquire.size() * fraction)) - 1]; };
    std::cout << width << 'x' << height << " retention=" << (retain ? count : 0)
              << " cycles=" << cycles << " real_idle_seconds=4 pixels_saved=0 pixel_match=exact"
              << " allocations=" << allocations << " retirements=" << retirements
              << " warm_acquire_median_ms=" << percentile(0.5) << " warm_acquire_p95_ms=" << percentile(0.95)
              << " warm_acquire_max_ms=" << warm_acquire.back() << " pin_budget_released=1\n" << std::flush;
}
}

int main() {
    CudaFunctions* driver = nullptr;
    if (cuda_load_functions(&driver, nullptr) || driver->cuInit(0) != CUDA_SUCCESS) return 77;
    void* library = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library) { cuda_free_functions(&driver); return 77; }
    const cuda::host_registration_api_t api {
        driver->cuDeviceGet, driver->cuDevicePrimaryCtxRetain, driver->cuDevicePrimaryCtxRelease,
        driver->cuCtxPushCurrent, driver->cuCtxPopCurrent,
        reinterpret_cast<decltype(cuda::host_registration_api_t::register_memory)>(dlsym(library, "cuMemHostRegister_v2")),
        reinterpret_cast<decltype(cuda::host_registration_api_t::unregister_memory)>(dlsym(library, "cuMemHostUnregister")), report
    };
    if (!api.register_memory || !api.unregister_memory) return 77;
    CUdevice device = 0;
    CUcontext context = nullptr;
    int status = 0;
    try {
        check(driver->cuDeviceGet(&device, 0));
        check(driver->cuDevicePrimaryCtxRetain(&context, device));
        check(driver->cuCtxPushCurrent(context));
        // Alternate order to expose rather than hide first-run effects.
        run(driver, api, 3840, false);
        run(driver, api, 3840, true);
        run(driver, api, 5120, true);
        run(driver, api, 5120, false);
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        status = 1;
    }
    if (context) {
        CUcontext popped = nullptr;
        driver->cuCtxPopCurrent(&popped);
        driver->cuDevicePrimaryCtxRelease(device);
    }
    dlclose(library);
    cuda_free_functions(&driver);
    return status;
}
