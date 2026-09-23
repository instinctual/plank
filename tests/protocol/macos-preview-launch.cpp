#include "backend/macpreviewlaunch.h"
#include <QCoreApplication>
#include <QFile>
#include <QJsonDocument>
#include <cstdio>
#include <cstdlib>

static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { \
    std::fprintf(stderr, "line %d: %s\n", __LINE__, #x); std::exit(1); } } while (0)

int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    CHECK(argc == 3);
    QFile topologyFile(QString::fromLocal8Bit(argv[1]));
    QFile requestFile(QString::fromLocal8Bit(argv[2]));
    CHECK(topologyFile.open(QIODevice::ReadOnly));
    CHECK(requestFile.open(QIODevice::ReadOnly));
    const auto rawTopology = QJsonDocument::fromJson(topologyFile.readAll()).object();
    auto expected = QJsonDocument::fromJson(requestFile.readAll()).object();
    expected["clipboard"] = NvOutputTopology::PlatformClipboardSyncFeature != 0;
    NvOutputTopology topology;
    CHECK(NvOutputTopology::fromJson(rawTopology, topology));
    CHECK(MacPreviewLaunch::request(topology, expected.value("bitrate_kbps").toInt(),
                                   expected.value("max_udp_payload_size").toInt()) == expected);
    CHECK(MacPreviewLaunch::request(topology, 9999, 1200).isEmpty());
    CHECK(MacPreviewLaunch::request(topology, 150001, 1200).isEmpty());
    CHECK(MacPreviewLaunch::request(topology, 10000, 1199).isEmpty());
    CHECK(MacPreviewLaunch::request(topology, 10000, 65528).isEmpty());
    CHECK(!MacPreviewLaunch::request(topology, 150000, 65527).isEmpty());
    CHECK(MacPreviewLaunch::request({}, 10000, 1200).isEmpty());
    const QJsonObject valid {
        {"schema_version", 4}, {"state", "connecting"}, {"udp_port", 28989},
        {"max_udp_payload_size", 1200}, {"capture", rawTopology.value("capture")},
        {"transport_token", QString::fromLatin1(QByteArray(32, 'x').toBase64())},
        {"services", QJsonObject {{"audio", true}, {"input", true}, {"pen", "normalized"}, {"cursor", "embedded"}, {"clipboard", false}, {"microphone", false}}}
    };
    MacPreviewLaunch::Reply parsed;
    CHECK(MacPreviewLaunch::parseReply(valid, topology, 28989, 1200, parsed));
    CHECK(parsed.configuration.serviceFlags == (PLANK_NATIVE_SERVICE_AUDIO | PLANK_NATIVE_SERVICE_INPUT));
    CHECK(parsed.configuration.hostFeatureFlags == (LI_FF_DYNAMIC_VIDEO_BITRATE | LI_FF_ENCODER_TARGET_ACK | LI_FF_PEN_TOUCH_EVENTS));
    CHECK(parsed.configuration.audioPacketDurationMs == 5);
    CHECK(parsed.configuration.opusConfiguration.sampleRate == 48000);
    CHECK(parsed.configuration.opusConfiguration.channelCount == 2);
    CHECK(parsed.configuration.opusConfiguration.streams == 1);
    CHECK(parsed.configuration.opusConfiguration.coupledStreams == 1);
    CHECK(parsed.configuration.opusConfiguration.mapping[0] == 0);
    CHECK(parsed.configuration.opusConfiguration.mapping[1] == 1);
    CHECK(parsed.configuration.negotiatedVideoFormat == VIDEO_FORMAT_H265_MAIN10);
    CHECK(parsed.configuration.sessionPort == 28989);
    CHECK(!parsed.clipboard);
    CHECK(!parsed.microphone);
    auto microphoneReply = valid;
    auto microphoneServices = valid.value("services").toObject();
    microphoneServices["microphone"] = true;
    microphoneReply["services"] = microphoneServices;
    CHECK(MacPreviewLaunch::parseReply(microphoneReply, topology, 28989, 1200, parsed));
    CHECK(parsed.microphone);
    auto clipboardReply = valid;
    auto clipboardServices = valid.value("services").toObject();
    clipboardServices["clipboard"] = true;
    clipboardReply["services"] = clipboardServices;
    CHECK(MacPreviewLaunch::parseReply(clipboardReply, topology, 28989, 1200, parsed) ==
          (NvOutputTopology::PlatformClipboardSyncFeature != 0));
    if (NvOutputTopology::PlatformClipboardSyncFeature) CHECK(parsed.clipboard);
    auto reject = [&](const QJsonObject& bad) {
        CHECK(MacPreviewLaunch::parseReply(valid, topology, 28989, 1200, parsed));
        CHECK(!MacPreviewLaunch::parseReply(bad, topology, 28989, 1200, parsed));
        CHECK(parsed.transportToken.isEmpty() && parsed.configuration.structSize == 0);
    };
    for (const auto& key : valid.keys()) {
        auto bad = valid; bad.remove(key); reject(bad);
        bad = valid; bad[key] = QJsonValue::Null; reject(bad);
    }
    for (const char* key : {"udp_port", "schema_version", "max_udp_payload_size"}) {
        auto bad = valid; bad[key] = true; reject(bad);
        bad[key] = valid.value(key).toDouble() + 0.5; reject(bad);
    }
    auto bad = valid; bad["udp_port"] = 443; reject(bad);
    bad = valid; bad["schema_version"] = 3; reject(bad);
    auto invalidServices = valid.value("services").toObject(); invalidServices.remove("microphone");
    bad = valid; bad["services"] = invalidServices; reject(bad);
    invalidServices["microphone"] = 1;
    bad["services"] = invalidServices; reject(bad);
    bad = valid; bad["max_udp_payload_size"] = 1500; reject(bad);
    bad = valid; bad["remote_address"] = "another-host"; reject(bad);
    bad = valid; bad["certificate_sha256"] = "another-certificate"; reject(bad);
    bad = valid; bad["transport_token"] = QString(44, 'x'); reject(bad);
    bad = valid; bad["transport_token"] = QString::fromLatin1(QByteArray(31, 'x').toBase64()); reject(bad);
    for (const char* service : {"audio", "input", "pen", "cursor"}) {
        auto services = valid.value("services").toObject(); services[service] = false;
        bad = valid; bad["services"] = services; reject(bad);
    }
    for (const QJsonValue& value : {QJsonValue(), QJsonValue(1), QJsonValue("true")}) {
        auto services = valid.value("services").toObject(); services["clipboard"] = value;
        bad = valid; bad["services"] = services; reject(bad);
    }
    auto capture = rawTopology.value("capture").toObject();
    capture["width"] = capture.value("width").toInt() + 2;
    bad = valid; bad["capture"] = capture; reject(bad);
    CHECK(!MacPreviewLaunch::parseReply(valid, topology, 28990, 1200, parsed));
    CHECK(!MacPreviewLaunch::parseReply(valid, topology, 28989, 1300, parsed));
    auto full = topology;
    full.appleEncodingMode = QStringLiteral("hevc-10-444-videotoolbox");
    NvOutputTopology checked;
    CHECK(NvOutputTopology::fromJson(full.toJson(), checked));
    CHECK(checked.appleEncodingMode == full.appleEncodingMode);
    CHECK(MacPreviewLaunch::request(full, 50000, 1200).value("encoding_mode") == QJsonValue(full.appleEncodingMode));
    auto fullReply = valid;
    fullReply["capture"] = full.toJson().value("capture");
    CHECK(MacPreviewLaunch::parseReply(fullReply, full, 28989, 1200, parsed));
    CHECK(parsed.configuration.negotiatedVideoFormat == VIDEO_FORMAT_H265_REXT10_444);
    CHECK(!MacPreviewLaunch::parseReply(valid, full, 28989, 1200, parsed));
    CHECK(!MacPreviewLaunch::parseReply(fullReply, topology, 28989, 1200, parsed));
    full.appleEncodingMode = QStringLiteral("invalid");
    CHECK(MacPreviewLaunch::request(full, 50000, 1200).isEmpty());
    std::printf("Mac preview launch: %u checks passed\n", checks);
}
