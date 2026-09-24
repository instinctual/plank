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
    expected["camera"] = MacPreviewLaunch::CameraSupported;
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
        {"schema_version", 6}, {"state", "connecting"}, {"udp_port", 28989},
        {"max_udp_payload_size", 1200}, {"capture", rawTopology.value("capture")},
        {"transport_token", QString::fromLatin1(QByteArray(32, 'x').toBase64())},
        {"services", QJsonObject {{"audio", true}, {"input", true}, {"pen", "normalized"}, {"cursor", "embedded"}, {"clipboard", false}, {"microphone", false}, {"camera", false}}}
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
    CHECK(!parsed.camera);
    auto cameraReply = valid;
    auto cameraServices = valid.value("services").toObject();
    cameraServices["camera"] = true; cameraReply["services"] = cameraServices;
    CHECK(MacPreviewLaunch::parseReply(cameraReply, topology, 28989, 1200, parsed) == MacPreviewLaunch::CameraSupported);
    CHECK(parsed.camera == MacPreviewLaunch::CameraSupported);
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
    bad = valid; bad["schema_version"] = 4; reject(bad);
    bad = valid; bad["schema_version"] = 5; reject(bad);
    for (const QJsonValue& value : {QJsonValue(), QJsonValue(1), QJsonValue("true")}) {
        auto services = valid.value("services").toObject(); services["camera"] = value;
        bad = valid; bad["services"] = services; reject(bad);
    }
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

    // One shared Host/Client vector fixes each independent feature contract.
    QFile featureFile(QFileInfo(requestFile).absolutePath() + "/media-feature-negotiation-v1.json");
    CHECK(featureFile.open(QIODevice::ReadOnly));
    const auto vector = QJsonDocument::fromJson(featureFile.readAll()).object();
    auto offer = vector.value("offer").toObject();
    auto negotiation = vector.value("response").toObject();
    auto featureLaunch = vector.value("launch").toObject();
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
    MacMediaFeatures::Agreement agreement;
    CHECK(MacMediaFeatures::select(negotiation, topology.appleEncodingMode, agreement));
    const int bitrate = expected.value("bitrate_kbps").toInt();
    CHECK(MacPreviewLaunch::request(topology, bitrate, 1200, agreement) == featureLaunch);
    auto featureReply = valid;
    featureReply.remove("services"); featureReply["schema_version"] = 7;
    featureReply["transport"] = MacMediaFeatures::transport();
    featureReply["required_features"] = MacMediaFeatures::required();
    featureReply["features"] = launchFeatures;
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
    for (int schema : {4, 5, 6}) {
        const auto legacy = MacMediaFeatures::legacy(schema, topology.appleEncodingMode);
        const auto request = MacPreviewLaunch::request(topology, 50000, 1200, legacy);
        CHECK(request.value("schema_version") == schema);
        CHECK(request.size() == (schema == 6 ? 12 : 11));
        CHECK(request.value("microphone") == QJsonValue(schema >= 5));
        CHECK(request.contains("camera") == (schema == 6));
        auto response = valid; response["schema_version"] = schema;
        auto services = response.value("services").toObject();
        if (schema < 6) services.remove("camera");
        services["microphone"] = schema >= 5; response["services"] = services;
        CHECK(MacPreviewLaunch::parseReply(response, topology, 28989, 1200, parsed, legacy, 50000));
        CHECK(parsed.microphone == (schema >= 5) && !parsed.camera);
        if (schema == 4) {
            services["microphone"] = true; response["services"] = services;
            CHECK(!MacPreviewLaunch::parseReply(response, topology, 28989, 1200, parsed, legacy, 50000));
        }
    }
    for (const QString& version : {QStringLiteral("1.0.156"), QStringLiteral("1.0.157-microphone-forwarding"), QStringLiteral("1.1.001")})
        CHECK(MacMediaFeatures::legacySchema(version) == 4);
    CHECK(MacMediaFeatures::legacySchema("1.1.002-native-media-investigation") == 5);
    CHECK(MacMediaFeatures::legacySchema("1.1.003-native-media-investigation") == 6);
    for (const QString& version : {QStringLiteral("1.1.004"), QStringLiteral("1.0.155"), QStringLiteral("1.1.2"), QStringLiteral("1.1.002/extra"), QString()})
        CHECK(MacMediaFeatures::legacySchema(version) == 0);
    std::printf("Mac preview launch: %u checks passed\n", checks);
}
