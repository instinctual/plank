// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the existing Client parser, not a substitute XML implementation.
#include "backend/nvcomputer.h"
#include <QCoreApplication>
#include <QFile>
#include <QTemporaryDir>
#include <cstdio>

static void rememberedUsernameTests(const QTemporaryDir& temporary,
                                     NvHTTP& http, const QString& xml)
{
    const auto check = [](bool condition, const char* message) {
        if (!condition) qFatal("username_persistence: %s", message);
    };
    QSettings policyFile(temporary.filePath(QStringLiteral("client.conf")), QSettings::IniFormat);
    const PlankClientPolicy policy(policyFile.fileName());
    const NvAddress firstAddress(QStringLiteral("first.example.test"), 28989);
    const NvAddress secondAddress(QStringLiteral("second.example.test"), 28989);
    NvComputer first(firstAddress, QStringLiteral("First"), 0, 0,
                     StreamingPreferences::plankDefaultProfileBitrates());
    NvComputer second(secondAddress, QStringLiteral("Second"), 0, 0,
                      StreamingPreferences::plankDefaultProfileBitrates());
    QSettings saved(temporary.filePath(QStringLiteral("usernames.ini")), QSettings::IniFormat);
    const QString key = QStringLiteral("plank-auth-username");
    const QString user = QStringLiteral("Example.User@example.test");
    first.rememberAuthenticatedUsername(user, firstAddress, policy);
    first.serialize(saved, false, policy);
    check(first.rememberedUsername(policy).isEmpty() && !saved.contains(key), "default off");

    policyFile.setValue(QStringLiteral("authentication/remember_username"), true);
    policyFile.sync();
    NvComputer before(first);
    first.rememberAuthenticatedUsername(user, firstAddress, policy);
    check(!first.isEqualSerialized(before), "successful username schedules a bookmark save");
    check(first.rememberedUsername(policy) == user, "exact authenticated spelling");
    check(second.rememberedUsername(policy).isEmpty(), "per bookmark isolation");
    // Public session metadata must neither overwrite nor populate a login name.
    NvComputer advertisement(http, xml);
    advertisement.plankOccupied = true;
    advertisement.plankSessionUser = QStringLiteral("someone-else");
    first.update(advertisement);
    second.update(advertisement);
    check(first.rememberedUsername(policy) == user && second.rememberedUsername(policy).isEmpty(),
          "public metadata is not a credential hint");
    first.sessionToken = QStringLiteral("synthetic-token-not-for-storage");
    first.serialize(saved, false, policy);
    saved.sync();
    QSettings disk(saved.fileName(), QSettings::IniFormat);
    NvComputer reloaded(disk, policy);
    check(reloaded.rememberedUsername(policy) == user && reloaded.sessionToken.isEmpty(),
          "username survives reopening, token does not");
    check(!reloaded.plankOccupied && reloaded.plankSessionUser.isEmpty(), "no occupancy persistence");
    check(!disk.allKeys().contains(QStringLiteral("password")), "no password storage key");
    for (const auto& storedKey : disk.allKeys()) {
        check(disk.value(storedKey).toString() != first.sessionToken, "no token serialized");
    }
    first.rememberAuthenticatedUsername(QStringLiteral("other-user"), secondAddress, policy);
    check(first.rememberedUsername(policy) == user, "stale destination completion ignored");
    first.updateManualBookmark(firstAddress, QStringLiteral("Renamed"), first.plankScalingMode,
        first.plankHostLayout, first.plankVirtualMode1, first.plankVirtualMode2,
        first.plankVideoProfile, first.plankCaptureSource, first.plankProfileBitratesKbps);
    check(first.rememberedUsername(policy) == user, "nickname edit preserves name");
    first.updateManualBookmark(secondAddress, QStringLiteral("Moved"), first.plankScalingMode,
        first.plankHostLayout, first.plankVirtualMode1, first.plankVirtualMode2,
        first.plankVideoProfile, first.plankCaptureSource, first.plankProfileBitratesKbps);
    check(first.rememberedUsername(policy).isEmpty(), "destination edit clears name");
    first.rememberAuthenticatedUsername(user, firstAddress, policy);
    check(first.rememberedUsername(policy).isEmpty(), "late success cannot repopulate old destination");
    for (const auto& invalid : {QString(), QString(257, QLatin1Char('x')),
            QStringLiteral("line\nfeed"), QString(QChar(0))}) {
        saved.setValue(key, invalid);
        NvComputer corrupt(saved, policy);
        check(corrupt.rememberedUsername(policy).isEmpty() && !saved.contains(key), "invalid disk value removed");
    }
    const QString international = QString::fromUtf8("\xc3\xa9xample@example.test");
    first.rememberAuthenticatedUsername(international, secondAddress, policy);
    check(first.rememberedUsername(policy) == international, "non-ASCII name retained");
    first.serialize(saved, false, policy);
    policyFile.setValue(QStringLiteral("authentication/remember_username"), false);
    policyFile.sync();
    check(first.rememberedUsername(policy).isEmpty(), "disable suppresses current prefill");
    first.serialize(saved, false, policy);
    check(!saved.contains(key), "disable prevents queued saves");
    saved.setValue(key, user);
    NvComputer disabled(saved, policy);
    check(disabled.rememberedUsername(policy).isEmpty() && !saved.contains(key), "disabled load purges name");
    // Startup cleanup also removes unused backup slots, not just array size.
    saved.clear();
    for (const auto& array : {QStringLiteral("hosts"), QStringLiteral("hostsbackup")}) {
        saved.setValue(array + QStringLiteral("/size"), 1);
        for (const auto& index : {QStringLiteral("1"), QStringLiteral("9")}) {
            saved.setValue(array + "/" + index + "/" + key, user);
            saved.setValue(array + "/" + index + QStringLiteral("/hostname"), QStringLiteral("Keep"));
        }
        NvComputer::forgetSavedUsernames(saved, array);
        check(saved.value(array + QStringLiteral("/size")).toInt() == 1, "array preserved");
        for (const auto& index : {QStringLiteral("1"), QStringLiteral("9")}) {
            check(!saved.contains(array + "/" + index + "/" + key), "primary and backup purged");
            check(saved.value(array + "/" + index + QStringLiteral("/hostname")).toString() == "Keep",
                  "unrelated bookmark state preserved");
        }
    }
    std::puts("client_username_persistence=pass default_off=1 per_bookmark=1 exact_names=1 no_tokens=1 policy_purge=1 destination_reset=1");
}

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
        rememberedUsernameTests(temporary, http, xml);
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
