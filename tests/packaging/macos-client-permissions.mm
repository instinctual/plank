// Actual permission model and QML layout with only OS boundaries replaced.
// No real consent, System Settings, capture, session or HID device is opened.
#include <QGuiApplication>
#include <QDesktopServices>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QTimer>
#include <QImage>
#include <QDir>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include "../../apps/client/app/backend/macpermissions.h"
#include "../../apps/client/app/streaming/input/macrawwacom.h"
#include <cassert>

static bool accessAllowed, inputAllowed, canConfigure = true;
static int micPermission, tabletPresence;
static unsigned requests, settingsOpened;
static bool settingsSuccess = true;
static std::function<void()> micReply;
static Boolean testAccessibility() { return accessAllowed; }
static IOHIDAccessType testInput(IOHIDRequestType type) {
    assert(type == kIOHIDRequestTypeListenEvent);
    return inputAllowed ? kIOHIDAccessTypeGranted : kIOHIDAccessTypeDenied;
}
int plankMacMicrophonePermission() { return micPermission; }
void plankMacRequestMicrophonePermission(std::function<void()> completed) { ++requests; micReply = completed; }
int MacRawWacomInput::supportedTabletPresence() { return tabletPresence; }
void MacRawWacomInput::requestPermissionIfNeeded() { ++requests; }
class TestDesktopServices {
public:
    static bool openUrl(const QUrl& url) {
        assert(url.scheme() == "x-apple.systempreferences");
        assert(url.toString().contains("Privacy_"));
        ++settingsOpened; return settingsSuccess;
    }
};
#define AXIsProcessTrusted testAccessibility
#define IOHIDCheckAccess testInput
#define QDesktopServices TestDesktopServices
#include "../../apps/client/app/backend/macpermissions.mm"
#undef QDesktopServices

int main(int argc, char** argv)
{
    QGuiApplication app(argc, argv);
    MacPermissions permissions([] { return canConfigure; });
    auto row = [&](int i) { return permissions.rows().at(i).toMap(); };
    permissions.refresh();
    assert(permissions.rows().size() == 3 && requests == 0 && settingsOpened == 0);
    assert(!row(0)["verified"].toBool());
    assert(row(1)["status"].toString() == "Not requested");
    assert(!row(2)["actionable"].toBool());
    tabletPresence = -1; permissions.refresh();
    assert(row(2)["status"].toString() == "Could not check tablet");
    tabletPresence = 1; permissions.refresh(); assert(row(2)["actionable"].toBool());
    canConfigure = false;
    for (int i = 0; i < 3; ++i) permissions.request(i);
    assert(requests == 0 && settingsOpened == 0 && !permissions.error().isEmpty());
    canConfigure = true;
    permissions.request(-1); permissions.request(3); assert(settingsOpened == 0);
    permissions.request(1); permissions.request(1); assert(requests == 1);
    micPermission = -1; micReply();
    assert(row(1)["status"].toString() == "Not allowed");
    permissions.request(1); assert(settingsOpened == 1);
    settingsSuccess = false; permissions.request(0); assert(!permissions.error().isEmpty());
    settingsSuccess = true; permissions.request(0); assert(permissions.error().isEmpty());
    permissions.request(2); assert(requests == 2);
    micPermission = 0;
    auto temporary = new MacPermissions([] { return true; });
    temporary->request(1); delete temporary; micReply(); // Guard late native completion.
    micPermission = 1; accessAllowed = inputAllowed = true;
    permissions.refresh();
    for (int i = 0; i < 3; ++i) assert(row(i)["verified"].toBool());
    assert(requests == 3);

    assert(argc >= 2);
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("macPermissions", &permissions);
    const QUrl source = QUrl::fromLocalFile(QDir(QString::fromLocal8Bit(argv[1])).absolutePath() + "/");
    const QByteArray qml = "import QtQuick\nimport QtQuick.Controls\nimport QtQuick.Controls.Material\nimport \"" + source.toEncoded() +
        "\"\nApplicationWindow { width: 900; height: 720; visible: true; Material.theme: Material.Dark; "
        "MacPermissionsDialog { id: dialog; objectName: \"permissions\"; Component.onCompleted: open() } }";
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app, [](const QList<QQmlError>& errors) {
        for (const auto& error : errors) qCritical() << error;
        std::abort();
    });
    engine.loadData(qml);
    assert(engine.rootObjects().size() == 1);
    QTimer::singleShot(500, &app, [&] {
        auto window = qobject_cast<QQuickWindow*>(engine.rootObjects().first());
        auto dialog = window->findChild<QObject*>("permissions");
        assert(dialog && dialog->property("opened").toBool());
        assert(dialog->property("width").toReal() <= window->width());
        assert(dialog->property("height").toReal() > 200);
        assert(dialog->property("height").toReal() < window->height());
        if (argc == 3) assert(window->grabWindow().save(QString::fromLocal8Bit(argv[2])));
        puts("Client permissions: denied/unknown/granted/absent, active-stream guard, late callback and real QML layout passed");
        app.quit();
    });
    return app.exec();
}
