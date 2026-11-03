// Diagnostic-only GPU sampling, without Qt, a window or compositor integration.
// This is not a replacement product renderer or a color-qualification test.
#pragma once
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" {
#include <libavutil/frame.h>
#include <va/va_drmcommon.h>
}

class VaapiSampling {
public:
    VaapiSampling() = default;
    VaapiSampling(const VaapiSampling&) = delete;
    VaapiSampling& operator=(const VaapiSampling&) = delete;
    ~VaapiSampling()
    {
        if (context != EGL_NO_CONTEXT) {
            eglMakeCurrent(display, surface, surface, context);
            glFinish();
            slots.clear();
            glDeleteProgram(program);
            glDeleteFramebuffers(1, &target);
            glDeleteTextures(1, &targetTexture);
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroyContext(display, context);
        }
        if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
        if (display != EGL_NO_DISPLAY) eglTerminate(display);
    }

    void initialize(const std::string& renderNode, int width, int height)
    {
        const auto devices = proc<PFNEGLQUERYDEVICESEXTPROC>("eglQueryDevicesEXT");
        const auto query = proc<PFNEGLQUERYDEVICESTRINGEXTPROC>("eglQueryDeviceStringEXT");
        const auto platform = proc<PFNEGLGETPLATFORMDISPLAYEXTPROC>("eglGetPlatformDisplayEXT");
        EGLDeviceEXT candidates[32];
        EGLint count = 0;
        ensure(devices(32, candidates, &count), "EGL device enumeration failed");
        for (int i = 0; i < count; ++i) {
            const char* path = query(candidates[i], EGL_DRM_RENDER_NODE_FILE_EXT);
            if (path && renderNode == path) {
                display = platform(EGL_PLATFORM_DEVICE_EXT, candidates[i], nullptr);
                break;
            }
        }
        ensure(display != EGL_NO_DISPLAY, "No EGL device matches the VA-API render node");
        ensure(eglInitialize(display, nullptr, nullptr), "EGL initialization failed");
        ensure(eglBindAPI(EGL_OPENGL_ES_API), "EGL ES binding failed");
        const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, EGL_RED_SIZE, 8,
            EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
        EGLConfig config;
        ensure(eglChooseConfig(display, attributes, &config, 1, &count) && count,
               "No EGL ES3 pbuffer configuration");
        const EGLint size[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        surface = eglCreatePbufferSurface(display, config, size);
        ensure(surface != EGL_NO_SURFACE, "EGL pbuffer creation failed");
        const EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, version);
        ensure(context != EGL_NO_CONTEXT && eglMakeCurrent(display, surface, surface, context),
               "EGL context creation failed");
        const auto* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
        ensure(renderer && !std::strstr(renderer, "llvmpipe") && !std::strstr(renderer, "softpipe"),
               "GPU sampling must not use a software renderer");
        std::cout << "sampling renderer=" << renderer << " target=" << width << 'x' << height
                  << " qt=false window=false max_leases=3" << std::endl;
        const char* extensions = eglQueryString(display, EGL_EXTENSIONS);
        ensure(extensions && std::strstr(extensions, "EGL_EXT_image_dma_buf_import_modifiers"),
               "EGL DMA-BUF modifier import is unavailable");
        createImage = proc<PFNEGLCREATEIMAGEKHRPROC>("eglCreateImageKHR");
        destroyImage = proc<PFNEGLDESTROYIMAGEKHRPROC>("eglDestroyImageKHR");
        bindImage = proc<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>("glEGLImageTargetTexture2DOES");
        const char* vertex = "#version 300 es\nprecision highp float;out vec2 uv;"
            "void main(){uv=vec2((gl_VertexID==1||gl_VertexID==3)?1.:0.,gl_VertexID>=2?1.:0.);"
            "gl_Position=vec4(uv*2.-1.,0.,1.);}";
        const char* fragment = "#version 300 es\nprecision highp float;uniform sampler2D video;"
            "in vec2 uv;out vec4 color;void main(){color=vec4(texture(video,uv).rgb,1.);}";
        const auto vs = shader(GL_VERTEX_SHADER, vertex);
        GLuint fs = 0;
        try { fs = shader(GL_FRAGMENT_SHADER, fragment); }
        catch (...) { glDeleteShader(vs); throw; }
        program = glCreateProgram();
        glAttachShader(program, vs); glAttachShader(program, fs); glLinkProgram(program);
        glDeleteShader(vs); glDeleteShader(fs);
        GLint linked = 0;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        ensure(linked, "Sampling shader link failed");
        glGenTextures(1, &targetTexture);
        glBindTexture(GL_TEXTURE_2D, targetTexture);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGB10_A2, width, height);
        glGenFramebuffers(1, &target);
        glBindFramebuffer(GL_FRAMEBUFFER, target);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, targetTexture, 0);
        ensure(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
               "10-bit sampling framebuffer is incomplete");
        glUseProgram(program); glUniform1i(glGetUniformLocation(program, "video"), 0);
        glViewport(0, 0, width, height);
        ensure(glGetError() == GL_NO_ERROR, "Sampling setup generated a GL error");
    }

    void submit(const VADRMPRIMESurfaceDescriptor& d, const AVFrame* frame)
    {
        slots.erase(std::remove_if(slots.begin(), slots.end(), [](const auto& slot) {
            const auto state = glClientWaitSync(slot->fence, 0, 0);
            ensure(state != GL_WAIT_FAILED, "Sampling fence failed");
            return state == GL_ALREADY_SIGNALED || state == GL_CONDITION_SATISFIED;
        }), slots.end());
        if (slots.size() == 3) { ++skipped; return; }
        ensure(d.fourcc == VA_FOURCC_Y410 && d.num_objects == 1 && d.num_layers == 1 &&
               d.layers[0].num_planes == 1 && d.layers[0].object_index[0] == 0,
               "Sampling requires the single-plane Y410 surface");
        auto slot = std::make_unique<Slot>();
        slot->display = display; slot->destroyImage = destroyImage;
        slot->frame = av_frame_clone(frame);
        ensure(slot->frame, "Could not retain the sampled surface");
        const auto& object = d.objects[0];
        const auto& plane = d.layers[0];
        // Match the product's Y410 -> XR30 storage interpretation, without a
        // driver YUV conversion. Keep the original offset, pitch and modifier.
        std::vector<EGLint> attrs = {EGL_WIDTH, frame->width, EGL_HEIGHT, frame->height,
            EGL_LINUX_DRM_FOURCC_EXT, EGLint(DRM_FORMAT_XRGB2101010),
            EGL_DMA_BUF_PLANE0_FD_EXT, object.fd, EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGLint(plane.offset[0]),
            EGL_DMA_BUF_PLANE0_PITCH_EXT, EGLint(plane.pitch[0])};
        if (object.drm_format_modifier != DRM_FORMAT_MOD_INVALID)
            attrs.insert(attrs.end(), {EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGLint(object.drm_format_modifier),
                EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGLint(object.drm_format_modifier >> 32)});
        attrs.push_back(EGL_NONE);
        slot->image = createImage(display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, attrs.data());
        ensure(slot->image != EGL_NO_IMAGE_KHR, "Sampling image import failed");
        glGenTextures(1, &slot->texture); glBindTexture(GL_TEXTURE_2D, slot->texture);
        bindImage(GL_TEXTURE_2D, slot->image);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        slot->fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        glFlush();
        ensure(slot->fence && glGetError() == GL_NO_ERROR, "GPU sampling draw failed");
        slots.push_back(std::move(slot));
        ++sampled;
    }

    uint64_t sampled = 0, skipped = 0;

private:
    static void ensure(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
    template<class T> static T proc(const char* name) {
        const auto function = reinterpret_cast<T>(eglGetProcAddress(name));
        ensure(function, name); return function;
    }
    static GLuint shader(GLenum type, const char* source) {
        const GLuint shader = glCreateShader(type);
        glShaderSource(shader, 1, &source, nullptr); glCompileShader(shader);
        GLint compiled = 0; glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
        if (!compiled) { glDeleteShader(shader); throw std::runtime_error("Sampling shader compilation failed"); }
        return shader;
    }
    struct Slot {
        EGLDisplay display = EGL_NO_DISPLAY;
        EGLImageKHR image = EGL_NO_IMAGE_KHR;
        PFNEGLDESTROYIMAGEKHRPROC destroyImage = nullptr;
        GLuint texture = 0;
        GLsync fence = nullptr;
        AVFrame* frame = nullptr;
        ~Slot() {
            if (fence) glDeleteSync(fence);
            glDeleteTextures(1, &texture);
            if (image != EGL_NO_IMAGE_KHR) destroyImage(display, image);
            av_frame_free(&frame);
        }
    };
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    PFNEGLCREATEIMAGEKHRPROC createImage = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroyImage = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC bindImage = nullptr;
    GLuint program = 0, target = 0, targetTexture = 0;
    std::vector<std::unique_ptr<Slot>> slots;
};
