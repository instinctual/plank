// Real NvHTTP over an ephemeral synthetic TLS server. No product auth bypass.
#include "backend/nvhttp.h"
#include <QCoreApplication>
#include <QFile>
#include <QJsonDocument>
#include <cstdio>

int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    if (argc != 3) return 2;
    const QString mode = QString::fromLocal8Bit(argv[1]);
    bool validPort;
    const int port = QString::fromLocal8Bit(argv[2]).toInt(&validPort);
    if (!validPort || port < 1 || port > 65535) return 2;
    QFile input;
    if (!input.open(stdin, QIODevice::ReadOnly)) return 2;
    const auto values = QJsonDocument::fromJson(input.readAll()).object();
    NvHTTP http(NvAddress(QStringLiteral("127.0.0.1"), static_cast<quint16>(port)));
    const bool busy = mode == QLatin1String("auth-busy");
    const bool auth = mode.startsWith(QLatin1String("auth-"));
    const bool success = mode == QLatin1String("success") || mode == QLatin1String("negotiate-optional") ||
        mode == QLatin1String("microphone-timed") || mode == QLatin1String("microphone-timed-disabled") ||
        mode == QLatin1String("legacy-4") || mode == QLatin1String("legacy-5") || mode == QLatin1String("legacy-6");
    const bool unknown = mode == QLatin1String("auth-first") || mode == QLatin1String("auth-recovery-unknown");
    // Trust only the out-of-band certificate supplied by this synthetic test
    // fixture. No product bypass or trusting the network leaf after sending.
    const auto identity = HostTlsGuard::identityKey({QSslCertificate(values.value("certificate").toString().toUtf8())});
    const QString endpoint = HostTrustStore::endpoint(QUrl(QString("https://127.0.0.1:%1").arg(port)));
    if (!unknown && HostTrustStore().check(endpoint, identity, true).status != HostTrustStore::Status::Trusted) return 2;
    if (!auth) http.setPlankSessionToken(values.value("token").toString(), identity);
    if (auth && !busy) {
        int prompts = 0;
        const bool accept = mode == QLatin1String("auth-replace-accept");
        if (mode.startsWith(QLatin1String("auth-replace-")))
            http.setTrustPrompt([&](const HostIdentityChangedException& change) {
                ++prompts;
                return accept && change.previousKey == identity && change.replacementKey.size() == 32;
            });
        try {
            const auto result = http.authenticate(QStringLiteral("synthetic"), QStringLiteral("fixture-password"), nullptr,
                mode.startsWith(QLatin1String("auth-recovery-")) ? NvHTTP::AuthenticationIntent::Recovery :
                                                                 NvHTTP::AuthenticationIntent::ExplicitConnection);
            if (mode != QLatin1String("auth-first") && mode != QLatin1String("auth-recovery-known") && !accept) return 1;
            if (result != values.value("token").toString() || prompts != (accept ? 1 : 0)) return 1;
            if (HostTrustStore().check(endpoint, http.hostIdentityKey()).status != HostTrustStore::Status::Trusted) return 1;
        } catch (const QtNetworkReplyException& error) {
            const auto expected = mode == QLatin1String("auth-replace-cancel") ?
                QNetworkReply::OperationCanceledError : QNetworkReply::SslHandshakeFailedError;
            if (mode != QLatin1String("auth-replace-cancel") && mode != QLatin1String("auth-changed") &&
                mode != QLatin1String("auth-recovery-unknown") && mode != QLatin1String("auth-mid-change")) return 1;
            if (error.getError() != expected || prompts != (mode == QLatin1String("auth-replace-cancel") ? 1 : 0)) return 1;
        }
        std::puts("client_authentication_trust=pass");
        return 0;
    }
    try {
        if (busy) { http.authenticate(QStringLiteral("synthetic"), QStringLiteral("test")); return 1; }
        QString pin;
        const auto topology = http.getOutputTopology(&pin);
        if (pin.size() != 64) return 1;
        if (mode == QLatin1String("wrong-pin")) pin = QString(64, QLatin1Char('0'));
        const auto result = http.startMacPreview(topology, pin, 50000, 1200);
        if (!success ||
                result.transportToken != QByteArray(32, 'x').toBase64() ||
                result.configuration.serviceFlags != (PLANK_NATIVE_SERVICE_AUDIO | PLANK_NATIVE_SERVICE_INPUT) ||
                result.configuration.sessionPort != static_cast<uint32_t>(port) ||
                result.configuration.negotiatedVideoFormat != VIDEO_FORMAT_H265_MAIN10) {
            std::fprintf(stderr, "manifest check failed: services=%u port=%u format=%u\n",
                         result.configuration.serviceFlags, result.configuration.sessionPort,
                         result.configuration.negotiatedVideoFormat);
            return 1;
        }
        if (result.microphone != (mode == QLatin1String("microphone-timed")) ||
                (result.microphone && result.microphoneSchema != 3)) return 1;
        // The same NvHTTP cannot replay its consumed HTTP token.
        try { http.startMacPreview(topology, pin, 50000, 1200); return 1; }
        catch (const GfeHttpResponseException& error) { if (error.getStatusCode() != 400) return 1; }
    } catch (const GfeHttpResponseException& error) {
        const int expected = busy ? 503 : mode == QLatin1String("wrong-pin") || mode == QLatin1String("certificate-swap") ||
                mode == QLatin1String("legacy-pin-change") ? 401 :
                (mode == QLatin1String("denied") || mode == QLatin1String("permissions") || mode == QLatin1String("negotiate-denied")) ? 403 :
                (mode == QLatin1String("redirect") || mode == QLatin1String("negotiate-redirect")) ? 307 :
                (mode == QLatin1String("legacy-unknown") || mode == QLatin1String("negotiate-incompatible") ||
                 mode == QLatin1String("negotiate-required") || mode == QLatin1String("negotiate-profile")) ? 426 : 400;
        if (success || error.getStatusCode() != expected) {
            std::fprintf(stderr, "unexpected HTTP status %d (expected %d)\n", error.getStatusCode(), expected);
            return 1;
        }
        if (mode == QLatin1String("permissions") &&
                !error.toQString().contains(QStringLiteral("PLANK Host requires macOS permissions"))) return 1;
        if (busy && !error.toQString().contains(QStringLiteral("Host authentication is busy"))) return 1;
        if (error.toQString().contains(QStringLiteral("do-not-log-this-response"))) return 1;
        try { http.getOutputTopology(); return 1; }
        catch (const GfeHttpResponseException& consumed) { if (consumed.getStatusCode() != 400) return 1; }
    } catch (const QtNetworkReplyException& error) {
        const bool tlsFailure = mode == QLatin1String("wrong-pin") || mode == QLatin1String("certificate-swap") ||
            mode == QLatin1String("legacy-pin-change");
        if (mode != QLatin1String("timeout") && mode != QLatin1String("negotiate-timeout") && !tlsFailure) return 1;
        if (tlsFailure && error.getError() != QNetworkReply::SslHandshakeFailedError) return 1;
        try { http.getOutputTopology(); return 1; }
        catch (const GfeHttpResponseException& consumed) { if (consumed.getStatusCode() != 400) return 1; }
    }
    std::puts("macos_client_https_launch=pass");
    return 0;
}
