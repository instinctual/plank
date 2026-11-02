#include "backend/macpreviewlaunch.h"
#include <QCoreApplication>
#include <QFile>
#include <QFileInfo>
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
    NvOutputTopology topology;
    CHECK(NvOutputTopology::fromJson(rawTopology, topology));
    // One shared Host/Client vector fixes each independent feature contract.
    QFile featureFile(QFileInfo(requestFile).absolutePath() + "/media-feature-negotiation-v1.json");
    CHECK(featureFile.open(QIODevice::ReadOnly));
    const auto vector = QJsonDocument::fromJson(featureFile.readAll()).object();
    auto offer = vector.value("offer").toObject();
    auto negotiation = vector.value("response").toObject();
    auto featureLaunch = vector.value("launch").toObject();
    CHECK(featureLaunch == expected);
    auto offered = offer.value("features").toObject();
    auto chosen = negotiation.value("features").toObject();
    auto launchFeatures = featureLaunch.value("features").toObject();
    for (const auto& name : {QStringLiteral("clipboard"), QStringLiteral("camera")}) {
        if ((name == QLatin1String("clipboard") && !NvOutputTopology::PlatformClipboardSyncFeature) ||
            (name == QLatin1String("camera") && !MacPreviewLaunch::CameraSupported)) {
            offered[name] = QJsonArray {}; chosen[name] = QJsonValue::Null; launchFeatures[name] = QJsonValue::Null;
        }
    }
#ifdef Q_OS_LINUX
    auto microphoneOffers = offered.value("microphone").toArray();
    microphoneOffers.prepend(vector.value("timed_microphone")); offered["microphone"] = microphoneOffers;
#endif
    offer["features"] = offered; negotiation["features"] = chosen; featureLaunch["features"] = launchFeatures;
    CHECK(MacMediaFeatures::offer(topology.appleEncodingMode) == offer);
    const auto invalidMode = topology.appleEncodingMode + QChar(0) + QStringLiteral("extra");
    CHECK(!MacMediaFeatures::encodingSupported(invalidMode));
    CHECK(MacMediaFeatures::offer(invalidMode).isEmpty());
    auto invalidTopology = rawTopology;
    auto invalidCapture = rawTopology.value("capture").toObject();
    auto invalidProfile = invalidCapture.value("encoding_profile").toObject();
    invalidProfile["encoding_mode"] = invalidMode;
    invalidCapture["encoding_profile"] = invalidProfile;
    invalidTopology["capture"] = invalidCapture;
    NvOutputTopology rejected;
    CHECK(!NvOutputTopology::fromJson(invalidTopology, rejected));
    MacMediaFeatures::Agreement agreement;
    CHECK(MacMediaFeatures::select(negotiation, topology.appleEncodingMode, agreement));
    const int bitrate = 50000;
    CHECK(MacPreviewLaunch::request(topology, bitrate, 1200, agreement) == featureLaunch);
    QJsonObject featureReply {
        {"schema_version", 7}, {"state", "connecting"}, {"udp_port", 28989},
        {"max_udp_payload_size", 1200}, {"capture", rawTopology.value("capture")},
        {"transport_token", QString::fromLatin1(QByteArray(32, 'x').toBase64())},
        {"transport", MacMediaFeatures::transport()}, {"required_features", MacMediaFeatures::required()},
        {"features", launchFeatures}
    };
    MacPreviewLaunch::Reply parsed;
    CHECK(MacPreviewLaunch::parseReply(featureReply, topology, 28989, 1200, parsed, agreement, bitrate));
    CHECK(parsed.microphone);
    for (const auto& name : {QStringLiteral("clipboard"), QStringLiteral("microphone"), QStringLiteral("camera")}) {
        auto fewer = launchFeatures; fewer[name] = QJsonValue::Null;
        auto response = featureReply; response["features"] = fewer;
        CHECK(MacPreviewLaunch::parseReply(response, topology, 28989, 1200, parsed, agreement, bitrate));
    }
    for (const auto& name : MacMediaFeatures::required()) {
        auto fewer = launchFeatures; fewer[name.toString()] = QJsonValue::Null;
        auto response = featureReply; response["features"] = fewer;
        CHECK(!MacPreviewLaunch::parseReply(response, topology, 28989, 1200, parsed, agreement, bitrate));
        CHECK(parsed.transportToken.isEmpty());
    }
    auto additive = negotiation;
    auto extraFeatures = chosen; extraFeatures["future_optional"] = QJsonObject {{"schema_version", 12}};
    additive["features"] = extraFeatures; additive["future_hint"] = true;
    CHECK(MacMediaFeatures::select(additive, topology.appleEncodingMode, agreement));
    auto desktopExtra = extraFeatures.value("desktop").toObject(); desktopExtra["future_hint"] = true;
    extraFeatures["desktop"] = desktopExtra; additive["features"] = extraFeatures;
    CHECK(MacMediaFeatures::select(additive, topology.appleEncodingMode, agreement));
    auto requiredExtra = MacMediaFeatures::required(); requiredExtra.append("future_optional");
    additive["required_features"] = requiredExtra;
    CHECK(!MacMediaFeatures::select(additive, topology.appleEncodingMode, agreement));
    CHECK(agreement.launchSchema == 0);
    for (const QJsonValue& wrong : {QJsonValue(true), QJsonValue(2), QJsonValue(1.5)}) {
        auto response = negotiation; response["schema_version"] = wrong;
        CHECK(!MacMediaFeatures::select(response, topology.appleEncodingMode, agreement));
    }
    for (const auto& name : MacMediaFeatures::names()) {
        auto response = negotiation; auto changed = chosen;
        auto profile = MacMediaFeatures::profile(name, topology.appleEncodingMode);
        profile["schema_version"] = 999; changed[name] = profile; response["features"] = changed;
        CHECK(!MacMediaFeatures::select(response, topology.appleEncodingMode, agreement));
    }
    auto incompatibleTransport = negotiation; incompatibleTransport["transport"] = "plank-native/1";
    CHECK(!MacMediaFeatures::select(incompatibleTransport, topology.appleEncodingMode, agreement));

    auto timedNegotiation = negotiation; auto timedChosen = chosen;
    timedChosen["microphone"] = vector.value("timed_microphone"); timedNegotiation["features"] = timedChosen;
#ifdef Q_OS_LINUX
    CHECK(MacMediaFeatures::select(timedNegotiation, topology.appleEncodingMode, agreement));
    auto timedLaunch = MacPreviewLaunch::request(topology, bitrate, 1200, agreement);
    auto timedReply = featureReply; timedReply["features"] = timedLaunch.value("features");
    CHECK(MacPreviewLaunch::parseReply(timedReply, topology, 28989, 1200, parsed, agreement, bitrate));
    CHECK(parsed.microphoneSchema == 3);
    CHECK(!MacPreviewLaunch::parseReply(featureReply, topology, 28989, 1200, parsed, agreement, bitrate));
    // Older Hosts select the second, untimed stereo offer. Launch keeps that agreement.
    CHECK(MacMediaFeatures::select(negotiation, topology.appleEncodingMode, agreement));
    CHECK(MacPreviewLaunch::parseReply(featureReply, topology, 28989, 1200, parsed, agreement, bitrate));
    CHECK(parsed.microphoneSchema == 2);
#else
    CHECK(!MacMediaFeatures::select(timedNegotiation, topology.appleEncodingMode, agreement));
#endif
    CHECK(MacMediaFeatures::select(negotiation, topology.appleEncodingMode, agreement));
    CHECK(MacPreviewLaunch::parseReply(featureReply, topology, 28989, 1200, parsed, agreement, bitrate));
    CHECK(parsed.configuration.serviceFlags == (PLANK_NATIVE_SERVICE_AUDIO | PLANK_NATIVE_SERVICE_INPUT));
    CHECK(parsed.configuration.hostFeatureFlags == (LI_FF_DYNAMIC_VIDEO_BITRATE | LI_FF_ENCODER_TARGET_ACK | LI_FF_PEN_TOUCH_EVENTS));
    CHECK(parsed.configuration.audioPacketDurationMs == 5);
    CHECK(parsed.configuration.opusConfiguration.sampleRate == 48000);
    CHECK(parsed.configuration.opusConfiguration.channelCount == 2);
    CHECK(parsed.configuration.opusConfiguration.streams == 1);
    CHECK(parsed.configuration.opusConfiguration.coupledStreams == 1);
    CHECK(parsed.configuration.opusConfiguration.mapping[0] == 0 && parsed.configuration.opusConfiguration.mapping[1] == 1);
    CHECK(MacPreviewLaunch::request(topology, 9999, 1200, agreement).isEmpty());
    CHECK(MacPreviewLaunch::request(topology, 150001, 1200, agreement).isEmpty());
    CHECK(MacPreviewLaunch::request(topology, 10000, 1199, agreement).isEmpty());
    CHECK(MacPreviewLaunch::request(topology, 10000, 65528, agreement).isEmpty());
    CHECK(!MacPreviewLaunch::request(topology, 150000, 65527, agreement).isEmpty());
    CHECK(MacPreviewLaunch::request({}, 10000, 1200, agreement).isEmpty());
    auto reject = [&](const QJsonObject& bad) {
        CHECK(MacPreviewLaunch::parseReply(featureReply, topology, 28989, 1200, parsed, agreement, bitrate));
        CHECK(!MacPreviewLaunch::parseReply(bad, topology, 28989, 1200, parsed, agreement, bitrate));
        CHECK(parsed.transportToken.isEmpty() && parsed.configuration.structSize == 0);
    };
    for (const auto& key : featureReply.keys()) {
        auto bad = featureReply; bad.remove(key); reject(bad);
        bad = featureReply; bad[key] = QJsonValue::Null; reject(bad);
    }
    for (const char* key : {"udp_port", "schema_version", "max_udp_payload_size"}) {
        auto bad = featureReply; bad[key] = true; reject(bad);
        bad[key] = featureReply.value(key).toDouble() + 0.5; reject(bad);
    }
    for (int schema : {3, 4, 5, 6}) {
        auto bad = featureReply; bad["schema_version"] = schema; reject(bad);
        auto oldAgreement = agreement; oldAgreement.launchSchema = schema;
        CHECK(MacPreviewLaunch::request(topology, bitrate, 1200, oldAgreement).isEmpty());
    }
    auto bad = featureReply; bad["udp_port"] = 443; reject(bad);
    bad = featureReply; bad["max_udp_payload_size"] = 1500; reject(bad);
    bad = featureReply; bad["transport_token"] = QString(44, 'x'); reject(bad);
    bad = featureReply; bad["transport_token"] = QString::fromLatin1(QByteArray(31, 'x').toBase64()); reject(bad);
    auto capture = rawTopology.value("capture").toObject(); capture["width"] = capture.value("width").toInt() + 2;
    bad = featureReply; bad["capture"] = capture; reject(bad);
    CHECK(!MacPreviewLaunch::parseReply(featureReply, topology, 28990, 1200, parsed, agreement, bitrate));
    CHECK(!MacPreviewLaunch::parseReply(featureReply, topology, 28989, 1300, parsed, agreement, bitrate));
    auto full = topology; full.appleEncodingMode = QStringLiteral("hevc-10-444-videotoolbox");
    auto fullNegotiation = negotiation; auto fullFeatures = chosen;
    fullFeatures["desktop"] = MacMediaFeatures::profile("desktop", full.appleEncodingMode);
    fullNegotiation["features"] = fullFeatures;
    MacMediaFeatures::Agreement fullAgreement;
    CHECK(MacMediaFeatures::select(fullNegotiation, full.appleEncodingMode, fullAgreement));
    auto fullReply = featureReply; fullReply["capture"] = full.toJson().value("capture");
    fullReply["features"] = MacPreviewLaunch::request(full, bitrate, 1200, fullAgreement).value("features");
    CHECK(MacPreviewLaunch::parseReply(fullReply, full, 28989, 1200, parsed, fullAgreement, bitrate));
    CHECK(parsed.configuration.negotiatedVideoFormat == VIDEO_FORMAT_H265_REXT10_444);
    CHECK(!MacPreviewLaunch::parseReply(featureReply, full, 28989, 1200, parsed, fullAgreement, bitrate));
    CHECK(!MacPreviewLaunch::parseReply(fullReply, topology, 28989, 1200, parsed, agreement, bitrate));
    std::printf("Mac media launch: %u checks passed\n", checks);
}
