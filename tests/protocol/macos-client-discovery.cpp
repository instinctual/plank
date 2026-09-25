// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the existing Client parser, not a substitute XML implementation.
#include "backend/nvcomputer.h"
#include <QCoreApplication>
#include <QFile>
#include <QTemporaryDir>
#include <cstdio>

int main(int argc, char **argv)
{
    QCoreApplication application(argc, argv);
    if (argc != 2) return 2;
    QFile fixture(QString::fromLocal8Bit(argv[1]));
    if (!fixture.open(QIODevice::ReadOnly)) return 2;
    const QString xml = QString::fromUtf8(fixture.readAll());
    try {
        NvHTTP::verifyResponseStatus(xml);
        NvHTTP http(NvAddress(QStringLiteral("127.0.0.1"), 28989));
        NvComputer computer(http, xml);
        if (computer.name != QStringLiteral("PLANK Mac qualification") ||
                computer.uuid != QStringLiteral("f92140f5-8740-4b3b-82f7-74db5353de27") ||
                computer.state != NvComputer::CS_ONLINE || !computer.plankAuthentication ||
                computer.authorizationState != NvComputer::AS_UNAUTHORIZED ||
                computer.plankHostMetadataVersion != 1 ||
                computer.plankHostVersion != QStringLiteral("macos-host-qualification") ||
                computer.serverCodecModeSupport != 0 || computer.plankFeatureFlags != 0 ||
                computer.plankTopologyVersion != 0 || computer.plankOccupied ||
                computer.currentGameId != 0 ||
                !computer.displayModes.isEmpty() || !computer.sessionToken.isEmpty() ||
                !computer.localAddress.isNull() || !computer.remoteAddress.isNull()) return 1;
        NvHTTP wrongPort(NvAddress(QStringLiteral("127.0.0.1"), 28990));
        bool rejectedPort = false;
        try { NvComputer invalid(wrongPort, xml); }
        catch (const GfeHttpResponseException& exception) { rejectedPort = exception.getStatusCode() == 400; }
        if (!rejectedPort) return 1;
        // Actual parser/update paths: advisory metadata grants no authority.
        const auto occupiedXml = [&](const QString& bit, const QString& name) {
            QString result = xml;
            result.replace(QStringLiteral("<PlankOccupied>0</PlankOccupied>"),
                           QStringLiteral("<PlankOccupied>%1</PlankOccupied><PlankSessionUser>%2</PlankSessionUser>").arg(bit, name));
            return result;
        };
        const QString occupied = occupiedXml(QStringLiteral("1"), QStringLiteral("example-user"));
        NvComputer busy(http, occupied);
        if (!busy.plankOccupied || busy.plankSessionUser != QStringLiteral("example-user") ||
                busy.authorizationState != NvComputer::AS_UNAUTHORIZED) return 1;
        computer.update(busy);
        if (!computer.plankOccupied || computer.plankSessionUser != busy.plankSessionUser) return 1;
        NvComputer free(http, xml);
        computer.update(free);
        if (computer.plankOccupied || !computer.plankSessionUser.isEmpty()) return 1;
        for (const QString& bit : {QString(), QStringLiteral("0"), QStringLiteral("2"), QStringLiteral("true")}) {
            const QString response = occupiedXml(bit, QStringLiteral("example-user"));
            if (NvHTTP::getPlankOccupied(response) || !NvHTTP::getPlankSessionUser(response).isEmpty()) return 1;
        }
        for (const QString& name : {QString(), QStringLiteral("&lt;markup&gt;"), QStringLiteral("two words"),
                QStringLiteral("name@realm"), QStringLiteral("line\nfeed"), QString(65, QLatin1Char('x'))}) {
            if (!NvHTTP::getPlankSessionUser(occupiedXml(QStringLiteral("1"), name)).isEmpty()) return 1;
        }
        if (NvHTTP::getPlankSessionUser(occupiedXml(QStringLiteral("1"), QString(64, QLatin1Char('x')))).size() != 64)
            return 1;
        QTemporaryDir temporary;
        if (!temporary.isValid()) return 2;
        QSettings ephemeral(temporary.filePath(QStringLiteral("occupancy.ini")), QSettings::IniFormat);
        busy.serialize(ephemeral, false);
        NvComputer reopenedBusy(ephemeral);
        if (reopenedBusy.plankOccupied || !reopenedBusy.plankSessionUser.isEmpty()) return 1;
        QSettings saved(temporary.filePath(QStringLiteral("bookmark.ini")), QSettings::IniFormat);
        saved.setValue(QStringLiteral("plank-video-profile"), 7);
        saved.setValue(QStringLiteral("plank-capture-source"), 2);
        saved.setValue(QStringLiteral("plank-host-layout"), QStringLiteral("fixed"));
        saved.setValue(QStringLiteral("plank-profile-bitrates-kbps"),
                       QVariantList{76500, 68500, 99000, 10000, 150000, 42500, 51000});
        NvComputer bookmark(saved);
        if (bookmark.plankVideoProfile != 7 || bookmark.plankCaptureSource != 2 ||
                bookmark.plankHostLayout != QStringLiteral("fixed") ||
                bookmark.plankProfileBitratesKbps.size() != StreamingPreferences::PLANK_PROFILE_COUNT ||
                bookmark.plankProfileBitratesKbps[0] != 76500 ||
                bookmark.plankProfileBitratesKbps[6] != 51000 ||
                bookmark.plankProfileBitratesKbps[7] != 50000) return 1;
        bookmark.plankProfileBitratesKbps[7] = 62500;
        bookmark.serialize(saved, false);
        saved.sync();
        if (saved.status() != QSettings::NoError) return 1;
        QSettings reloaded(temporary.filePath(QStringLiteral("bookmark.ini")), QSettings::IniFormat);
        NvComputer restored(reloaded);
        if (restored.plankVideoProfile != 7 || restored.plankCaptureSource != 2 ||
                restored.plankHostLayout != QStringLiteral("fixed") ||
                restored.plankProfileBitratesKbps != bookmark.plankProfileBitratesKbps ||
                !restored.sessionToken.isEmpty()) return 1;
        // Matching remains a per-bookmark policy across process restarts,
        // independent of either Apple encoding profile and saved fixed size.
        for (int profile : {7, 8}) {
            saved.setValue(QStringLiteral("plank-video-profile"), profile);
            saved.setValue(QStringLiteral("plank-host-layout"), QStringLiteral("match-client"));
            NvComputer matched(saved);
            if (matched.plankCaptureSource != 2 || matched.plankVideoProfile != profile ||
                    matched.plankHostLayout != NvOutputTopology::MatchClientHostLayout) return 1;
            matched.serialize(saved, false);
            saved.sync();
            if (saved.status() != QSettings::NoError) return 1;
            QSettings disk(saved.fileName(), QSettings::IniFormat);
            NvComputer reopened(disk);
            if (reopened.plankHostLayout != NvOutputTopology::MatchClientHostLayout ||
                    reopened.plankVideoProfile != profile || reopened.plankCaptureSource != 2 ||
                    reopened.plankVirtualMode1 != matched.plankVirtualMode1 ||
                    reopened.plankProfileBitratesKbps != matched.plankProfileBitratesKbps) return 1;
        }
        // Corrupt cross-platform tuples must not silently become a Linux codec.
        saved.setValue(QStringLiteral("plank-video-profile"), 7);
        saved.setValue(QStringLiteral("plank-host-layout"), QStringLiteral("fixed"));
        saved.setValue(QStringLiteral("plank-capture-source"), 0);
        NvComputer invalidTuple(saved);
        if (invalidTuple.plankVideoProfile != 7 ||
                StreamingPreferences::isPlankProfileValidForCaptureSource(
                    invalidTuple.plankVideoProfile, invalidTuple.plankCaptureSource) ||
                invalidTuple.plankHostLayout != NvOutputTopology::MatchClientHostLayout) return 1;
        std::puts("macos_client_bookmark=pass persistence=1 existing_bitrates_preserved=1 invalid_tuple_not_substituted=1");
        std::puts("macos_client_discovery=pass actual_client_parser=1 online_metadata=1 no_media_claim=1 mismatched_port_rejected=1");
        return 0;
    } catch (const std::exception&) {
        // Do not echo unknown server response text into a test log.
        return 1;
    }
}
