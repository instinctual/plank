// Actual Client HTTPS/auth/launch plus native media. No GUI, device access,
// installation, synthetic verifier, password file, or login-screen input.
#include "backend/nvhttp.h"
#include "plank_transport.h"
#include "plank_transport_control.h"
#include "streaming/video/applevideoprofile.h"
#include <QCoreApplication>
#include <QFile>
#include <QElapsedTimer>
#include <QThread>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/pixdesc.h>
#include <opus/opus.h>
}

#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "check failed at %d\n", __LINE__); return 1; } } while (0)
int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    CHECK(argc == 6 || (argc == 7 && QByteArray(argv[6]) == "--sample-keyframes"));
    const bool sampleKeyframes = argc == 7;
    const QString encodingMode = QString::fromLocal8Bit(argv[5]);
    const bool fullChroma = encodingMode == QLatin1String("hevc-10-444-videotoolbox");
    CHECK(fullChroma || encodingMode == QLatin1String("hevc-10-420-videotoolbox"));
    bool valid = false;
    const int port = QString::fromLocal8Bit(argv[2]).toInt(&valid);
    CHECK(valid && port > 0 && port <= 65535);
    QFile input;
    CHECK(input.open(stdin, QIODevice::ReadOnly));
    QByteArray password = input.readLine(4098).trimmed();
    CHECK(!password.isEmpty() && password.size() <= 4096);
    try {
        NvHTTP http(NvAddress(QString::fromLocal8Bit(argv[1]), static_cast<quint16>(port)));
        const QString info = http.getServerInfo(NvHTTP::NVLL_NONE);
        CHECK(NvHTTP::getXmlString(info, "ServerCodecModeSupport") == "1049088");
        // Same discovery gate used by normal login and reconnect. The original
        // probe skipped it and therefore missed the GUI's absent topology.
        CHECK(NvOutputTopology::supportsDescription(
                    NvHTTP::getXmlString(info, "PlankTopologyVersion").toInt(),
                    NvHTTP::getXmlString(info, "PlankFeatureFlags").toInt()));
        bool greeter = false;
        const QString token = http.authenticate(QString::fromLocal8Bit(argv[3]), QString::fromUtf8(password), &greeter);
        password.fill('\0'); password.clear();
        http.setPlankSessionToken(token, http.hostIdentityKey());
        {
            const auto requested = NvOutputTopology::virtualModeSize(QString::fromLocal8Bit(argv[4]));
            const auto prepared = http.prepareMacDisplay(QString::fromLocal8Bit(argv[4]), encodingMode);
            CHECK(prepared.displayPolicyKnown());
            CHECK(prepared.desktopWidth == requested.width() && prepared.desktopHeight == requested.height());
        }
        CHECK(NvHTTP::getXmlString(http.getServerInfo(NvHTTP::NVLL_NONE), "PairStatus") == "1");
        NvHTTP anonymous(http.address());
        CHECK(NvHTTP::getXmlString(anonymous.getServerInfo(NvHTTP::NVLL_NONE), "PairStatus") == "0");
        anonymous.setPlankSessionToken(QString(44, QLatin1Char('x')), http.hostIdentityKey());
        CHECK(NvHTTP::getXmlString(anonymous.getServerInfo(NvHTTP::NVLL_NONE), "PairStatus") == "0");
        QString pin;
        const auto topology = http.getOutputTopology(&pin);
        CHECK(topology.featureFlags == NvOutputTopology::FixedCaptureFlags);
        CHECK(topology.displayPolicyKnown());
        CHECK(topology.appleEncodingMode == encodingMode);
        CHECK(topology.allowsBookmarkHostLayout(QStringLiteral("fixed")));
        CHECK(topology.desktopWidth > 0 && topology.desktopHeight > 0);
        const auto desktops = http.getAppList();
        CHECK(desktops.size() == 1 && desktops[0].name == QStringLiteral("Desktop"));
        auto launch = http.startMacPreview(topology, pin, 50000, 1200);
        const QByteArray remote = QByteArray(argv[1]) + ':' + QByteArray::number(port);
        const QByteArray fingerprint = pin.toLatin1();
        PlankTransportConfig config {};
        config.struct_size = sizeof(config); config.abi_version = PLANK_TRANSPORT_ABI_VERSION;
        config.mode = PLANK_TRANSPORT_MODE_CLIENT;
        config.remote_address = remote.constData(); config.server_name = "plank-host";
        config.certificate_sha256 = fingerprint.constData();
        config.session_token = launch.transportToken.constData();
        config.handshake_timeout_ms = 5000; config.idle_timeout_ms = 5000;
        config.keep_alive_interval_ms = 1000; config.max_udp_payload_size = 1200;
        PlankTransportNativeEndpoint* raw = nullptr;
        CHECK(plank_transport_native_endpoint_create(&config, &raw) == PLANK_TRANSPORT_OK);
        std::unique_ptr<PlankTransportNativeEndpoint, decltype(&plank_transport_native_endpoint_destroy)>
            endpoint(raw, plank_transport_native_endpoint_destroy);
        launch.transportToken.fill('\0'); launch.transportToken.clear();
        CHECK(plank_transport_native_endpoint_start(raw) == PLANK_TRANSPORT_OK);
        CHECK(plank_transport_native_endpoint_wait_ready(raw, 5000) == PLANK_TRANSPORT_OK);
        AVCodecContext* codec = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_HEVC));
        CHECK(codec);
        codec->thread_count = 4;
        codec->err_recognition = AV_EF_EXPLODE;
        CHECK(avcodec_open2(codec, codec->codec, nullptr) == 0);
        AVFrame* frame = av_frame_alloc();
        AVPacket* packet = av_packet_alloc();
        int opusError;
        OpusDecoder* audio = opus_decoder_create(48000, 2, &opusError);
        CHECK(audio && opusError == OPUS_OK);
        std::vector<uint8_t> bytes(64 * 1024 * 1024);
        // GPU-less builders cannot necessarily software-decode 5K444 in real
        // time. Optional format-only mode drains media promptly and retains at
        // most eight keyframes / 64 MiB in memory for decode after disconnect.
        // This is not hardware, render, or full reference-chain qualification.
        std::vector<std::vector<uint8_t>> samples;
        size_t sampleBytes = 0;
        unsigned frames = 0, decoded = 0, audioPackets = 0, rateSent = 0, rateAck = 0;
        const uint32_t cycleRates[] = {10000, 150000, 10000, 150000};
        uint64_t lastPTS = 0, lastFrameNumber = 0;
        QElapsedTimer clock; clock.start();
        while (clock.elapsed() < 15000) {
            if (rateSent < 4 && clock.elapsed() >= (rateSent + 1) * 3000) {
                uint8_t control[20]; size_t size = 0;
                CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_SET_VIDEO_BITRATE,
                    &cycleRates[rateSent], 1, control, sizeof(control), &size));
                CHECK(plank_transport_native_data_send(raw, control, size) == PLANK_TRANSPORT_OK);
                ++rateSent;
            }
            {
                uint8_t control[20]; size_t size = 0;
                const int result = plank_transport_native_data_receive(raw, control, sizeof(control), &size, 0);
                CHECK(result == PLANK_TRANSPORT_TIMEOUT || result == PLANK_TRANSPORT_OK);
                if (result == PLANK_TRANSPORT_OK) {
                    PlankTransportControlPacket ack {};
                    CHECK(!plank_transport_control_decode(control, size, &ack));
                    CHECK(rateAck < rateSent && ack.type == PLANK_TRANSPORT_CONTROL_VIDEO_BITRATE_APPLIED && ack.payload_size == 12);
                    CHECK(plank_transport_control_read_u32(ack.payload + 4) == cycleRates[rateAck]);
                    std::printf("live_bitrate_applied_kbps=%u decoded_frames=%u opus_packets=%u\n", cycleRates[rateAck], decoded, audioPackets);
                    ++rateAck;
                }
            }
            PlankTransportNativeVideoFrameInfo video {}; video.struct_size = sizeof(video);
            size_t count = 0;
            const int result = plank_transport_native_video_receive(raw, &video, bytes.data(), bytes.size(), &count, 5);
            CHECK(result == PLANK_TRANSPORT_OK || result == PLANK_TRANSPORT_TIMEOUT);
            if (result == PLANK_TRANSPORT_OK) {
                CHECK(video.codec == PLANK_TRANSPORT_NATIVE_VIDEO_CODEC_HEVC && count > 0);
                if (lastFrameNumber && video.frame_number != lastFrameNumber + 1) {
                    std::fprintf(stderr, "native_frame_gap previous=%llu current=%llu key=%u\n",
                        static_cast<unsigned long long>(lastFrameNumber),
                        static_cast<unsigned long long>(video.frame_number), video.flags);
                    PlankTransportNativeStats stats {}; stats.struct_size = sizeof(stats);
                    if (plank_transport_native_endpoint_stats(raw, &stats) == PLANK_TRANSPORT_OK)
                        std::fprintf(stderr, "native_gap_counters receive_drops=%llu kyproto_drops=%llu source=%llu missing=%llu unrecovered=%llu\n",
                            static_cast<unsigned long long>(stats.video_receive_drops),
                            static_cast<unsigned long long>(stats.kyproto_packets_dropped),
                            static_cast<unsigned long long>(stats.video_fec_source_symbols),
                            static_cast<unsigned long long>(stats.video_fec_source_symbols_missing),
                            static_cast<unsigned long long>(stats.video_fec_source_symbols_unrecovered));
                }
                lastFrameNumber = video.frame_number;
                CHECK(!frames || video.pts > lastPTS);
                lastPTS = video.pts; ++frames;
                if (sampleKeyframes) {
                    if ((video.flags & PLANK_TRANSPORT_NATIVE_VIDEO_FLAG_KEY) && samples.size() < 8) {
                        CHECK(count <= bytes.size() - sampleBytes);
                        samples.emplace_back(bytes.begin(), bytes.begin() + count);
                        sampleBytes += count;
                    }
                } else {
                CHECK(av_new_packet(packet, static_cast<int>(count)) == 0);
                std::memcpy(packet->data, bytes.data(), count);
                CHECK(avcodec_send_packet(codec, packet) == 0);
                av_packet_unref(packet);
                int status;
                while ((status = avcodec_receive_frame(codec, frame)) == 0) {
                    CHECK(frame->width == topology.desktopWidth && frame->height == topology.desktopHeight);
                    CHECK(frame->format == (fullChroma ? AV_PIX_FMT_YUV444P10LE : AV_PIX_FMT_YUV420P10LE) && frame->color_range == AVCOL_RANGE_JPEG);
                    CHECK(frame->colorspace == AVCOL_SPC_BT709 && frame->color_primaries == AVCOL_PRI_BT709);
                    CHECK(plankAppleVideoFrameMatches(frame, codec->profile, fullChroma));
                    ++decoded;
                    av_frame_unref(frame);
                }
                CHECK(status == AVERROR(EAGAIN));
                }
            }
            for (unsigned i = 0; i < 64; ++i) {
                uint8_t opus[65536]; size_t size = 0;
                PlankTransportNativeAudioPacketInfo sound {}; sound.struct_size = sizeof(sound);
                const int got = plank_transport_native_audio_receive(raw, &sound, opus, sizeof(opus), &size, 0);
                if (got == PLANK_TRANSPORT_TIMEOUT) break;
                CHECK(got == PLANK_TRANSPORT_OK && sound.frame_samples == 240 && sound.missing_samples == 0);
                float pcm[480];
                CHECK(opus_decode_float(audio, opus, static_cast<opus_int32>(size), pcm, 240, 0) == 240);
                ++audioPackets;
            }
        }
        // A static desktop can produce fewer than a GOP's worth of SCK
        // changes. One captured keyframe is sufficient for this explicitly
        // format-only gate; bitrate response under motion is a separate test.
        CHECK(frames > 1 && (sampleKeyframes ? !samples.empty() : decoded > 1) && audioPackets > 100);
        CHECK(rateAck == 4);
        uint8_t control[20]; size_t count = 0; uint32_t bitrate = 55000;
        CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_SET_VIDEO_BITRATE, &bitrate, 1, control, sizeof(control), &count));
        CHECK(plank_transport_native_data_send(raw, control, count) == PLANK_TRANSPORT_OK);
        CHECK(plank_transport_native_data_receive(raw, control, sizeof(control), &count, 5000) == PLANK_TRANSPORT_OK);
        PlankTransportControlPacket ack {};
        CHECK(!plank_transport_control_decode(control, count, &ack));
        CHECK(ack.type == PLANK_TRANSPORT_CONTROL_VIDEO_BITRATE_APPLIED && ack.payload_size == 12);
        CHECK(plank_transport_control_read_u32(ack.payload + 4) == bitrate);
        CHECK(!plank_transport_control_encode(PLANK_TRANSPORT_CONTROL_CLIENT_DISCONNECT, nullptr, 0, control, sizeof(control), &count));
        CHECK(plank_transport_native_data_send(raw, control, count) == PLANK_TRANSPORT_OK);
        QElapsedTimer drain; drain.start();
        while (plank_transport_native_endpoint_state(raw) == PLANK_TRANSPORT_STATE_READY && drain.elapsed() < 5000)
            QThread::msleep(10);
        CHECK(plank_transport_native_endpoint_state(raw) != PLANK_TRANSPORT_STATE_READY);
        for (const auto& sample : samples) {
            avcodec_flush_buffers(codec);
            CHECK(av_new_packet(packet, static_cast<int>(sample.size())) == 0);
            std::memcpy(packet->data, sample.data(), sample.size());
            CHECK(avcodec_send_packet(codec, packet) == 0);
            av_packet_unref(packet);
            CHECK(avcodec_send_packet(codec, nullptr) == 0);
            CHECK(avcodec_receive_frame(codec, frame) == 0);
            CHECK(frame->width == topology.desktopWidth && frame->height == topology.desktopHeight);
            CHECK(plankAppleVideoFrameMatches(frame, codec->profile, fullChroma));
            ++decoded;
            av_frame_unref(frame);
        }
        opus_decoder_destroy(audio); av_packet_free(&packet); av_frame_free(&frame); avcodec_free_context(&codec);
        std::printf("installed_mac_client=pass network_frames=%u decoded_frames=%u opus_packets=%u pixels=%dx%d chroma=%s exact_profile=1 bitrate_ack=1 disconnect=1 graphical_client=0 input_posting=0 keyframes_only=%d\n",
                    frames, decoded, audioPackets, topology.desktopWidth, topology.desktopHeight, fullChroma ? "444" : "420", sampleKeyframes);
    } catch (const GfeHttpResponseException& error) {
        std::fprintf(stderr, "HTTP failure: %d\n", error.getStatusCode()); return 1;
    } catch (const QtNetworkReplyException& error) {
        std::fprintf(stderr, "Network failure: %s\n", qPrintable(error.toQString())); return 1;
    }
}
