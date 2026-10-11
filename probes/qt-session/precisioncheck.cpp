#include "precisioncheck.h"

#include <QCoreApplication>
#include <QOpenGLContext>
#include <QOpenGLExtraFunctions>
#include <QQuickWindow>
#include <QTimer>

#include <array>
#include <atomic>
#include <memory>

namespace {
bool checkFramebuffer()
{
    auto* context = QOpenGLContext::currentContext();
    if (!context) { qWarning("Precision gate: no current OpenGL context"); return false; }
    auto* gl = context->extraFunctions();
    GLint framebuffer = 0;
    gl->glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer);
    qInfo("Qt GL renderer: %s; active framebuffer: %d",
          reinterpret_cast<const char*>(gl->glGetString(GL_RENDERER)), framebuffer);
    const GLenum attachment = framebuffer ? GL_COLOR_ATTACHMENT0 :
            (context->isOpenGLES() ? GL_BACK : GL_BACK_LEFT);
    GLint bits[3] = {};
    gl->glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, attachment, GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE, &bits[0]);
    gl->glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, attachment, GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE, &bits[1]);
    gl->glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, attachment, GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE, &bits[2]);
    const auto actual = context->format();
    qInfo("Qt context format: R%d G%d B%d; framebuffer precision: R%d G%d B%d",
          actual.redBufferSize(), actual.greenBufferSize(), actual.blueBufferSize(),
          bits[0], bits[1], bits[2]);
    if (gl->glGetError() != GL_NO_ERROR || bits[0] != 10 || bits[1] != 10 || bits[2] != 10) {
        qWarning("Precision gate: requested 10-bit surface was not proven as an actual RGB10 framebuffer");
        return false;
    }
    GLint viewport[4] = {};
    gl->glGetIntegerv(GL_VIEWPORT, viewport);
    if (viewport[2] < 1024 || viewport[3] < 1) {
        qWarning("Precision gate needs a framebuffer at least 1024 pixels wide");
        return false;
    }

    const bool scissorEnabled = gl->glIsEnabled(GL_SCISSOR_TEST);
    const bool ditherEnabled = gl->glIsEnabled(GL_DITHER);
    const bool srgbEnabled = !context->isOpenGLES() && gl->glIsEnabled(GL_FRAMEBUFFER_SRGB);
    GLint scissor[4] = {};
    GLfloat clear[4] = {};
    GLboolean mask[4] = {};
    gl->glGetIntegerv(GL_SCISSOR_BOX, scissor);
    gl->glGetFloatv(GL_COLOR_CLEAR_VALUE, clear);
    gl->glGetBooleanv(GL_COLOR_WRITEMASK, mask);
    gl->glEnable(GL_SCISSOR_TEST);
    gl->glDisable(GL_DITHER);
    if (!context->isOpenGLES()) gl->glDisable(GL_FRAMEBUFFER_SRGB);
    gl->glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

    bool passed = true;
    std::array<GLuint, 1024> samples{};
    for (int channel = 0; channel < 4 && passed; ++channel) {
        for (int code = 0; code < 1024; ++code) {
            const GLfloat value = GLfloat(code) / 1023;
            gl->glScissor(code, 0, 1, 1);
            gl->glClearColor(channel == 0 || channel == 3 ? value : 0,
                             channel == 1 || channel == 3 ? value : 0,
                             channel == 2 || channel == 3 ? value : 0, 1);
            gl->glClear(GL_COLOR_BUFFER_BIT);
        }
        gl->glReadPixels(0, 0, 1024, 1, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, samples.data());
        if (gl->glGetError() != GL_NO_ERROR) {
            qWarning("Precision gate: packed 10-bit framebuffer readback failed");
            passed = false;
            break;
        }
        for (GLuint code = 0; code < 1024 && passed; ++code) {
            for (int component = 0; component < 3; ++component) {
                const GLuint actual = (samples[code] >> (component * 10)) & 1023;
                const GLuint expected = channel == component || channel == 3 ? code : 0;
                if (actual != expected) {
                    qWarning("Precision gate: ramp %d code %u channel %d gave %u, expected %u",
                             channel, code, component, actual, expected);
                    passed = false;
                    break;
                }
            }
        }
    }
    gl->glColorMask(mask[0], mask[1], mask[2], mask[3]);
    gl->glClearColor(clear[0], clear[1], clear[2], clear[3]);
    gl->glScissor(scissor[0], scissor[1], scissor[2], scissor[3]);
    if (!scissorEnabled) gl->glDisable(GL_SCISSOR_TEST);
    if (ditherEnabled) gl->glEnable(GL_DITHER);
    if (srgbEnabled) gl->glEnable(GL_FRAMEBUFFER_SRGB);
    if (passed) qInfo("Precision gate passed: all 1024 RGB/gray levels retained in the Qt framebuffer");
    return passed;
}
}

void runQtFramebufferPrecisionCheck(QQuickWindow& window)
{
    const auto armed = std::make_shared<std::atomic_bool>(false);
    const auto started = std::make_shared<std::atomic_bool>(false);
    // Initial exposure can precede the compositor's fullscreen configure.
    // Test a later frame, after the GUI loop has handled that transition.
    QTimer::singleShot(2000, &window, [&window, armed] {
        QWindow* topLevel = &window;
        while (topLevel->parent()) topLevel = topLevel->parent();
        const auto margins = topLevel->frameMargins();
        qInfo("Precision gate: settled window %dx%d, top-level state %d, native child %d; frame margins %d,%d,%d,%d",
              window.width(), window.height(), int(topLevel->windowState()), !window.isTopLevel(),
              margins.left(), margins.top(), margins.right(), margins.bottom());
        if (!window.isTopLevel() && topLevel->windowState() != Qt::WindowFullScreen && margins.top() <= 0) {
            qWarning("Precision gate: native child must preserve the top-level window decoration");
            QCoreApplication::exit(1);
            return;
        }
        armed->store(true);
        window.update();
    });
    QObject::connect(&window, &QQuickWindow::afterRendering, &window, [&window, armed, started] {
        if (!armed->load()) return;
        if (started->exchange(true)) return;
        window.beginExternalCommands();
        const bool passed = checkFramebuffer();
        window.endExternalCommands();
        QMetaObject::invokeMethod(QCoreApplication::instance(), [passed] {
            QCoreApplication::exit(passed ? 0 : 1);
        }, Qt::QueuedConnection);
    }, Qt::DirectConnection);
    QTimer::singleShot(10000, &window, [] {
        qWarning("Precision gate: no completed GPU framebuffer test before deadline");
        QCoreApplication::exit(1);
    });
}
