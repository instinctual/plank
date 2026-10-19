#include "softwareinteropcheck.h"
#include "softwarevideodevice.h"
#include "packedvideoblitter.h"

#include <QOpenGLContext>
#include <QOpenGLExtraFunctions>
#include <QDebug>
#include <vector>

namespace {
struct Frame { AVFrame* value = av_frame_alloc(); ~Frame() { av_frame_free(&value); } };
struct Context {
    AVCodecContext* value = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_H264));
    ~Context() { avcodec_free_context(&value); }
};
}

bool checkQtSoftwareInterop()
{
    auto* context = QOpenGLContext::currentContext();
    if (!context) return false;
    if (!context->hasExtension("GL_EXT_memory_object_fd") || !context->hasExtension("GL_EXT_semaphore_fd")) {
        QString error;
        if (QtSoftwareVideoDevice::createForCurrentContext(error) || error.isEmpty()) return false;
        qInfo("SKIP Qt live GPU handoff: this test GL driver lacks external memory/semaphores; hardware gate remains pending");
        return qEnvironmentVariableIntValue("PLANK_QT_REQUIRE_GPU_INTEROP") != 1;
    }
    QString error;
    auto device = QtSoftwareVideoDevice::createForCurrentContext(error);
    if (!device) { qWarning().noquote() << error; return false; }
    auto first = device->createImage({1024, 4}, error);
    auto second = device->createImage({1024, 4}, error);
    if (!first || !second) { qWarning().noquote() << error; return false; }
    Context codec; Frame decoded;
    if (!codec.value || !decoded.value) return false;
    codec.value->pix_fmt = AV_PIX_FMT_GBRP10LE;
    auto* frame = decoded.value;
    frame->width = 1024; frame->height = 4; frame->format = codec.value->pix_fmt;
    frame->color_range = AVCOL_RANGE_JPEG; frame->colorspace = AVCOL_SPC_RGB;
    if (device->getBuffer(codec.value, frame, 0) < 0) return false;
    auto* gl = context->extraFunctions();
    GLint viewport[4]{};
    gl->glGetIntegerv(GL_VIEWPORT, viewport);
    const QSize drawable(viewport[2], viewport[3]);
    const QtSessionGeometry geometry{{1024, 4}, {0, 0, 1024, 4},
        {11, 73, 1024, 4}, drawable, drawable};
    QtPackedVideoBlitter blitter;
    std::vector<GLuint> result(1024 * 4);
    for (int i = 0; i < 120; ++i) {
        // Wait-free runtime never writes into an in-flight decoder reference.
        // Test allocation follows the same pool ownership: unref and reacquire.
        if (i) {
            av_frame_unref(frame);
            frame->width = 1024; frame->height = 4; frame->format = codec.value->pix_fmt;
            frame->color_range = AVCOL_RANGE_JPEG; frame->colorspace = AVCOL_SPC_RGB;
            if (device->getBuffer(codec.value, frame, 0) < 0) return false;
        }
        for (int y = 0; y < 4; ++y) for (int x = 0; x < 1024; ++x)
            for (int p = 0; p < 3; ++p) {
                auto* row = reinterpret_cast<uint16_t*>(frame->data[p] + y * frame->linesize[p]);
                row[x] = (y == 3 || y == (p + 1) % 3) ? (x + i * 13) % 1024 : 0;
            }
        auto& image = i % 2 ? second : first;
        if (i >= 2 && !image->releaseGl(error)) { qWarning().noquote() << error; return false; }
        if (!device->convert(frame, codec.value->pix_fmt, *image, error)) {
            qWarning().noquote() << error; return false;
        }
        // Detect accidental overlapping ownership before drawing.
        if (image->beginWrite(error) || error.isEmpty()) return false;
        for (int repeat = 0; repeat < 2; ++repeat) {
            if (!blitter.draw(image->glTexture(),
                              PlankPackedVideo::Mapping::Identity10, geometry, error)) {
                qWarning().noquote() << error; return false;
            }
        }
        // Test-only GPU readback. No runtime transfer ever takes this path.
        gl->glReadPixels(11, drawable.height() - 77, 1024, 4, GL_RGBA,
                         GL_UNSIGNED_INT_2_10_10_10_REV, result.data());
        for (int y = 0; y < 4; ++y) for (int x = 0; x < 1024; ++x)
            for (int c = 0; c < 3; ++c) {
                const unsigned expected = y == 3 || y == c ? (x + i * 13) % 1024 : 0;
                if (((result[(3 - y) * 1024 + x] >> (c * 10)) & 1023) != expected) {
                    qWarning("Qt GPU handoff precision failed at iteration %d row %d pixel %d channel %d", i, y, x, c);
                    return false;
                }
            }
    }
    qInfo("Qt pooled decode memory -> Vulkan RGB10 -> Qt GL: 120 ownership roundtrips and repeated draws passed");
    return gl->glGetError() == GL_NO_ERROR;
}
