// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only: validate the uninstall paths against the actual packaged Qt.
#include <QtCore/QCoreApplication>
#include <QtCore/QDir>
#include <QtCore/QSettings>
#include <QtCore/QStandardPaths>
#include <cstdio>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName("Instinctual");
    QCoreApplication::setOrganizationDomain("instinctual.la");
    QCoreApplication::setApplicationName("PLANK");
    const QString home = QDir::homePath();
    if (QSettings().fileName() != home + "/Library/Preferences/la.instinctual.PLANK.plist" ||
        QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation) !=
            home + "/Library/Application Support/Instinctual/PLANK" ||
        QStandardPaths::writableLocation(QStandardPaths::CacheLocation) !=
            home + "/Library/Caches/Instinctual/PLANK") {
        std::fputs("Client uninstaller paths do not match the current Qt configuration\n", stderr);
        return 1;
    }
    std::puts("Client uninstall settings/data/cache paths match Qt; no settings changed");
    return 0;
}
