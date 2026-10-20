#include "presentercheck.h"
#include "sessionwindow.h"
#include "videopresenter.h"
#include "../../apps/client/app/streaming/audio/renderers/pipewire.h"

#include <QCoreApplication>
#include <QDebug>
#include <QScopeGuard>
#include <QThread>
#include <QTimer>
#include <cstring>
#include <memory>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
}
#include "../../apps/client/app/streaming/video/applevideo-test-frame.h"

namespace {
QtVideoFrame::Ptr decode(const QString& renderNode, QString& error)
{
    const auto* codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    AVCodecContext* context = avcodec_alloc_context3(codec);
    AVFrame* frame = av_frame_alloc();
    AVPacket* packet = av_packet_alloc();
    const auto cleanup = qScopeGuard([&] {
        av_packet_free(&packet);
        av_frame_free(&frame);
        avcodec_free_context(&context);
    });
    if (!context || !frame || !packet) {
        error = QStringLiteral("Could not allocate decoder fixture");
        return {};
    }
    context->thread_count = 1;
    context->extra_hw_frames = 8;
    context->get_format = [](AVCodecContext*, const AVPixelFormat* formats) {
        for (; *formats != AV_PIX_FMT_NONE; ++formats)
            if (*formats == AV_PIX_FMT_VAAPI) return *formats;
        return AV_PIX_FMT_NONE;
    };
    if (av_hwdevice_ctx_create(&context->hw_device_ctx, AV_HWDEVICE_TYPE_VAAPI,
                              renderNode.toUtf8().constData(), nullptr, 0) < 0 ||
            avcodec_open2(context, codec, nullptr) < 0 ||
            av_new_packet(packet, k_AppleHEVCRext10TestFrameSize) < 0) {
        error = QStringLiteral("Hardware HEVC fixture is unavailable");
        return {};
    }
    memcpy(packet->data, k_AppleHEVCRext10TestFrame, k_AppleHEVCRext10TestFrameSize);
    if (avcodec_send_packet(context, packet) < 0) {
        error = QStringLiteral("Could not submit the HEVC fixture");
        return {};
    }
    int status = avcodec_receive_frame(context, frame);
    if (status == AVERROR(EAGAIN)) {
        avcodec_send_packet(context, nullptr);
        status = avcodec_receive_frame(context, frame);
    }
    if (status < 0 || frame->format != AV_PIX_FMT_VAAPI ||
            frame->width != 3840 || frame->height != 2160 ||
            frame->color_range != AVCOL_RANGE_JPEG || frame->colorspace != AVCOL_SPC_BT709) {
        error = QStringLiteral("HEVC fixture did not produce the expected exact-format frame");
        return {};
    }
    auto surface = QtVaapiVideoFrame::create(frame, 10, error);
    return surface ? QtVideoFrame::hardware(std::move(surface), {}, QtVideoFrame::Purpose::DecoderQualification) : nullptr;
}
}

void runQtPresenterLifecycleCheck(QtSessionWindow& window, bool audio)
{
    // A real decoder/mailbox/render-node/swap check without any Host, account,
    // network connection or physical input forwarding. Audio opens silence only.
    window.setLiveSession(true);
    auto* presenter = new QtVideoPresenter(&window);
    presenter->addOutput(&window, {}, true);
    QObject::connect(presenter, &QtVideoPresenter::deviceReady, &window,
        [presenter, audio](bool available, const QString& reason) {
        if (!available || presenter->vaapiRenderNode().isEmpty()) {
            qCritical().noquote() << "Presenter hardware fixture unavailable:" << reason;
            QCoreApplication::exit(77);
            return;
        }
        const auto factory = presenter->deliveryFactory();
        const auto node = presenter->vaapiRenderNode();
        auto outcome = std::make_shared<int>(1);
        auto* worker = QThread::create([factory, node, audio, outcome] {
            for (int iteration = 0; iteration < 12; ++iteration) {
                if (QThread::currentThread()->isInterruptionRequested()) return;
                std::unique_ptr<PipeWireAudioRenderer> playback;
                if (audio && iteration % 3) {
                    playback = std::make_unique<PipeWireAudioRenderer>(true, true);
                    OPUS_MULTISTREAM_CONFIGURATION config{};
                    config.sampleRate = 48000; config.channelCount = 2; config.samplesPerFrame = 240;
                    if (!playback->prepareForPlayback(&config)) {
                        qCritical("Presenter fixture could not open PipeWire");
                        return;
                    }
                    // Exercise qualification teardown and live audio separately.
                    if (iteration % 3 == 1) playback.reset();
                }
                QString error;
                auto frame = decode(node, error);
                auto delivery = factory();
                if (!frame || !delivery.qualify || !delivery.qualify(frame, error)) {
                    qCritical().noquote() << "Presenter lifecycle iteration" << iteration << "failed:" << error;
                    return;
                }
                qInfo("Presenter lifecycle iteration %d passed (audio=%d)", iteration, audio);
                delivery.discard();
                // Do not finish before the covered parent's callback timeout
                // could fire. There is no such sleep in the product renderer.
                QThread::msleep(100);
            }
            *outcome = 0;
        });
        QObject::connect(worker, &QThread::finished, presenter, [worker, outcome] {
            worker->deleteLater();
            QCoreApplication::exit(*outcome);
        });
        QObject::connect(QCoreApplication::instance(), &QCoreApplication::aboutToQuit, worker, [presenter, worker] {
            presenter->stop();
            worker->requestInterruption();
            worker->wait(); // qualification cancellation is bounded; no active session
        });
        worker->start();
    });
    QTimer::singleShot(0, presenter, &QtVideoPresenter::initializeDevice);
}
