#include "gpuinteropcheck.h"

#include <QOpenGLContext>
#include <QOpenGLExtraFunctions>
#include <QDebug>
#include <libplacebo/vulkan.h>
#include <array>
#include <cstring>

void reportQtGpuInteropCapabilities()
{
    auto* context = QOpenGLContext::currentContext();
    if (!context) return;
    const bool memory = context->hasExtension("GL_EXT_memory_object_fd");
    const bool semaphore = context->hasExtension("GL_EXT_semaphore_fd");
    qInfo("Qt GL external memory=%d external semaphore=%d (capabilities only)", memory, semaphore);
    // Mesa software renderers are allowed here solely to determine what the
    // hosted runner can exercise. Never use this as product device selection.
    auto params = pl_vulkan_default_params;
    params.allow_software = true;
    pl_vulkan vk = pl_vulkan_create(nullptr, &params);
    if (!vk) { qInfo("Qt interop qualification unavailable: no Vulkan test device"); return; }
    qInfo("Qt Vulkan opaque FD texture=%d semaphore=%d DMA-BUF texture=%d",
          bool(vk->gpu->export_caps.tex & PL_HANDLE_FD),
          bool(vk->gpu->export_caps.sync & PL_HANDLE_FD),
          bool(vk->gpu->export_caps.tex & PL_HANDLE_DMA_BUF));

    // Opaque handles require *both* the same device and compatible driver.
    // A generic 'Intel' or 'Mesa' string match is not sufficient.
    using GetBytes = void (*)(GLenum, GLubyte*);
    using GetIndexedBytes = void (*)(GLenum, GLuint, GLubyte*);
    const auto getBytes = reinterpret_cast<GetBytes>(context->getProcAddress("glGetUnsignedBytevEXT"));
    const auto getIndexedBytes = reinterpret_cast<GetIndexedBytes>(context->getProcAddress("glGetUnsignedBytei_vEXT"));
    bool match = false;
    if (memory && semaphore && getBytes && getIndexedBytes) {
        VkPhysicalDeviceIDProperties id{};
        id.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES;
        VkPhysicalDeviceProperties2 properties{};
        properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
        properties.pNext = &id;
        auto getProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(
            vk->get_proc_addr(vk->instance, "vkGetPhysicalDeviceProperties2"));
        if (!getProperties) { pl_vulkan_destroy(&vk); return; }
        getProperties(vk->phys_device, &properties);
        std::array<GLubyte, VK_UUID_SIZE> driver{}, device{};
        constexpr GLenum DriverUuid = 0x9598, DeviceUuid = 0x9597, NumDeviceUuids = 0x9596;
        getBytes(DriverUuid, driver.data());
        GLint devices = 0;
        context->extraFunctions()->glGetIntegerv(NumDeviceUuids, &devices);
        if (std::memcmp(driver.data(), id.driverUUID, VK_UUID_SIZE) == 0 && devices > 0 && devices <= 16)
            for (GLint i = 0; i < devices; ++i) {
                getIndexedBytes(DeviceUuid, GLuint(i), device.data());
                match |= std::memcmp(device.data(), id.deviceUUID, VK_UUID_SIZE) == 0;
            }
        if (context->extraFunctions()->glGetError() != GL_NO_ERROR) match = false;
    }
    qInfo("Qt Vulkan/GL same-device-and-driver=%d; external-handle delivery remains an independent gate", match);
    pl_vulkan_destroy(&vk);
}
