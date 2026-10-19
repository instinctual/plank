#include "videoprecisioncheck.h"
#include "packedvideoblitter.h"
#include "gpuinteropcheck.h"
#include "softwareinteropcheck.h"

#include <QCoreApplication>
#include <QOpenGLContext>
#include <QOpenGLExtraFunctions>
#include <QQuickWindow>
#include <QTimer>
#include <array>
#include <atomic>
#include <memory>
#include <vector>

namespace {
using Mapping = PlankPackedVideo::Mapping;

bool checkVideo()
{
    auto* context = QOpenGLContext::currentContext();
    if (!context) return false;
    reportQtGpuInteropCapabilities();
    if (!checkQtSoftwareInterop()) return false;
    auto* gl = context->extraFunctions();
    GLint viewport[4] = {};
    gl->glGetIntegerv(GL_VIEWPORT, viewport);
    if (viewport[2] < 1100 || viewport[3] < 200) {
        qWarning("Video gate needs a framebuffer at least 1100x200 pixels");
        return false;
    }
    const QSize drawable(viewport[2], viewport[3]);
    QtPackedVideoBlitter blitter;
    GLuint texture = 0, chroma = 0;
    gl->glGenTextures(1, &texture);
    gl->glGenTextures(1, &chroma);
    std::vector<GLuint> pixels(1024 * 4);
    bool passed = true;
    for (int test = 0; test < 9 && passed; ++test) {
        const bool eightBit = test == 1;
        const bool p010 = test >= 6;
        const bool color = test == 8;
        const bool limited = test == 5 || test == 7;
        const bool bt709 = test == 2 || limited || p010;
        const bool crop = test == 3;
        const bool filter = test == 4;
        const Mapping mapping = eightBit ? Mapping::Identity8 : limited ? Mapping::Bt709Limited10 :
            bt709 ? Mapping::Bt709Full10 : Mapping::Identity10;
        for (int row = 0; row < 4; ++row) {
            for (int code = 0; code < 1024; ++code) {
                const GLuint level = filter ? (code & 1 ? 1023 : 0) : GLuint(code);
                GLuint rgb[] = {row == 0 || row == 3 ? level : 0,
                                row == 1 || row == 3 ? level : 0,
                                row == 2 || row == 3 ? level : 0};
                if (eightBit) {
                    const GLuint r = rgb[0] / 4, g = rgb[1] / 4, b = rgb[2] / 4;
                    // Upload the *sampled* XR24 channel order: Y,U,V = G,B,R.
                    pixels[row * 1024 + code] = g | b << 8 | r << 16 | 0xff000000U;
                } else if (bt709) {
                    pixels[row * 1024 + code] = 512 | GLuint(code) << 10 | 512 << 20 | 0xc0000000U;
                } else {
                    pixels[row * 1024 + code] = rgb[0] | rgb[1] << 10 | rgb[2] << 20 | 0xc0000000U;
                }
            }
        }
        gl->glActiveTexture(GL_TEXTURE0);
        gl->glBindTexture(GL_TEXTURE_2D, texture);
        gl->glTexImage2D(GL_TEXTURE_2D, 0, eightBit ? GL_RGBA8 : GL_RGB10_A2, 1024, 4, 0, GL_RGBA,
                         eightBit ? GL_UNSIGNED_BYTE : GL_UNSIGNED_INT_2_10_10_10_REV, pixels.data());
        if (p010) {
            std::vector<GLushort> luma(1024 * 4), uv(512 * 2 * 2);
            for (int y = 0; y < 4; ++y)
                for (int x = 0; x < 1024; ++x) luma[y * 1024 + x] = GLushort(x << 6);
            for (int i = 0; i < 512 * 2; ++i) {
                uv[i * 2] = GLushort((color ? 640 : 512) << 6);
                uv[i * 2 + 1] = GLushort((color ? 384 : 512) << 6);
            }
            gl->glTexImage2D(GL_TEXTURE_2D, 0, GL_R16, 1024, 4, 0, GL_RED, GL_UNSIGNED_SHORT, luma.data());
            gl->glBindTexture(GL_TEXTURE_2D, chroma);
            gl->glTexImage2D(GL_TEXTURE_2D, 0, GL_RG16, 512, 2, 0, GL_RG, GL_UNSIGNED_SHORT, uv.data());
        }
        const int width = crop || filter ? 512 : 1024;
        const int sourceX = crop ? 512 : 0;
        const int sourceWidth = crop ? 512 : 1024;
        const QtSessionGeometry geometry{{1024, 4}, {qreal(sourceX), 0, qreal(sourceWidth), 4},
            {11, 73, qreal(width), 4}, drawable, drawable};
        QString error;
        if (!blitter.draw(texture, GL_TEXTURE_2D, mapping, geometry, error, p010 ? chroma : 0)) {
            qWarning().noquote() << error;
            passed = false;
            break;
        }
        std::vector<GLuint> result(width * 4);
        // Test-only readback. The actual importer/presenter has no readback or
        // CPU image path. Flip GL's bottom-origin rows when comparing.
        gl->glReadPixels(11, drawable.height() - 77, width, 4, GL_RGBA,
                         GL_UNSIGNED_INT_2_10_10_10_REV, result.data());
        for (int row = 0; row < 4 && passed; ++row) {
            for (int x = 0; x < width && passed; ++x) {
                const GLuint code = sourceX + x;
                for (int channel = 0; channel < 3; ++channel) {
                    GLuint expected = row == channel || row == 3 ? code : 0;
                    const GLuint source8 = expected / 4;
                    if (eightBit) expected = qRound(source8 * 1023.0 / 255.0);
                    if (bt709) expected = code;
                    if (color) {
                        const double delta[] = {-1.5748 * 128.0, (-0.1873242729 + 0.4681242729) * 128.0, 1.8556 * 128.0};
                        expected = qRound(std::clamp(double(code) + delta[channel], 0.0, 1023.0));
                    }
                    if (limited) expected = qRound(std::clamp((double(code) - 64.0) / 876.0, 0.0, 1.0) * 1023.0);
                    if (filter) expected = row == channel || row == 3 ? 512 : 0;
                    const GLuint actual = (result[(3 - row) * width + x] >> (10 * channel)) & 1023;
                    // GL 4.6 section 2.3.5.2 permits either adjacent integer
                    // when converting a non-integral UNORM value. Eight-bit
                    // expansion must still recover the exact original code;
                    // do not relax native ten-bit ramps or their crop test.
                    bool matches = actual == expected;
                    if (eightBit) {
                        const GLuint lower = source8 * 1023 / 255;
                        const GLuint upper = (source8 * 1023 + 254) / 255;
                        matches = actual >= lower && actual <= upper &&
                            qRound(actual * 255.0 / 1023.0) == int(source8);
                    } else if (limited || color) {
                        matches = std::abs(int(actual) - int(expected)) <= 1;
                    } else if (filter && (row == channel || row == 3)) {
                        // The exact midpoint is 511.5 in the 10-bit target.
                        matches = actual == 511 || actual == 512;
                    }
                    if (!matches) {
                        qWarning("Video gate case %d row %d x %d channel %d: %u instead of %u",
                                 test, row, x, channel, actual, expected);
                        passed = false;
                        break;
                    }
                }
            }
        }
        if (gl->glGetError() != GL_NO_ERROR) passed = false;
        qInfo("Qt video shader case %d: %s", test, passed ? "pass" : "fail");
    }
    if (passed) {
        // Fail closed on a substituted 8-bit intermediate, even when the
        // OpenGL context itself advertises ten-bit components.
        GLint originalFramebuffer = 0;
        GLuint fbo = 0, rgb8 = 0;
        gl->glGetIntegerv(GL_FRAMEBUFFER_BINDING, &originalFramebuffer);
        gl->glGenFramebuffers(1, &fbo);
        gl->glGenTextures(1, &rgb8);
        gl->glBindTexture(GL_TEXTURE_2D, rgb8);
        gl->glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1024, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        gl->glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        gl->glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rgb8, 0);
        QString error;
        passed = gl->glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE &&
            !blitter.draw(texture, GL_TEXTURE_2D, Mapping::Identity10,
                          {{1024, 4}, {0, 0, 1024, 4}, {0, 0, 1024, 4}, {1024, 4}, {1024, 4}}, error) &&
            error.contains(QStringLiteral("precision"));
        gl->glBindFramebuffer(GL_FRAMEBUFFER, GLuint(originalFramebuffer));
        gl->glDeleteFramebuffers(1, &fbo);
        gl->glDeleteTextures(1, &rgb8);
        qInfo("Qt video rejects RGB8 substitution: %s", passed ? "pass" : "fail");
    }
    gl->glDeleteTextures(1, &texture);
    gl->glDeleteTextures(1, &chroma);
    qInfo("Qt video precision gate: %s (synthetic GPU textures; not hardware decode qualification)", passed ? "pass" : "fail");
    return passed;
}
}

void runQtVideoPrecisionCheck(QQuickWindow& window)
{
    const auto armed = std::make_shared<std::atomic_bool>(false);
    const auto checked = std::make_shared<std::atomic_bool>(false);
    QTimer::singleShot(2000, &window, [&window, armed] { armed->store(true); window.update(); });
    QObject::connect(&window, &QQuickWindow::afterRendering, &window, [&window, armed, checked] {
        if (!armed->load() || checked->exchange(true)) return;
        window.beginExternalCommands();
        const bool passed = checkVideo();
        window.endExternalCommands();
        QMetaObject::invokeMethod(QCoreApplication::instance(), [passed] {
            QCoreApplication::exit(passed ? 0 : 1);
        }, Qt::QueuedConnection);
    }, Qt::DirectConnection);
    QTimer::singleShot(10000, &window, [] {
        qWarning("Qt video precision gate timed out");
        QCoreApplication::exit(1);
    });
}
