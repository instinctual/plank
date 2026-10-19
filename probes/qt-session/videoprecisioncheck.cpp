#include "videoprecisioncheck.h"
#include "packedvideoblitter.h"

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
    auto* gl = context->extraFunctions();
    GLint viewport[4] = {};
    gl->glGetIntegerv(GL_VIEWPORT, viewport);
    if (viewport[2] < 1100 || viewport[3] < 200) {
        qWarning("Video gate needs a framebuffer at least 1100x200 pixels");
        return false;
    }
    const QSize drawable(viewport[2], viewport[3]);
    QtPackedVideoBlitter blitter;
    GLuint texture = 0;
    gl->glGenTextures(1, &texture);
    std::vector<GLuint> pixels(1024 * 4);
    bool passed = true;
    for (int test = 0; test < 5 && passed; ++test) {
        const bool eightBit = test == 1;
        const bool bt709 = test == 2;
        const bool crop = test == 3;
        const bool filter = test == 4;
        const Mapping mapping = eightBit ? Mapping::Identity8 : bt709 ? Mapping::Bt709Full10 : Mapping::Identity10;
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
        const int width = crop || filter ? 512 : 1024;
        const int sourceX = crop ? 512 : 0;
        const int sourceWidth = crop ? 512 : 1024;
        const QtSessionGeometry geometry{{1024, 4}, {qreal(sourceX), 0, qreal(sourceWidth), 4},
            {11, 73, qreal(width), 4}, drawable, drawable};
        QString error;
        if (!blitter.draw(texture, GL_TEXTURE_2D, mapping, geometry, error)) {
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
                    if (eightBit) expected = qRound((expected / 4) * 1023.0 / 255.0);
                    if (bt709) expected = code;
                    if (filter) expected = row == channel || row == 3 ? 512 : 0;
                    const GLuint actual = (result[(3 - row) * width + x] >> (10 * channel)) & 1023;
                    if (actual != expected) {
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
