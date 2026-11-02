#include "src/platform/linux/cuda_host_registration.h"
#include <cassert>
#include <iostream>
#include <vector>
#include <thread>

namespace {
thread_local std::vector<int> calls;
thread_local int failure = 0;
thread_local int registered = 0, retained = 0, pushed = 0;
CUcontext context = reinterpret_cast<CUcontext>(1);
CUresult result(int step) { calls.push_back(step); return failure == step ? CUDA_ERROR_UNKNOWN : CUDA_SUCCESS; }
CUresult CUDAAPI device(CUdevice* d, int ordinal) { assert(ordinal == 0); *d = 0; return result(1); }
CUresult CUDAAPI retain(CUcontext* c, CUdevice) { *c = context; const auto r = result(2); if (r == CUDA_SUCCESS) ++retained; return r; }
CUresult CUDAAPI release(CUdevice) { --retained; return result(8); }
CUresult CUDAAPI push(CUcontext c) { assert(c == context); const auto r = result(3); if (r == CUDA_SUCCESS) ++pushed; return r; }
CUresult CUDAAPI pop(CUcontext* c) { *c = context; --pushed; return result(5); }
CUresult CUDAAPI reg(void* data, std::size_t size, unsigned flags) {
    assert(data && size && flags == 1); const auto r = result(4); if (r == CUDA_SUCCESS) ++registered; return r;
}
CUresult CUDAAPI unreg(void* data) { assert(data && registered > 0); --registered; return result(6); }
void report(CUresult status, const char*) { assert(status != CUDA_SUCCESS); }
}
int main() {
    const cuda::host_registration_api_t api {device, retain, release, push, pop, reg, unreg, report};
    std::atomic<std::size_t> budget {0};
    char data[128] {};
    for (failure = 0; failure <= 5; ++failure) {
        calls.clear();
        auto memory = cuda::host_memory_registration_t::make(api, data, 128, budget, 256);
        assert(bool(memory) == (failure == 0));
        if (memory) {
            assert(registered == 1 && retained == 1 && pushed == 0 && budget == 128);
            assert((calls == std::vector<int>{1, 2, 3, 4, 5}));
            memory.reset();
            assert((calls == std::vector<int>{1, 2, 3, 4, 5, 3, 6, 5, 8}));
        }
        assert(!registered && !retained && !pushed && budget == 0);
    }
    failure = 0;
    for (const std::size_t size : {0U, 257U, 0xffffffffU}) {
        calls.clear();
        assert(!cuda::host_memory_registration_t::make(api, data, size, budget, 256));
        assert(calls.empty() && budget == 0);
    }
    auto first = cuda::host_memory_registration_t::make(api, data, 128, budget, 256);
    auto second = cuda::host_memory_registration_t::make(api, data + 64, 128, budget, 256);
    assert(first && second && budget == 256);
    calls.clear();
    assert(!cuda::host_memory_registration_t::make(api, data, 1, budget, 256));
    assert(calls.empty() && budget == 256);
    first.reset(); second.reset();
    assert(budget == 0 && !registered && !retained && !pushed);
    // The same budget is reusable after retirement and after every failed init.
    assert(cuda::host_memory_registration_t::make(api, data, 256, budget, 256));
    assert(budget == 0);
    std::atomic<unsigned> successes {0};
    std::vector<std::thread> threads;
    for (unsigned i = 0; i < 8; ++i) threads.emplace_back([&] {
        char buffer[128] {};
        for (unsigned attempt = 0; attempt < 1000; ++attempt) {
            auto memory = cuda::host_memory_registration_t::make(api, buffer, sizeof(buffer), budget, 256);
            assert(budget <= 256);
            if (memory) { ++successes; std::this_thread::yield(); }
        }
        assert(!registered && !retained && !pushed);
    });
    for (auto& thread : threads) thread.join();
    assert(successes > 0 && budget == 0);
    std::cout << "CUDA SHM registration rollback, context lifetime and budget passed\n";
}
