// Build on linux-client-builder; run offscreen there and on the qualified Intel NUC.
// Tests the production Qt vertex/fragment shaders, including identity and range mapping.
#include "streaming/qt/packedvideoshaders.h"
#include "streaming/video/packedvideo.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#define GL_GLEXT_PROTOTYPES
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static void require(bool ok, const char* message)
{
    if (!ok) throw std::runtime_error(message);
}

static GLuint shader(GLenum type, const std::string& source)
{
    const auto id = glCreateShader(type);
    const auto* data = source.c_str();
    glShaderSource(id, 1, &data, nullptr);
    glCompileShader(id);
    GLint ok;
    glGetShaderiv(id, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(id, sizeof(log), nullptr, log);
        std::cerr << log << '\n';
    }
    require(ok, "shader compile failed");
    return id;
}

int main() try
{
    EGLDisplay display = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                               EGL_DEFAULT_DISPLAY, nullptr);
    require(eglInitialize(display, nullptr, nullptr), "EGL initialize failed");
    require(eglBindAPI(EGL_OPENGL_ES_API), "EGL bind failed");
    const EGLint attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, EGL_NO_CONFIG_KHR,
                                          EGL_NO_CONTEXT, attributes);
    require(context != EGL_NO_CONTEXT, "EGL context failed");
    require(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context), "EGL current failed");
    std::cout << "renderer=" << glGetString(GL_RENDERER) << '\n';
    const auto vertex = shader(GL_VERTEX_SHADER, std::string("#version 300 es\n") + QtPackedVideoShaders::vertex);
    const auto frag = shader(GL_FRAGMENT_SHADER,
        std::string("#version 300 es\nprecision highp float;\nprecision highp sampler2D;\n") +
        QtPackedVideoShaders::fragment);
    const auto program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, frag);
    glLinkProgram(program);
    GLint linked;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    require(linked, "shader link failed");
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "video"), 0);
    glUniform1i(glGetUniformLocation(program, "p010"), 0);
    glUniform1i(glGetUniformLocation(program, "chroma"), 1);
    glUniform4f(glGetUniformLocation(program, "destination"), 0, 0, 1, 1);
    glUniform4f(glGetUniformLocation(program, "source"), 0, 0, 1, 1);
    GLuint vao;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    // XR30 memory channels R:G:B = V:Y:U. Exhaust the gray ramp and
    // independently vary each packed component, including out-of-gamut codes.
    std::vector<std::array<int,3>> input;
    for (int y=0; y<1024; ++y) input.push_back({512,y,512});
    for (int v : {0,64,256,512,768,960,1023})
        for (int y : {0,1,64,256,512,768,940,1022,1023})
            for (int u : {0,64,256,512,768,960,1023}) input.push_back({v,y,u});
    std::vector<uint32_t> raw, output(input.size());
    for (auto value : input) raw.push_back(value[0] | (value[1]<<10) | (value[2]<<20) | (3U<<30));
    GLuint source, target, fbo;
    glGenTextures(1, &source);
    glBindTexture(GL_TEXTURE_2D, source);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB10_A2, input.size(), 1, 0,
                 GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, raw.data());
    glGenTextures(1, &target);
    glBindTexture(GL_TEXTURE_2D, target);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGB10_A2, input.size(), 1);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
    require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "incomplete RGB10 FBO");
    glViewport(0, 0, input.size(), 1);
    glDisable(GL_DITHER);
    glBindTexture(GL_TEXTURE_2D, source);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    using PlankPackedVideo::Mapping;
    for (auto mode : {Mapping::Bt709Full10, Mapping::Bt709Limited10, Mapping::Identity10, Mapping::Identity8}) {
        glUniform1i(glGetUniformLocation(program, "mapping"), int(mode));
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glReadPixels(0, 0, input.size(), 1, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, output.data());
        require(glGetError() == GL_NO_ERROR, "shader draw/readback failed");
        int maxError = 0;
        for (size_t i=0; i<input.size(); ++i) {
            const auto p = input[i];
            std::array<double,3> expected = {double(p[0]),double(p[1]),double(p[2])};
            if (mode == Mapping::Bt709Full10 || mode == Mapping::Bt709Limited10) {
                // Independent reference derived from BT.709 Kr/Kb.
                constexpr double kr=.2126, kb=.0722, kg=1-kr-kb;
                double y=p[1], cb=p[2]-512, cr=p[0]-512;
                if (mode == Mapping::Bt709Limited10) {
                    y=(y-64)*1023/876; cb*=1023./896; cr*=1023./896;
                }
                expected = {y+2*(1-kr)*cr,
                            y-2*kb*(1-kb)/kg*cb-2*kr*(1-kr)/kg*cr,
                            y+2*(1-kb)*cb};
            } else if (mode == Mapping::Identity8) {
                expected = {double(p[2]),double(p[0]),double(p[1])};
            }
            for (int c=0; c<3; ++c) {
                int want=std::lround(std::clamp(expected[c],0.,1023.));
                int got=(output[i]>>(c*10))&1023;
                maxError=std::max(maxError, std::abs(want-got));
            }
        }
        std::cout << "mode=" << int(mode) << " samples=" << input.size()
                  << " max_error_10bit_codes=" << maxError << '\n';
        require(maxError <= (mode == Mapping::Identity8 || mode == Mapping::Identity10 ? 0 : 1), "pixel comparison failed");
    }
    glDeleteFramebuffers(1,&fbo);
    glDeleteTextures(1,&target);
    glDeleteTextures(1,&source);
    glDeleteVertexArrays(1,&vao);
    glDeleteProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(frag);
    eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
    eglDestroyContext(display,context);
    eglTerminate(display);
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
}
